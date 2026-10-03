use shuai_ffi::*;

#[test]
fn drives_connect_fail_backoff_retry_ok() {
    let p = ReconnectPolicy::new(None, false);
    assert_eq!(p.state(), FfiReconnectState::Idle);
    assert_eq!(
        p.transition(FfiReconnectEvent::Connect),
        FfiReconnectAction::StartConnect
    );
    assert_eq!(p.state(), FfiReconnectState::Connecting { attempt: 1 });
    let a = p.transition(FfiReconnectEvent::ConnectFailed {
        kind: FfiFailureKind::Network,
    });
    assert_eq!(a, FfiReconnectAction::ScheduleRetry { delay_ms: 1000 });
    assert_eq!(
        p.transition(FfiReconnectEvent::BackoffElapsed),
        FfiReconnectAction::StartConnect
    );
    let a = p.transition(FfiReconnectEvent::ConnectFailed {
        kind: FfiFailureKind::Timeout,
    });
    assert_eq!(a, FfiReconnectAction::ScheduleRetry { delay_ms: 2000 });
    p.transition(FfiReconnectEvent::BackoffElapsed);
    assert_eq!(
        p.transition(FfiReconnectEvent::ConnectOk),
        FfiReconnectAction::None
    );
    assert_eq!(p.state(), FfiReconnectState::Connected { attempt: 3 });
}

#[test]
fn auth_failure_gives_up() {
    let p = ReconnectPolicy::new(None, false);
    p.transition(FfiReconnectEvent::Connect);
    let a = p.transition(FfiReconnectEvent::ConnectFailed {
        kind: FfiFailureKind::AuthFailed,
    });
    assert_eq!(a, FfiReconnectAction::None);
    assert_eq!(p.state(), FfiReconnectState::GaveUp);
}

#[test]
fn max_attempts_is_honoured_and_stable_drop_reconnects_immediately() {
    let p = ReconnectPolicy::new(Some(0), false);
    p.transition(FfiReconnectEvent::Connect);
    p.transition(FfiReconnectEvent::ConnectFailed {
        kind: FfiFailureKind::Network,
    });
    assert_eq!(p.state(), FfiReconnectState::GaveUp);

    let p = ReconnectPolicy::new(None, false);
    p.transition(FfiReconnectEvent::Connect);
    p.transition(FfiReconnectEvent::ConnectOk);
    let a = p.transition(FfiReconnectEvent::Dropped { uptime_ms: 60_000 });
    assert_eq!(a, FfiReconnectAction::StartConnect);
}

#[test]
fn cancel_aborts() {
    let p = ReconnectPolicy::new(None, true);
    p.transition(FfiReconnectEvent::Connect);
    assert_eq!(
        p.transition(FfiReconnectEvent::UserCancel),
        FfiReconnectAction::Cancel
    );
    assert_eq!(p.state(), FfiReconnectState::Idle);
}
