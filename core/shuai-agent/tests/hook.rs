mod common;
use common::*;
use serde_json::Value;

#[test]
fn version_flag_prints_version() {
    let out = std::process::Command::new(BIN)
        .arg("--version")
        .output()
        .unwrap();
    assert!(out.status.success());
    assert_eq!(
        String::from_utf8(out.stdout).unwrap().trim(),
        format!("shuai-agent {}", env!("CARGO_PKG_VERSION"))
    );
}

#[test]
fn hook_appends_envelope_with_context() {
    let h = home();
    let mut c = agent(h.path());
    c.arg("hook")
        .arg("Stop")
        .env("TMUX_PANE", "%5")
        .env("TMUX", "/tmp/tmux-1000/default,1234,0");
    let out = run_with_stdin(c, &fixture("stop"));
    assert!(out.status.success());
    assert!(out.stdout.is_empty(), "async hooks must print nothing");

    let evs = events(h.path());
    assert_eq!(evs.len(), 1);
    let e = &evs[0];
    assert_eq!(e["v"], 1);
    assert_eq!(e["seq"], 1);
    assert_eq!(e["host"], "test-host");
    assert_eq!(e["source"], "claude");
    assert_eq!(e["tmux"]["pane"], "%5");
    assert_eq!(e["tmux"]["socket"], "/tmp/tmux-1000/default");
    assert_eq!(e["pid"], std::process::id());
    assert!(e["ts_ms"].as_u64().unwrap() > 1_600_000_000_000);
    assert_eq!(e["event"]["type"], "stop");
    assert_eq!(e["event"]["last_assistant_message"], "All tests pass now.");
    assert_eq!(e["event"]["raw"]["hook_event_name"], "Stop");

    // and it round-trips through the shared proto types
    let env: shuai_proto::Envelope = serde_json::from_value(e.clone()).unwrap();
    assert_eq!(env.event.kind(), "stop");
}

#[test]
fn hook_without_tmux_omits_tmux() {
    let h = home();
    hook(h.path(), "SessionStart", &fixture("session_start"), &[]);
    let evs = events(h.path());
    assert!(evs[0].get("tmux").is_none());
    assert_eq!(evs[0]["event"]["type"], "session_start");
}

#[test]
fn seq_is_monotonic_across_invocations() {
    let h = home();
    for _ in 0..5 {
        hook(h.path(), "Stop", &fixture("stop"), &[]);
    }
    assert_eq!(seqs(&events(h.path())), vec![1, 2, 3, 4, 5]);
}

#[test]
fn seq_recovers_when_counter_file_is_lost() {
    let h = home();
    for _ in 0..3 {
        hook(h.path(), "Stop", &fixture("stop"), &[]);
    }
    for f in ["seq", "events.seq"] {
        let _ = std::fs::remove_file(h.path().join(f));
    }
    hook(h.path(), "Stop", &fixture("stop"), &[]);
    assert_eq!(seqs(&events(h.path())), vec![1, 2, 3, 4]);
}

#[test]
fn unknown_event_is_recorded_as_other() {
    let h = home();
    hook(h.path(), "PreCompact", &fixture("future_event"), &[]);
    let e = &events(h.path())[0]["event"];
    assert_eq!(e["type"], "other");
    assert_eq!(e["name"], "PreCompact");
    assert_eq!(e["raw"]["trigger"], "auto");
}

#[test]
fn post_tool_use_drops_tool_response_from_raw() {
    let h = home();
    hook(h.path(), "PostToolUse", &fixture("post_tool_use"), &[]);
    let e = &events(h.path())[0]["event"];
    assert_eq!(e["type"], "post_tool_use");
    assert!(e["raw"].get("tool_response").is_none());
    assert_eq!(e["tool_input"]["command"], "cargo test --workspace");
}

#[test]
fn oversized_payload_raw_is_truncated() {
    let h = home();
    let big = "x".repeat(600_000);
    let payload = format!(r#"{{"session_id":"s","prompt":"{big}"}}"#);
    hook(h.path(), "UserPromptSubmit", &payload, &[]);
    let line = std::fs::read_to_string(h.path().join("events.jsonl")).unwrap();
    assert!(line.len() < 300_000, "line was {} bytes", line.len());
    let v: Value = serde_json::from_str(line.trim_end()).unwrap();
    assert_eq!(v["event"]["type"], "user_prompt_submit");
}

#[test]
fn hook_never_fails_on_bad_stdin() {
    let h = home();
    let out = hook(h.path(), "Stop", "this is not json", &[]);
    assert_eq!(out.status.code(), Some(0));
    assert!(out.stdout.is_empty());
    let log = std::fs::read_to_string(h.path().join("agent.log")).unwrap();
    assert!(!log.is_empty());
}

#[test]
fn hook_never_fails_on_empty_stdin() {
    let h = home();
    let out = hook(h.path(), "Stop", "", &[]);
    assert_eq!(out.status.code(), Some(0));
    assert!(out.stdout.is_empty());
}

#[test]
fn hook_never_fails_when_state_dir_is_unusable() {
    let h = home();
    let blocker = h.path().join("file");
    std::fs::write(&blocker, "x").unwrap();
    // SHUAI_HOME points *under* a regular file: cannot be created.
    let out = hook(&blocker.join("sub"), "Stop", &fixture("stop"), &[]);
    assert_eq!(out.status.code(), Some(0));
    assert!(out.stdout.is_empty());
}

#[test]
fn hook_with_bad_arguments_still_exits_zero() {
    let h = home();
    let mut c = agent(h.path());
    c.args(["hook", "Stop", "--no-such-flag"]);
    let out = run_with_stdin(c, "{}");
    assert_eq!(out.status.code(), Some(0), "exit 2 would block Claude");
    assert!(out.stdout.is_empty());
}

#[test]
fn concurrent_hooks_never_interleave_lines() {
    let h = home();
    let n = 40;
    let big = "y".repeat(20_000);
    let payload =
        format!(r#"{{"session_id":"s","hook_event_name":"UserPromptSubmit","prompt":"{big}"}}"#);
    let handles: Vec<_> = (0..n)
        .map(|_| {
            let p = h.path().to_path_buf();
            let payload = payload.clone();
            std::thread::spawn(move || hook(&p, "UserPromptSubmit", &payload, &[]))
        })
        .collect();
    for t in handles {
        assert!(t.join().unwrap().status.success());
    }
    let evs = events(h.path()); // panics on any corrupt line
    let mut s = seqs(&evs);
    assert_eq!(s.len(), n);
    s.sort_unstable();
    assert_eq!(s, (1..=n as u64).collect::<Vec<_>>());
    // file order == seq order
    assert_eq!(seqs(&evs), (1..=n as u64).collect::<Vec<_>>());
}

#[test]
fn log_rotates_when_too_big() {
    let h = home();
    for _ in 0..30 {
        let mut c = agent(h.path());
        c.args(["hook", "Stop"]).env("SHUAI_MAX_LOG_BYTES", "3000");
        run_with_stdin(c, &fixture("stop"));
    }
    assert!(h.path().join("events.jsonl.1").exists());
    let size = std::fs::metadata(h.path().join("events.jsonl"))
        .unwrap()
        .len();
    assert!(size < 6000, "main file is {size}");
    let s = seqs(&events(h.path()));
    assert_eq!(*s.last().unwrap(), 30);
    assert!(s.windows(2).all(|w| w[1] == w[0] + 1), "contiguous: {s:?}");
}
