//! Pure reconnect policy: a deterministic state machine with no I/O and no clocks.
//!
//! The driver (owned by the caller) feeds [`ReconnectEvent`]s into
//! [`ReconnectPolicy::transition`] and performs the returned [`ReconnectAction`].
//! Whenever the state changes, any previously scheduled retry timer must be cancelled
//! by the driver.

use std::sync::Arc;
use std::time::Duration;

/// Why a connection attempt failed, as far as retry policy is concerned.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FailureKind {
    /// Transport-level failure (refused, unreachable, reset). Retriable.
    Network,
    /// Connection attempt timed out. Retriable.
    Timeout,
    /// Credentials were rejected. Retrying cannot help.
    AuthFailed,
    /// The host key was rejected by the verifier. Retrying cannot help.
    HostKeyRejected,
    /// Any other failure. Retriable.
    Other,
}

impl FailureKind {
    /// Whether retrying could possibly succeed without user intervention.
    pub fn is_retriable(self) -> bool {
        !matches!(self, FailureKind::AuthFailed | FailureKind::HostKeyRejected)
    }
}

/// Reconnect state.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ReconnectState {
    /// Not connected and not trying.
    Idle,
    /// A connection attempt (numbered from 1) is in flight.
    Connecting { attempt: u32 },
    /// Session is up.
    Connected,
    /// Waiting `delay` before the next attempt; `attempt` is the one that just failed.
    Backoff { attempt: u32, delay: Duration },
    /// Gave up (fatal failure or attempt budget exhausted). Only [`ReconnectEvent::Connect`]
    /// leaves this state.
    GaveUp,
}

/// Inputs to the state machine.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ReconnectEvent {
    /// The user (or app) asks to connect.
    Connect,
    /// The in-flight attempt succeeded.
    ConnectOk,
    /// The in-flight attempt failed.
    ConnectFailed(FailureKind),
    /// An established session dropped.
    Dropped,
    /// The backoff timer elapsed.
    BackoffElapsed,
    /// The device's network path changed.
    NetworkChanged,
    /// The app returned to the foreground.
    AppForegrounded,
    /// The user cancelled.
    UserCancel,
}

/// What the driver must do after a transition.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ReconnectAction {
    /// Nothing.
    None,
    /// Start a connection attempt now (cancelling any pending retry timer).
    StartConnect,
    /// Fire [`ReconnectEvent::BackoffElapsed`] after this delay.
    ScheduleRetry(Duration),
    /// Abort any in-flight attempt or pending timer.
    Cancel,
}

/// Result of feeding one event.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Transition {
    /// The new state.
    pub state: ReconnectState,
    /// The side effect the driver should perform.
    pub action: ReconnectAction,
}

/// Source of backoff jitter; injectable for determinism.
pub trait Jitter: Send + Sync {
    /// Returns the actual delay to use for a nominal delay `d`. Must return a value `<= d`.
    fn apply(&self, d: Duration) -> Duration;
}

/// No jitter: delays are exactly the exponential schedule.
#[derive(Debug, Default, Clone, Copy)]
pub struct NoJitter;

impl Jitter for NoJitter {
    fn apply(&self, d: Duration) -> Duration {
        d
    }
}

/// Random jitter in `[d/2, d]`.
#[derive(Debug, Default, Clone, Copy)]
pub struct HalfJitter;

impl Jitter for HalfJitter {
    fn apply(&self, d: Duration) -> Duration {
        let half = d / 2;
        let spread = (d - half).as_nanos() as u64;
        if spread == 0 {
            return d;
        }
        half + Duration::from_nanos(rand::random_range(0..=spread))
    }
}

/// Reconnect policy parameters plus the transition function.
#[derive(Clone)]
pub struct ReconnectPolicy {
    /// Delay before the 2nd attempt (doubles each time).
    pub base: Duration,
    /// Upper bound on any delay.
    pub cap: Duration,
    /// Give up after this many failed attempts; `None` retries forever.
    pub max_attempts: Option<u32>,
    jitter: Arc<dyn Jitter>,
}

impl ReconnectPolicy {
    /// Default policy (1s base, 30s cap, unlimited attempts, [`HalfJitter`]).
    pub fn new() -> Self {
        Self::with_jitter(Arc::new(HalfJitter))
    }

    /// Default policy with a custom jitter source.
    pub fn with_jitter(jitter: Arc<dyn Jitter>) -> Self {
        Self {
            base: Duration::from_secs(1),
            cap: Duration::from_secs(30),
            max_attempts: None,
            jitter,
        }
    }

    /// Nominal (pre-jitter) delay after `attempt` failures: `min(cap, base * 2^(attempt-1))`.
    pub fn nominal_delay(&self, attempt: u32) -> Duration {
        let exp = attempt.saturating_sub(1).min(32);
        self.base.saturating_mul(1u32 << exp.min(31)).min(self.cap)
    }

    /// Computes the next state and action for `event` in `state`.
    pub fn transition(&self, state: &ReconnectState, event: ReconnectEvent) -> Transition {
        use ReconnectAction as A;
        use ReconnectEvent as E;
        use ReconnectState as S;
        let go = |state, action| Transition { state, action };
        let stay = go(*state, A::None);
        match (*state, event) {
            (S::Idle | S::GaveUp, E::Connect) => go(S::Connecting { attempt: 1 }, A::StartConnect),
            (S::GaveUp, E::UserCancel) => go(S::Idle, A::None),
            (S::Connecting { .. } | S::Connected | S::Backoff { .. }, E::UserCancel) => {
                go(S::Idle, A::Cancel)
            }
            (S::Connecting { .. }, E::ConnectOk) => go(S::Connected, A::None),
            (S::Connecting { attempt }, E::ConnectFailed(kind)) => {
                let exhausted = self.max_attempts.is_some_and(|m| attempt >= m);
                if !kind.is_retriable() || exhausted {
                    go(S::GaveUp, A::None)
                } else {
                    let delay = self.jitter.apply(self.nominal_delay(attempt)).min(self.cap);
                    go(S::Backoff { attempt, delay }, A::ScheduleRetry(delay))
                }
            }
            (S::Connected, E::Dropped) => go(S::Connecting { attempt: 1 }, A::StartConnect),
            (S::Backoff { attempt, .. }, E::BackoffElapsed) => go(
                S::Connecting {
                    attempt: attempt.saturating_add(1),
                },
                A::StartConnect,
            ),
            (S::Backoff { .. }, E::NetworkChanged | E::AppForegrounded) => {
                go(S::Connecting { attempt: 1 }, A::StartConnect)
            }
            _ => stay,
        }
    }
}

impl Default for ReconnectPolicy {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use ReconnectAction as A;
    use ReconnectEvent as E;
    use ReconnectState as S;

    fn p() -> ReconnectPolicy {
        ReconnectPolicy::with_jitter(Arc::new(NoJitter))
    }
    fn secs(n: u64) -> Duration {
        Duration::from_secs(n)
    }
    fn t(state: ReconnectState, action: ReconnectAction) -> Transition {
        Transition { state, action }
    }

    #[test]
    fn failure_kind_retriable() {
        assert!(FailureKind::Network.is_retriable());
        assert!(FailureKind::Timeout.is_retriable());
        assert!(FailureKind::Other.is_retriable());
        assert!(!FailureKind::AuthFailed.is_retriable());
        assert!(!FailureKind::HostKeyRejected.is_retriable());
    }

    #[test]
    fn nominal_delay_is_exponential_and_capped() {
        let p = p();
        let got: Vec<_> = (1..=8).map(|n| p.nominal_delay(n)).collect();
        assert_eq!(
            got,
            vec![
                secs(1),
                secs(2),
                secs(4),
                secs(8),
                secs(16),
                secs(30),
                secs(30),
                secs(30)
            ]
        );
        // No overflow for huge attempt numbers.
        assert_eq!(p.nominal_delay(u32::MAX), secs(30));
        assert_eq!(p.nominal_delay(0), secs(1));
    }

    #[test]
    fn half_jitter_stays_within_bounds() {
        let j = HalfJitter;
        for _ in 0..200 {
            let d = j.apply(secs(10));
            assert!(d >= secs(5) && d <= secs(10), "{d:?}");
        }
        assert_eq!(j.apply(Duration::ZERO), Duration::ZERO);
    }

    #[test]
    fn jitter_is_injected_into_backoff() {
        struct Third;
        impl Jitter for Third {
            fn apply(&self, d: Duration) -> Duration {
                d / 3
            }
        }
        let p = ReconnectPolicy::with_jitter(Arc::new(Third));
        let tr = p.transition(
            &S::Connecting { attempt: 3 },
            E::ConnectFailed(FailureKind::Network),
        );
        assert_eq!(
            tr,
            t(
                S::Backoff {
                    attempt: 3,
                    delay: secs(4) / 3
                },
                A::ScheduleRetry(secs(4) / 3)
            )
        );
    }

    #[test]
    fn idle_connect_starts_attempt_one() {
        assert_eq!(
            p().transition(&S::Idle, E::Connect),
            t(S::Connecting { attempt: 1 }, A::StartConnect)
        );
    }

    #[test]
    fn idle_ignores_everything_else() {
        for e in [
            E::ConnectOk,
            E::ConnectFailed(FailureKind::Network),
            E::Dropped,
            E::BackoffElapsed,
            E::NetworkChanged,
            E::AppForegrounded,
            E::UserCancel,
        ] {
            assert_eq!(p().transition(&S::Idle, e), t(S::Idle, A::None), "{e:?}");
        }
    }

    #[test]
    fn connecting_ok_goes_connected() {
        assert_eq!(
            p().transition(&S::Connecting { attempt: 4 }, E::ConnectOk),
            t(S::Connected, A::None)
        );
    }

    #[test]
    fn connecting_retriable_failure_backs_off_exponentially() {
        for (attempt, want) in [(1, 1), (2, 2), (3, 4), (4, 8), (5, 16), (6, 30), (20, 30)] {
            for kind in [
                FailureKind::Network,
                FailureKind::Timeout,
                FailureKind::Other,
            ] {
                assert_eq!(
                    p().transition(&S::Connecting { attempt }, E::ConnectFailed(kind)),
                    t(
                        S::Backoff {
                            attempt,
                            delay: secs(want)
                        },
                        A::ScheduleRetry(secs(want))
                    ),
                    "attempt {attempt} {kind:?}"
                );
            }
        }
    }

    #[test]
    fn connecting_fatal_failure_gives_up() {
        for kind in [FailureKind::AuthFailed, FailureKind::HostKeyRejected] {
            assert_eq!(
                p().transition(&S::Connecting { attempt: 1 }, E::ConnectFailed(kind)),
                t(S::GaveUp, A::None)
            );
        }
    }

    #[test]
    fn connecting_gives_up_when_attempt_budget_exhausted() {
        let mut policy = p();
        policy.max_attempts = Some(3);
        assert!(matches!(
            policy
                .transition(
                    &S::Connecting { attempt: 2 },
                    E::ConnectFailed(FailureKind::Network)
                )
                .state,
            S::Backoff { .. }
        ));
        assert_eq!(
            policy.transition(
                &S::Connecting { attempt: 3 },
                E::ConnectFailed(FailureKind::Network)
            ),
            t(S::GaveUp, A::None)
        );
    }

    #[test]
    fn connecting_ignores_redundant_triggers() {
        let s = S::Connecting { attempt: 2 };
        for e in [
            E::Connect,
            E::Dropped,
            E::BackoffElapsed,
            E::NetworkChanged,
            E::AppForegrounded,
        ] {
            assert_eq!(p().transition(&s, e), t(s, A::None), "{e:?}");
        }
    }

    #[test]
    fn connecting_cancel_goes_idle() {
        assert_eq!(
            p().transition(&S::Connecting { attempt: 2 }, E::UserCancel),
            t(S::Idle, A::Cancel)
        );
    }

    #[test]
    fn connected_dropped_retries_immediately() {
        assert_eq!(
            p().transition(&S::Connected, E::Dropped),
            t(S::Connecting { attempt: 1 }, A::StartConnect)
        );
    }

    #[test]
    fn connected_cancel_goes_idle_and_cancels() {
        assert_eq!(
            p().transition(&S::Connected, E::UserCancel),
            t(S::Idle, A::Cancel)
        );
    }

    #[test]
    fn connected_ignores_other_events() {
        for e in [
            E::Connect,
            E::ConnectOk,
            E::ConnectFailed(FailureKind::Network),
            E::BackoffElapsed,
            E::NetworkChanged,
            E::AppForegrounded,
        ] {
            assert_eq!(
                p().transition(&S::Connected, e),
                t(S::Connected, A::None),
                "{e:?}"
            );
        }
    }

    #[test]
    fn backoff_elapsed_starts_next_attempt() {
        assert_eq!(
            p().transition(
                &S::Backoff {
                    attempt: 3,
                    delay: secs(4)
                },
                E::BackoffElapsed
            ),
            t(S::Connecting { attempt: 4 }, A::StartConnect)
        );
    }

    #[test]
    fn backoff_network_change_or_foreground_retries_immediately_and_resets_attempts() {
        let s = S::Backoff {
            attempt: 7,
            delay: secs(30),
        };
        for e in [E::NetworkChanged, E::AppForegrounded] {
            assert_eq!(
                p().transition(&s, e),
                t(S::Connecting { attempt: 1 }, A::StartConnect),
                "{e:?}"
            );
        }
    }

    #[test]
    fn backoff_cancel_goes_idle() {
        assert_eq!(
            p().transition(
                &S::Backoff {
                    attempt: 2,
                    delay: secs(2)
                },
                E::UserCancel
            ),
            t(S::Idle, A::Cancel)
        );
    }

    #[test]
    fn backoff_ignores_other_events() {
        let s = S::Backoff {
            attempt: 2,
            delay: secs(2),
        };
        for e in [
            E::Connect,
            E::ConnectOk,
            E::ConnectFailed(FailureKind::Network),
            E::Dropped,
        ] {
            assert_eq!(p().transition(&s, e), t(s, A::None), "{e:?}");
        }
    }

    #[test]
    fn gave_up_only_leaves_on_explicit_connect_or_cancel() {
        assert_eq!(
            p().transition(&S::GaveUp, E::Connect),
            t(S::Connecting { attempt: 1 }, A::StartConnect)
        );
        assert_eq!(
            p().transition(&S::GaveUp, E::UserCancel),
            t(S::Idle, A::None)
        );
        for e in [
            E::ConnectOk,
            E::ConnectFailed(FailureKind::Network),
            E::Dropped,
            E::BackoffElapsed,
            E::NetworkChanged,
            E::AppForegrounded,
        ] {
            assert_eq!(
                p().transition(&S::GaveUp, e),
                t(S::GaveUp, A::None),
                "{e:?}"
            );
        }
    }

    #[test]
    fn full_scenario_drop_fail_fail_recover() {
        let p = p();
        let mut s = S::Connected;
        let steps = [
            (E::Dropped, S::Connecting { attempt: 1 }),
            (
                E::ConnectFailed(FailureKind::Network),
                S::Backoff {
                    attempt: 1,
                    delay: secs(1),
                },
            ),
            (E::BackoffElapsed, S::Connecting { attempt: 2 }),
            (
                E::ConnectFailed(FailureKind::Timeout),
                S::Backoff {
                    attempt: 2,
                    delay: secs(2),
                },
            ),
            (E::NetworkChanged, S::Connecting { attempt: 1 }),
            (E::ConnectOk, S::Connected),
        ];
        for (e, want) in steps {
            s = p.transition(&s, e).state;
            assert_eq!(s, want, "{e:?}");
        }
    }
}
