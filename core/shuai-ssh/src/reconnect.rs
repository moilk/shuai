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
    Connecting {
        /// Attempt number, from 1.
        attempt: u32,
    },
    /// Session is up.
    Connected,
    /// Waiting `delay` before the next attempt; `attempt` is the one that just failed.
    Backoff {
        /// The attempt that just failed.
        attempt: u32,
        /// Time to wait before the next attempt.
        delay: Duration,
    },
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
    fn dropped(uptime: Duration) -> ReconnectEvent {
        E::Dropped { uptime }
    }
    fn connected(attempt: u32) -> ReconnectState {
        S::Connected { attempt }
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
        let mut p = ReconnectPolicy::with_jitter(Arc::new(Third));
        p.min_drop_delay = Duration::ZERO;
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
            dropped(secs(100)),
            E::BackoffElapsed,
            E::NetworkChanged,
            E::AppForegrounded,
            E::UserCancel,
        ] {
            assert_eq!(p().transition(&S::Idle, e), t(S::Idle, A::None), "{e:?}");
        }
    }

    #[test]
    fn connecting_ok_goes_connected_carrying_the_attempt() {
        assert_eq!(
            p().transition(&S::Connecting { attempt: 4 }, E::ConnectOk),
            t(connected(4), A::None)
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
    fn max_attempts_zero_means_a_single_try_and_no_retries() {
        let mut policy = p();
        policy.max_attempts = Some(0);
        // An explicit connect still makes one attempt...
        assert_eq!(
            policy.transition(&S::Idle, E::Connect),
            t(S::Connecting { attempt: 1 }, A::StartConnect)
        );
        // ...but its failure is final, retriable or not.
        assert_eq!(
            policy.transition(
                &S::Connecting { attempt: 1 },
                E::ConnectFailed(FailureKind::Network)
            ),
            t(S::GaveUp, A::None)
        );
        // And so is a quick drop of a connection that came up.
        assert_eq!(
            policy.transition(&connected(1), dropped(Duration::ZERO)),
            t(S::GaveUp, A::None)
        );
    }

    #[test]
    fn connecting_ignores_redundant_triggers() {
        let s = S::Connecting { attempt: 2 };
        for e in [E::Connect, dropped(secs(1)), E::BackoffElapsed] {
            assert_eq!(p().transition(&s, e), t(s, A::None), "{e:?}");
        }
    }

    #[test]
    fn connecting_network_change_or_foreground_restarts_the_attempt() {
        for e in [E::NetworkChanged, E::AppForegrounded] {
            assert_eq!(
                p().transition(&S::Connecting { attempt: 3 }, e),
                t(S::Connecting { attempt: 1 }, A::RestartConnect),
                "{e:?}"
            );
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
    fn stable_connection_dropping_reconnects_immediately_from_attempt_one() {
        for uptime in [secs(10), secs(3600)] {
            assert_eq!(
                p().transition(&connected(5), dropped(uptime)),
                t(S::Connecting { attempt: 1 }, A::StartConnect)
            );
        }
    }

    #[test]
    fn quick_drop_backs_off_instead_of_hammering_the_server() {
        let tr = p().transition(&connected(1), dropped(Duration::from_millis(200)));
        assert_eq!(
            tr,
            t(
                S::Backoff {
                    attempt: 1,
                    delay: secs(1)
                },
                A::ScheduleRetry(secs(1))
            )
        );
        // Just below the stability threshold still counts as quick.
        let tr = p().transition(&connected(1), dropped(Duration::from_millis(9_999)));
        assert!(matches!(tr.action, A::ScheduleRetry(_)));
    }

    #[test]
    fn quick_drop_applies_minimum_delay_even_with_small_jitter() {
        struct Tiny;
        impl Jitter for Tiny {
            fn apply(&self, _: Duration) -> Duration {
                Duration::from_millis(1)
            }
        }
        let mut p = ReconnectPolicy::with_jitter(Arc::new(Tiny));
        p.min_drop_delay = Duration::from_millis(500);
        let tr = p.transition(&connected(1), dropped(Duration::ZERO));
        assert_eq!(tr.action, A::ScheduleRetry(Duration::from_millis(500)));
    }

    #[test]
    fn accept_then_drop_server_sees_growing_delays_not_a_tight_loop() {
        let p = p();
        let mut s = S::Idle;
        let mut tr = p.transition(&s, E::Connect);
        let mut delays = Vec::new();
        for _ in 0..8 {
            s = p.transition(&tr.state, E::ConnectOk).state;
            tr = p.transition(&s, dropped(Duration::from_millis(50)));
            let A::ScheduleRetry(d) = tr.action else {
                panic!("quick drop must back off, got {tr:?}");
            };
            delays.push(d);
            tr = p.transition(&tr.state, E::BackoffElapsed);
            assert!(matches!(tr.state, S::Connecting { .. }));
        }
        assert_eq!(
            delays,
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
    }

    #[test]
    fn connected_cancel_goes_idle_and_cancels() {
        assert_eq!(
            p().transition(&connected(1), E::UserCancel),
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
                p().transition(&connected(2), e),
                t(connected(2), A::None),
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
    fn backoff_connect_means_retry_now_keeping_the_attempt_count() {
        assert_eq!(
            p().transition(
                &S::Backoff {
                    attempt: 3,
                    delay: secs(4)
                },
                E::Connect
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
            E::ConnectOk,
            E::ConnectFailed(FailureKind::Network),
            dropped(secs(100)),
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
            dropped(secs(100)),
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
    fn full_scenario_stable_drop_fail_fail_recover() {
        let p = p();
        let mut s = connected(1);
        let steps = [
            (dropped(secs(60)), S::Connecting { attempt: 1 }),
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
            (E::ConnectOk, connected(1)),
        ];
        for (e, want) in steps {
            s = p.transition(&s, e).state;
            assert_eq!(s, want, "{e:?}");
        }
    }

    mod props {
        use super::*;
        use proptest::prelude::*;

        fn arb_event() -> impl Strategy<Value = ReconnectEvent> {
            prop_oneof![
                Just(E::Connect),
                Just(E::ConnectOk),
                prop_oneof![
                    Just(FailureKind::Network),
                    Just(FailureKind::Timeout),
                    Just(FailureKind::AuthFailed),
                    Just(FailureKind::HostKeyRejected),
                    Just(FailureKind::Other),
                ]
                .prop_map(E::ConnectFailed),
                (0u64..40_000).prop_map(|ms| E::Dropped {
                    uptime: Duration::from_millis(ms)
                }),
                Just(E::BackoffElapsed),
                Just(E::NetworkChanged),
                Just(E::AppForegrounded),
                Just(E::UserCancel),
            ]
        }

        proptest! {
            #[test]
            fn invariants_hold_for_arbitrary_event_sequences(
                events in proptest::collection::vec(arb_event(), 0..200),
                max_attempts in proptest::option::of(0u32..6),
                half_jitter in any::<bool>(),
            ) {
                let jitter: Arc<dyn Jitter> =
                    if half_jitter { Arc::new(HalfJitter) } else { Arc::new(NoJitter) };
                let mut policy = ReconnectPolicy::with_jitter(jitter);
                policy.max_attempts = max_attempts;
                let mut state = S::Idle;
                for e in events {
                    let tr = policy.transition(&state, e);
                    // Delays never exceed the cap.
                    if let A::ScheduleRetry(d) = tr.action {
                        prop_assert!(d <= policy.cap, "{d:?}");
                        prop_assert!(matches!(tr.state, S::Backoff { delay, .. } if delay == d));
                    }
                    if let S::Backoff { delay, attempt } = tr.state {
                        prop_assert!(delay <= policy.cap);
                        prop_assert!(attempt >= 1);
                    }
                    // GaveUp is only left through an explicit Connect (or the user cancelling).
                    if state == S::GaveUp {
                        match e {
                            E::Connect => prop_assert_eq!(tr.state, S::Connecting { attempt: 1 }),
                            E::UserCancel => prop_assert_eq!(tr.state, S::Idle),
                            _ => prop_assert_eq!(tr.state, S::GaveUp),
                        }
                    }
                    // Never start (or restart) an attempt while connected.
                    if matches!(state, S::Connected { .. }) {
                        prop_assert!(!matches!(tr.action, A::StartConnect | A::RestartConnect));
                    }
                    // Actions and resulting states agree.
                    if matches!(tr.action, A::StartConnect | A::RestartConnect) {
                        prop_assert!(matches!(tr.state, S::Connecting { .. }));
                    }
                    if let S::Connecting { attempt } = tr.state {
                        prop_assert!(attempt >= 1);
                        if let Some(m) = max_attempts.filter(|m| *m >= 1) {
                            prop_assert!(attempt <= m, "attempt {attempt} > budget {m}");
                        }
                    }
                    state = tr.state;
                }
            }
        }
    }
}
