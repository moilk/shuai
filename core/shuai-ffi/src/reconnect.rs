//! Reconnect state machine; Swift owns the timers and feeds events in.

use std::sync::{Arc, Mutex};
use std::time::Duration;

use shuai_ssh::reconnect as r;

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum FfiFailureKind {
    Network,
    Timeout,
    AuthFailed,
    HostKeyRejected,
    Other,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum FfiReconnectState {
    Idle,
    Connecting { attempt: u32 },
    Connected { attempt: u32 },
    Backoff { attempt: u32, delay_ms: u64 },
    GaveUp,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum FfiReconnectEvent {
    Connect,
    ConnectOk,
    ConnectFailed { kind: FfiFailureKind },
    Dropped { uptime_ms: u64 },
    BackoffElapsed,
    NetworkChanged,
    AppForegrounded,
    UserCancel,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum FfiReconnectAction {
    None,
    StartConnect,
    RestartConnect,
    ScheduleRetry { delay_ms: u64 },
    Cancel,
}

impl From<FfiFailureKind> for r::FailureKind {
    fn from(k: FfiFailureKind) -> Self {
        match k {
            FfiFailureKind::Network => Self::Network,
            FfiFailureKind::Timeout => Self::Timeout,
            FfiFailureKind::AuthFailed => Self::AuthFailed,
            FfiFailureKind::HostKeyRejected => Self::HostKeyRejected,
            FfiFailureKind::Other => Self::Other,
        }
    }
}

impl From<FfiReconnectEvent> for r::ReconnectEvent {
    fn from(e: FfiReconnectEvent) -> Self {
        match e {
            FfiReconnectEvent::Connect => Self::Connect,
            FfiReconnectEvent::ConnectOk => Self::ConnectOk,
            FfiReconnectEvent::ConnectFailed { kind } => Self::ConnectFailed(kind.into()),
            FfiReconnectEvent::Dropped { uptime_ms } => Self::Dropped {
                uptime: Duration::from_millis(uptime_ms),
            },
            FfiReconnectEvent::BackoffElapsed => Self::BackoffElapsed,
            FfiReconnectEvent::NetworkChanged => Self::NetworkChanged,
            FfiReconnectEvent::AppForegrounded => Self::AppForegrounded,
            FfiReconnectEvent::UserCancel => Self::UserCancel,
        }
    }
}

fn ms(d: Duration) -> u64 {
    d.as_millis() as u64
}

impl From<r::ReconnectState> for FfiReconnectState {
    fn from(s: r::ReconnectState) -> Self {
        match s {
            r::ReconnectState::Idle => Self::Idle,
            r::ReconnectState::Connecting { attempt } => Self::Connecting { attempt },
            r::ReconnectState::Connected { attempt } => Self::Connected { attempt },
            r::ReconnectState::Backoff { attempt, delay } => Self::Backoff {
                attempt,
                delay_ms: ms(delay),
            },
            r::ReconnectState::GaveUp => Self::GaveUp,
        }
    }
}

impl From<r::ReconnectAction> for FfiReconnectAction {
    fn from(a: r::ReconnectAction) -> Self {
        match a {
            r::ReconnectAction::None => Self::None,
            r::ReconnectAction::StartConnect => Self::StartConnect,
            r::ReconnectAction::RestartConnect => Self::RestartConnect,
            r::ReconnectAction::ScheduleRetry(d) => Self::ScheduleRetry { delay_ms: ms(d) },
            r::ReconnectAction::Cancel => Self::Cancel,
        }
    }
}

/// Stateful wrapper around the pure policy: feed events, perform the returned action.
#[derive(uniffi::Object)]
pub struct ReconnectPolicy {
    policy: r::ReconnectPolicy,
    state: Mutex<r::ReconnectState>,
}

#[uniffi::export]
impl ReconnectPolicy {
    /// `max_attempts = None` retries forever. `jitter = false` gives exact exponential
    /// delays (1s, 2s, 4s, ... capped at 30s), useful for tests.
    #[uniffi::constructor]
    pub fn new(max_attempts: Option<u32>, jitter: bool) -> Arc<Self> {
        let mut policy = if jitter {
            r::ReconnectPolicy::new()
        } else {
            r::ReconnectPolicy::with_jitter(Arc::new(r::NoJitter))
        };
        policy.max_attempts = max_attempts;
        Arc::new(Self {
            policy,
            state: Mutex::new(r::ReconnectState::Idle),
        })
    }

    pub fn state(&self) -> FfiReconnectState {
        (*self.state.lock().unwrap()).into()
    }

    pub fn transition(&self, event: FfiReconnectEvent) -> FfiReconnectAction {
        let mut st = self.state.lock().unwrap();
        let t = self.policy.transition(&st, event.into());
        *st = t.state;
        t.action.into()
    }
}
