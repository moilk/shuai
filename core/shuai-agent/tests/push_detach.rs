//! Pushes are fire-and-forget: a slow ntfy never delays a hook (the PermissionRequest hook is
//! synchronous: Claude waits for it before showing its local dialog).
mod common;
use common::*;
use std::io::Read;
use std::process::Stdio;
use std::time::{Duration, Instant};

const TOPIC: &str = "shuai-DETACHTOPICxyz";
const TOKEN: &str = "tk_DETACHTOKENabc";

fn cfg(h: &std::path::Path, url: &str) {
    write_config(
        h,
        &format!("[ntfy]\nserver = \"{url}\"\ntopic = \"{TOPIC}\"\ntoken = \"{TOKEN}\"\n"),
    );
}

/// Every process command line on the machine.
fn all_cmdlines() -> String {
    let out = std::process::Command::new("ps")
        .args(["-axww", "-o", "command="])
        .output()
        .unwrap();
    String::from_utf8_lossy(&out.stdout).into_owned()
}

#[test]
fn permission_request_without_app_returns_fast_and_pushes_in_background() {
    let h = home();
    let m = mock_server_delayed(Duration::from_secs(5));
    cfg(h.path(), &m.url);

    let mut c = agent(h.path());
    c.args(["hook", "PermissionRequest"])
        .env("TMUX_PANE", "%5")
        .env("TMUX", "/tmp/tmux-1000/default,1,0")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    let t0 = Instant::now();
    let mut child = c.spawn().unwrap();
    {
        use std::io::Write;
        let mut si = child.stdin.take().unwrap();
        let _ = si.write_all(fixture("permission_request").as_bytes());
    }
    // The reader gets EOF on both pipes as soon as the hook exits, not when the push child does.
    let (mut out, mut err) = (Vec::new(), Vec::new());
    child.stdout.take().unwrap().read_to_end(&mut out).unwrap();
    child.stderr.take().unwrap().read_to_end(&mut err).unwrap();
    let status = child.wait().unwrap();
    let took = t0.elapsed();
    assert!(status.success());
    assert!(out.is_empty(), "no stdout: {out:?}");
    assert!(took < Duration::from_millis(300), "hook took {took:?}");

    // The push child is alive, and neither topic nor token is on any command line.
    let r = m.rx.recv_timeout(Duration::from_secs(5)).expect("a push");
    assert_eq!(r.request_line, format!("POST /{TOPIC} HTTP/1.1"));
    assert_eq!(r.headers["authorization"], format!("Bearer {TOKEN}"));
    assert_eq!(r.body, "test-host");
    let ps = all_cmdlines();
    assert!(
        ps.lines().any(|l| l.contains("push-send")),
        "push child should still be waiting on the server:\n{ps}"
    );
    assert!(!ps.contains(TOPIC), "topic on argv");
    assert!(!ps.contains(TOKEN), "token on argv");

    // exactly one request
    assert!(m.rx.recv_timeout(Duration::from_millis(800)).is_err());
}

#[test]
fn every_hook_and_codex_notify_detach() {
    for (args, stdin) in [
        (
            vec!["hook", "Stop"],
            r#"{"session_id":"s","hook_event_name":"Stop"}"#,
        ),
        (
            vec!["hook", "Notification"],
            r#"{"session_id":"s","notification_type":"idle_prompt","message":"x"}"#,
        ),
        (
            vec!["codex-notify", r#"{"type":"agent-turn-complete"}"#],
            "",
        ),
    ] {
        let h = home();
        let m = mock_server_delayed(Duration::from_secs(3));
        cfg(h.path(), &m.url);
        let mut c = agent(h.path());
        c.args(&args).env("SHUAI_PUSH_MIN_INTERVAL_SECS", "0");
        let t0 = Instant::now();
        let out = run_with_stdin(c, stdin);
        assert!(t0.elapsed() < Duration::from_millis(1500), "{args:?}");
        assert!(out.status.success());
        assert!(
            m.rx.recv_timeout(Duration::from_secs(5)).is_ok(),
            "{args:?}"
        );
    }
}
