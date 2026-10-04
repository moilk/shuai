//! Status-only push payloads, dedupe, rate limit, click URLs.
mod common;
use common::*;
use std::path::Path;
use std::time::Duration;

fn cfg(h: &Path, url: &str) {
    write_config(
        h,
        &format!("[ntfy]\nserver = \"{url}\"\ntopic = \"my-topic\"\n"),
    );
}

struct Env<'a> {
    pane: Option<&'a str>,
    path: Option<&'a Path>,
    interval: &'a str,
}

fn fire(h: &Path, event: &str, json: &str, e: &Env) -> std::process::Output {
    let mut c = agent(h);
    if event == "codex" {
        c.args(["codex-notify", json]);
    } else {
        c.args(["hook", event]);
    }
    if let Some(p) = e.pane {
        c.env("TMUX_PANE", p)
            .env("TMUX", "/tmp/tmux-1000/default,1,0");
    }
    if let Some(p) = e.path {
        c.env("PATH", format!("{}:/usr/bin:/bin", p.display()));
    }
    c.env("SHUAI_PUSH_MIN_INTERVAL_SECS", e.interval);
    run_with_stdin(c, if event == "codex" { "" } else { json })
}

const E0: Env = Env {
    pane: Some("%5"),
    path: None,
    interval: "0",
};

fn ev(name: &str, sid: &str, extra: &str) -> String {
    format!(
        r#"{{"session_id":"{sid}","hook_event_name":"{name}","cwd":"/home/SECRETCWD/proj"{extra}}}"#
    )
}

fn recv(m: &Mock) -> Req {
    m.rx.recv_timeout(Duration::from_secs(5)).expect("a push")
}

fn none(m: &Mock) {
    assert!(
        m.rx.recv_timeout(Duration::from_millis(700)).is_err(),
        "unexpected extra push"
    );
}

const PERM_PROMPT: &str = r#","notification_type":"permission_prompt","message":"x""#;
const IDLE_PROMPT: &str = r#","notification_type":"idle_prompt","message":"x""#;
const PERM_REQ: &str = r#","tool_name":"Bash","tool_input":{"command":"ls"}"#;

#[test]
fn payload_titles_priorities_and_status_only_bodies() {
    let h = home();
    let m = mock_server();
    cfg(h.path(), &m.url);
    let cases: Vec<(&str, String, &str, &str)> = vec![
        (
            "Notification",
            ev("Notification", "a", PERM_PROMPT),
            "Claude needs approval",
            "high",
        ),
        (
            "Notification",
            ev("Notification", "b", IDLE_PROMPT),
            "Claude is waiting for input",
            "default",
        ),
        ("Stop", ev("Stop", "c", ""), "Claude finished", "default"),
        (
            "StopFailure",
            ev(
                "StopFailure",
                "d",
                r#","error_type":"rate_limit","error_message":"x""#,
            ),
            "Claude stopped with an error",
            "default",
        ),
        (
            "PermissionRequest",
            ev("PermissionRequest", "e", PERM_REQ),
            "Claude needs approval",
            "high",
        ),
    ];
    for (event, json, title, prio) in cases {
        let out = fire(h.path(), event, &json, &E0);
        assert_eq!(out.status.code(), Some(0));
        let r = recv(&m);
        assert_eq!(r.headers["title"], title);
        assert_eq!(r.headers["priority"], prio);
        assert!(r.headers.contains_key("tags"));
        assert_eq!(r.body, "test-host");
    }
    fire(
        h.path(),
        "codex",
        r#"{"type":"agent-turn-complete","thread-id":"t","turn-id":"1","cwd":"/x","input-messages":["hi"],"last-assistant-message":"yo"}"#,
        &E0,
    );
    let r = recv(&m);
    assert_eq!(r.headers["title"], "Codex finished");
    assert_eq!(r.body, "test-host");
}

#[test]
fn no_event_content_ever_reaches_the_ntfy_request() {
    let h = home();
    let m = mock_server();
    cfg(h.path(), &m.url);
    let extra = |kind: &str| -> String {
        format!(
            r#","prompt":"SECRETPROMPT","user_prompt":"SECRETPROMPT","tool_name":"SECRETTOOL","tool_input":{{"command":"SECRETCMD","file_path":"/SECRETPATH"}},"last_assistant_message":"SECRETREPLY","message":"SECRETMSG","error_message":"SECRETERR","notification_type":"{kind}""#
        )
    };
    let jobs = [
        (
            "Notification",
            ev("Notification", "n1", &extra("permission_prompt")),
        ),
        (
            "Notification",
            ev("Notification", "n2", &extra("idle_prompt")),
        ),
        ("Stop", ev("Stop", "n3", &extra("x"))),
        ("StopFailure", ev("StopFailure", "n4", &extra("x"))),
        (
            "PermissionRequest",
            ev("PermissionRequest", "n5", &extra("x")),
        ),
    ];
    let mut n = 0;
    for (event, json) in &jobs {
        fire(h.path(), event, json, &E0);
        n += 1;
    }
    fire(
        h.path(),
        "codex",
        r#"{"type":"agent-turn-complete","thread-id":"SECRETTHREAD","turn-id":"1","cwd":"/SECRETCWD","input-messages":["SECRETPROMPT"],"last-assistant-message":"SECRETREPLY"}"#,
        &E0,
    );
    n += 1;
    for _ in 0..n {
        let r = recv(&m);
        let mut all = format!("{}\n{}\n", r.request_line, r.body);
        for (k, v) in &r.headers {
            all.push_str(&format!("{k}: {v}\n"));
        }
        assert!(!all.contains("SECRET"), "event content leaked: {all}");
        assert!(!all.contains("/home/"), "cwd leaked: {all}");
    }
    none(&m);
}

fn fake_tmux(dir: &Path, script: &str) {
    let p = dir.join("tmux");
    std::fs::write(&p, format!("#!/bin/sh\n{script}\n")).unwrap();
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(&p, std::fs::Permissions::from_mode(0o755)).unwrap();
}

#[test]
fn body_has_host_and_tmux_session_and_window_index() {
    let h = home();
    let bin = home();
    let m = mock_server();
    cfg(h.path(), &m.url);
    let log = bin.path().join("args");
    fake_tmux(
        bin.path(),
        &format!("echo \"$@\" > {}\necho 'main › 2'", log.display()),
    );
    let e = Env {
        pane: Some("%5"),
        path: Some(bin.path()),
        interval: "0",
    };
    fire(h.path(), "Stop", &ev("Stop", "s", ""), &e);
    let r = recv(&m);
    assert_eq!(r.body, "test-host · main › 2");
    let args = std::fs::read_to_string(log).unwrap();
    assert!(args.contains("display-message -p -t %5"), "{args}");
    assert!(args.contains("#{session_name}"), "{args}");
    assert!(
        !args.contains("window_name"),
        "window names are opt-in: {args}"
    );
}

#[test]
fn host_name_from_config_is_the_host_label() {
    let h = home();
    let m = mock_server();
    write_config(
        h.path(),
        &format!(
            "host_name = \"devbox\"\nhost_id = \"x\"\n[ntfy]\nserver = \"{}\"\ntopic = \"t\"\n",
            m.url
        ),
    );
    fire(h.path(), "Stop", &ev("Stop", "s", ""), &E0);
    assert_eq!(recv(&m).body, "devbox");
}

#[test]
fn hanging_or_failing_tmux_falls_back_to_host_only_quickly() {
    for script in ["sleep 30", "exit 1", "printf '\\033[31m\\n'"] {
        let h = home();
        let bin = home();
        let m = mock_server();
        cfg(h.path(), &m.url);
        fake_tmux(bin.path(), script);
        let e = Env {
            pane: Some("%5"),
            path: Some(bin.path()),
            interval: "0",
        };
        let t0 = std::time::Instant::now();
        fire(h.path(), "Stop", &ev("Stop", "s", ""), &e);
        assert!(t0.elapsed() < Duration::from_secs(4), "{script}");
        assert_eq!(recv(&m).body, "test-host", "{script}");
    }
}

#[test]
fn click_url_is_percent_encoded() {
    let h = home();
    let m = mock_server();
    write_config(
        h.path(),
        &format!(
            "host_id = \"my host&x=1#\"\n[ntfy]\nserver = \"{}\"\ntopic = \"t\"\n",
            m.url
        ),
    );
    let e = Env {
        pane: Some("%12"),
        path: None,
        interval: "0",
    };
    fire(h.path(), "Stop", &ev("Stop", "s", ""), &e);
    assert_eq!(
        recv(&m).headers["click"],
        "shuai://open?host=my%20host%26x%3D1%23&pane=%2512"
    );
}

#[test]
fn no_click_without_tmux_pane() {
    let h = home();
    let m = mock_server();
    cfg(h.path(), &m.url);
    let e = Env {
        pane: None,
        path: None,
        interval: "0",
    };
    fire(h.path(), "Stop", &ev("Stop", "s", ""), &e);
    assert!(!recv(&m).headers.contains_key("click"));
}

#[test]
fn permission_request_and_prompt_notification_pair_pushes_once() {
    let h = home();
    let m = mock_server();
    cfg(h.path(), &m.url);
    let e = Env {
        pane: Some("%5"),
        path: None,
        interval: "10",
    };
    fire(
        h.path(),
        "PermissionRequest",
        &ev("PermissionRequest", "s1", PERM_REQ),
        &e,
    );
    assert_eq!(recv(&m).headers["title"], "Claude needs approval");
    fire(
        h.path(),
        "Notification",
        &ev("Notification", "s1", PERM_PROMPT),
        &e,
    );
    none(&m);
    // the pairing is consumed: a later prompt notification pushes again
    fire(
        h.path(),
        "Notification",
        &ev("Notification", "s1", PERM_PROMPT),
        &e,
    );
    assert_eq!(recv(&m).headers["title"], "Claude needs approval");
}

#[test]
fn notification_before_request_also_pairs() {
    let h = home();
    let m = mock_server();
    cfg(h.path(), &m.url);
    let e = Env {
        pane: Some("%5"),
        path: None,
        interval: "10",
    };
    fire(
        h.path(),
        "Notification",
        &ev("Notification", "s1", PERM_PROMPT),
        &e,
    );
    recv(&m);
    fire(
        h.path(),
        "PermissionRequest",
        &ev("PermissionRequest", "s1", PERM_REQ),
        &e,
    );
    none(&m);
}

#[test]
fn rate_limit_one_push_per_session_per_window_except_approvals() {
    let h = home();
    let m = mock_server();
    cfg(h.path(), &m.url);
    let e = Env {
        pane: Some("%5"),
        path: None,
        interval: "10",
    };
    fire(h.path(), "Stop", &ev("Stop", "s1", ""), &e);
    recv(&m);
    // same session within the window: dropped (idle and stop alike)
    fire(h.path(), "Stop", &ev("Stop", "s1", ""), &e);
    fire(
        h.path(),
        "Notification",
        &ev("Notification", "s1", IDLE_PROMPT),
        &e,
    );
    none(&m);
    // approvals are exempt
    fire(
        h.path(),
        "PermissionRequest",
        &ev("PermissionRequest", "s1", PERM_REQ),
        &e,
    );
    assert_eq!(recv(&m).headers["title"], "Claude needs approval");
    // another session is independent
    fire(h.path(), "Stop", &ev("Stop", "s2", ""), &e);
    recv(&m);
}

#[test]
fn rate_limit_window_expires() {
    let h = home();
    let m = mock_server();
    cfg(h.path(), &m.url);
    let e = Env {
        pane: Some("%5"),
        path: None,
        interval: "1",
    };
    fire(h.path(), "Stop", &ev("Stop", "s1", ""), &e);
    recv(&m);
    std::thread::sleep(Duration::from_millis(1200));
    fire(h.path(), "Stop", &ev("Stop", "s1", ""), &e);
    recv(&m);
}

#[test]
fn hostile_config_values_parse_and_arrive_intact() {
    let h = home();
    let m = mock_server();
    write_config(
        h.path(),
        &format!(
            "host_name = \"a\\\"b\\\\c\"\nhost_id = \"id\"\n[ntfy]\nserver = \"{}\"\ntopic = \"t\"\ntoken = \"tk\\\"\\\\x\"\n",
            m.url
        ),
    );
    fire(h.path(), "Stop", &ev("Stop", "s", ""), &E0);
    let r = recv(&m);
    assert_eq!(r.body, "a\"b\\c");
    assert_eq!(r.headers["authorization"], "Bearer tk\"\\x");
}
