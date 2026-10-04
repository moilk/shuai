//! Privacy and robustness of the push path: window names, secrets in logs, file modes,
//! gate corruption and lock contention.
mod common;
use common::*;
use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::time::{Duration, Instant};

const TOPIC: &str = "shuai-SECRETTOPICxyz";
const TOKEN: &str = "tk_SECRETTOKENabc";

fn cfg_with(h: &Path, server: &str, extra_ntfy: &str) {
    write_config(
        h,
        &format!(
            "[ntfy]\nserver = \"{server}\"\ntopic = \"{TOPIC}\"\ntoken = \"{TOKEN}\"\n{extra_ntfy}"
        ),
    );
}

fn fake_tmux(dir: &Path, script: &str) {
    let p = dir.join("tmux");
    std::fs::write(&p, format!("#!/bin/sh\n{script}\n")).unwrap();
    std::fs::set_permissions(&p, std::fs::Permissions::from_mode(0o755)).unwrap();
}

fn stop(h: &Path, bin: Option<&Path>) -> std::process::Output {
    let mut c = agent(h);
    c.args(["hook", "Stop"])
        .env("TMUX_PANE", "%5")
        .env("TMUX", "/tmp/tmux-1000/default,1,0")
        .env("SHUAI_PUSH_MIN_INTERVAL_SECS", "0");
    if let Some(b) = bin {
        c.env("PATH", format!("{}:/usr/bin:/bin", b.display()));
    }
    run_with_stdin(c, r#"{"session_id":"s","hook_event_name":"Stop"}"#)
}

/// A tmux that expands the requested format like the real one, for a window auto-renamed to a
/// sensitive command ($5 is the format: display-message -p -t PANE FORMAT).
const SMART_TMUX: &str = r#"
out=$(printf '%s' "$5" | sed -e 's/#{session_name}/main/' -e 's/#{window_index}/2/' -e 's/#{window_name}/vim secrets.env/')
echo "$out"
"#;

#[test]
fn window_name_is_not_sent_by_default() {
    let h = home();
    let bin = home();
    let m = mock_server();
    cfg_with(h.path(), &m.url, "");
    fake_tmux(bin.path(), SMART_TMUX);
    stop(h.path(), Some(bin.path()));
    let r = m.rx.recv_timeout(Duration::from_secs(5)).unwrap();
    assert_eq!(r.body, "test-host · main › 2");
    assert!(!r.body.contains("vim") && !r.body.contains("secrets"));
}

#[test]
fn window_name_is_sent_only_when_opted_in() {
    let h = home();
    let bin = home();
    let m = mock_server();
    cfg_with(h.path(), &m.url, "window_names = true\n");
    fake_tmux(bin.path(), SMART_TMUX);
    stop(h.path(), Some(bin.path()));
    let r = m.rx.recv_timeout(Duration::from_secs(5)).unwrap();
    assert_eq!(r.body, "test-host · main › 2: vim secrets.env");
}

fn assert_no_secrets(h: &Path, extra: &str) {
    let mut all = extra.to_string();
    for entry in std::fs::read_dir(h).unwrap() {
        let p = entry.unwrap().path();
        if p.file_name().unwrap() == "config.toml" {
            continue;
        }
        if let Ok(s) = std::fs::read_to_string(&p) {
            all.push_str(&s);
        }
    }
    assert!(!all.contains("SECRETTOPIC"), "topic leaked: {all}");
    assert!(!all.contains("SECRETTOKEN"), "token leaked: {all}");
}

#[test]
fn failing_server_never_puts_topic_or_token_in_agent_log() {
    let closed = {
        let l = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        format!("http://{}", l.local_addr().unwrap())
    };
    for server in [
        closed.as_str(),
        "http://nonexistent.invalid",
        "http://[::1",
        "ht!tp://x",
    ] {
        let h = home();
        cfg_with(h.path(), server, "");
        stop(h.path(), None);
        assert!(std::fs::read_to_string(h.path().join("agent.log")).is_ok_and(|s| !s.is_empty()));
        assert_no_secrets(h.path(), "");
    }
}

#[test]
fn broken_config_never_logs_its_contents() {
    let h = home();
    // a syntax error right after the token: toml's message would quote the line
    write_config(
        h.path(),
        &format!(
            "[ntfy]\nserver = \"http://x\"\ntopic = \"{TOPIC}\"\ntoken = \"{TOKEN}\" garbage\n"
        ),
    );
    stop(h.path(), None);
    let log = std::fs::read_to_string(h.path().join("agent.log")).unwrap();
    assert!(log.contains("config.toml"), "{log}");
    assert_no_secrets(h.path(), "");
}

#[test]
fn notify_and_doctor_never_print_topic_or_token() {
    let h = home();
    let closed = {
        let l = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        format!("http://{}", l.local_addr().unwrap())
    };
    cfg_with(h.path(), &closed, "");
    let mut c = agent(h.path());
    c.args(["notify", "--title", "t", "--body", "b"]);
    let o = run_with_stdin(c, "");
    assert!(!o.status.success());
    let text = format!(
        "{}{}",
        String::from_utf8_lossy(&o.stdout),
        String::from_utf8_lossy(&o.stderr)
    );
    assert_no_secrets(h.path(), &text);
    let mut c = agent(h.path());
    c.arg("doctor");
    let o = run_with_stdin(c, "");
    let text = String::from_utf8_lossy(&o.stdout).into_owned();
    assert!(text.contains("\"ntfy_configured\": true"), "{text}");
    assert_no_secrets(h.path(), &text);
}

#[test]
fn http_error_status_is_logged_without_secrets() {
    use std::io::{Read, Write};
    let l = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let url = format!("http://{}", l.local_addr().unwrap());
    std::thread::spawn(move || {
        for s in l.incoming() {
            let mut s = s.unwrap();
            let mut buf = [0u8; 4096];
            let _ = s.read(&mut buf);
            let _ = s.write_all(
                b"HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
            );
        }
    });
    let h = home();
    cfg_with(h.path(), &url, "");
    stop(h.path(), None);
    assert_no_secrets(h.path(), "");
}

#[test]
fn config_and_state_dir_are_tightened_to_private_modes() {
    let h = home();
    let m = mock_server();
    let dir = h.path().join("state");
    std::fs::create_dir(&dir).unwrap();
    std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o755)).unwrap();
    cfg_with(&dir, &m.url, "");
    std::fs::set_permissions(
        dir.join("config.toml"),
        std::fs::Permissions::from_mode(0o644),
    )
    .unwrap();
    stop(&dir, None);
    m.rx.recv_timeout(Duration::from_secs(5)).unwrap();
    let mode = |p: &Path| std::fs::metadata(p).unwrap().permissions().mode() & 0o777;
    assert_eq!(mode(&dir), 0o700);
    assert_eq!(mode(&dir.join("config.toml")), 0o600);
}

#[test]
fn doctor_tightens_a_loose_config() {
    let h = home();
    cfg_with(h.path(), "http://x", "");
    std::fs::set_permissions(
        h.path().join("config.toml"),
        std::fs::Permissions::from_mode(0o666),
    )
    .unwrap();
    let mut c = agent(h.path());
    c.arg("doctor");
    run_with_stdin(c, "");
    let m = std::fs::metadata(h.path().join("config.toml")).unwrap();
    assert_eq!(m.permissions().mode() & 0o777, 0o600);
}

#[test]
fn corrupt_gate_files_recover_and_still_push() {
    for junk in [
        "not json",
        "[]",
        "{\"s\": 5}",
        "{\"s\": {\"last\": \"x\"}}",
        "{\"s\": {\"last\": 99999999999999999}}", // a timestamp from the future
        "{\"s\": null}",
        "",
    ] {
        let h = home();
        let m = mock_server();
        cfg_with(h.path(), &m.url, "");
        std::fs::write(h.path().join("push.json"), junk).unwrap();
        let mut c = agent(h.path());
        c.args(["hook", "Stop"]);
        run_with_stdin(c, r#"{"session_id":"s","hook_event_name":"Stop"}"#);
        m.rx.recv_timeout(Duration::from_secs(5))
            .unwrap_or_else(|_| panic!("no push with gate {junk:?}"));
        let s = std::fs::read_to_string(h.path().join("push.json")).unwrap();
        assert!(
            serde_json::from_str::<serde_json::Value>(&s).is_ok_and(|v| v.is_object()),
            "{junk:?}"
        );
    }
}

#[test]
fn a_held_gate_lock_delays_the_hook_only_briefly_and_the_push_still_goes_out() {
    let h = home();
    let m = mock_server();
    cfg_with(h.path(), &m.url, "");
    let lock = std::fs::File::create(h.path().join("push.lock")).unwrap();
    lock.lock().unwrap();
    let t0 = Instant::now();
    let mut c = agent(h.path());
    c.args(["hook", "PermissionRequest"]);
    run_with_stdin(
        c,
        r#"{"session_id":"s","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"ls"}}"#,
    );
    let took = t0.elapsed();
    assert!(took < Duration::from_millis(900), "hook blocked {took:?}");
    m.rx.recv_timeout(Duration::from_secs(5))
        .expect("fail open: push anyway");
}

#[test]
fn concurrent_approvals_never_lose_or_duplicate_pushes() {
    let h = home();
    let m = mock_server();
    cfg_with(h.path(), &m.url, "");
    // 6 sessions x (PermissionRequest + its permission_prompt notification) at once.
    let mut rxs = Vec::new();
    for i in 0..6 {
        let mut c = agent(h.path());
        c.args(["hook", "PermissionRequest"]);
        rxs.push(spawn_hook(
            c,
            format!(
                r#"{{"session_id":"s{i}","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{{"command":"ls"}}}}"#
            ),
        ));
        let mut c = agent(h.path());
        c.args(["hook", "Notification"]);
        rxs.push(spawn_hook(
            c,
            format!(
                r#"{{"session_id":"s{i}","hook_event_name":"Notification","notification_type":"permission_prompt","message":"x"}}"#
            ),
        ));
    }
    for rx in rxs {
        rx.recv_timeout(Duration::from_secs(20)).unwrap();
    }
    let mut n = 0;
    while m.rx.recv_timeout(Duration::from_millis(700)).is_ok() {
        n += 1;
    }
    assert_eq!(n, 6, "one push per session");
}
