mod common;
use common::*;
use std::time::Duration;

fn cfg(h: &std::path::Path, url: &str) {
    write_config(
        h,
        &format!("[ntfy]\nserver = \"{url}\"\ntopic = \"my-topic\"\ntoken = \"tk_secret\"\n"),
    );
}

#[test]
fn notify_posts_to_ntfy() {
    let h = home();
    let m = mock_server();
    cfg(h.path(), &m.url);
    let out = agent(h.path())
        .args([
            "notify",
            "--title",
            "Claude needs you",
            "--body",
            "Approve Bash?",
        ])
        .args([
            "--click",
            "shuai://host/dev/pane/%255",
            "--priority",
            "high",
            "--tags",
            "lock,robot",
        ])
        .output()
        .unwrap();
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    let r = m.rx.recv_timeout(Duration::from_secs(5)).unwrap();
    assert_eq!(r.request_line, "POST /my-topic HTTP/1.1");
    assert_eq!(r.body, "Approve Bash?");
    assert_eq!(r.headers["title"], "Claude needs you");
    assert_eq!(r.headers["click"], "shuai://host/dev/pane/%255");
    assert_eq!(r.headers["priority"], "high");
    assert_eq!(r.headers["tags"], "lock,robot");
    assert_eq!(r.headers["authorization"], "Bearer tk_secret");
}

#[test]
fn notify_without_config_fails_cleanly() {
    let h = home();
    let out = agent(h.path())
        .args(["notify", "--title", "t", "--body", "b"])
        .output()
        .unwrap();
    assert!(!out.status.success());
}

#[test]
fn notify_to_dead_server_fails_quickly() {
    let h = home();
    cfg(h.path(), "http://127.0.0.1:1");
    let t0 = std::time::Instant::now();
    let out = agent(h.path())
        .args(["notify", "--title", "t", "--body", "b"])
        .output()
        .unwrap();
    assert!(!out.status.success());
    assert!(t0.elapsed() < Duration::from_secs(8));
}

fn hook_with_pane(h: &std::path::Path, event: &str, fx: &str) {
    let mut c = agent(h);
    c.args(["hook", event])
        .env("TMUX_PANE", "%5")
        .env("TMUX", "/tmp/tmux-1000/default,1,0")
        .env("SHUAI_PUSH_MIN_INTERVAL_SECS", "0");
    let out = run_with_stdin(c, &fixture(fx));
    assert_eq!(out.status.code(), Some(0));
    assert!(out.stdout.is_empty());
}

#[test]
fn permission_prompt_notification_pushes_when_app_absent() {
    let h = home();
    let m = mock_server();
    cfg(h.path(), &m.url);
    hook_with_pane(h.path(), "Notification", "notification_permission");
    let r = m.rx.recv_timeout(Duration::from_secs(5)).unwrap();
    assert_eq!(r.request_line, "POST /my-topic HTTP/1.1");
    assert_eq!(r.headers["title"], "Claude needs approval");
    assert_eq!(r.body, "test-host");
    assert_eq!(r.headers["click"], "shuai://open?host=test-host&pane=%255");
    assert!(r.headers.contains_key("title"));
    // event still recorded
    assert_eq!(events(h.path()).len(), 1);
}

#[test]
fn idle_prompt_and_stop_push_too() {
    let h = home();
    let m = mock_server();
    cfg(h.path(), &m.url);
    hook_with_pane(h.path(), "Notification", "notification_idle");
    let r = m.rx.recv_timeout(Duration::from_secs(5)).unwrap();
    assert_eq!(r.headers["title"], "Claude is waiting for input");
    hook_with_pane(h.path(), "Stop", "stop");
    let r = m.rx.recv_timeout(Duration::from_secs(5)).unwrap();
    assert_eq!(r.headers["title"], "Claude finished");
    assert!(!r.body.contains("All tests pass"), "{}", r.body);
}

#[test]
fn no_push_when_app_is_present() {
    let h = home();
    let m = mock_server();
    cfg(h.path(), &m.url);
    touch_presence(h.path());
    hook_with_pane(h.path(), "Notification", "notification_permission");
    hook_with_pane(h.path(), "Stop", "stop");
    assert!(m.rx.recv_timeout(Duration::from_millis(600)).is_err());
}

#[test]
fn no_push_for_other_events_or_other_notification_types() {
    let h = home();
    let m = mock_server();
    cfg(h.path(), &m.url);
    hook_with_pane(h.path(), "PreToolUse", "pre_tool_use");
    hook_with_pane(h.path(), "UserPromptSubmit", "user_prompt_submit");
    let mut c = agent(h.path());
    c.args(["hook", "Notification"]);
    run_with_stdin(
        c,
        r#"{"session_id":"s","notification_type":"auth_success","message":"ok"}"#,
    );
    assert!(m.rx.recv_timeout(Duration::from_millis(600)).is_err());
}

#[test]
fn no_push_when_ntfy_not_configured_and_hook_still_succeeds() {
    let h = home();
    hook_with_pane(h.path(), "Stop", "stop");
    assert_eq!(events(h.path()).len(), 1);
}

#[test]
fn push_failure_never_breaks_hook() {
    let h = home();
    cfg(h.path(), "http://127.0.0.1:1");
    hook_with_pane(h.path(), "Stop", "stop");
    let log = std::fs::read_to_string(h.path().join("agent.log")).unwrap_or_default();
    assert!(log.contains("ntfy"), "failure should be logged: {log:?}");
}
