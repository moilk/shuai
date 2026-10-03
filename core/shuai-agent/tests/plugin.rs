mod common;
use common::*;
use serde_json::Value;
use std::path::PathBuf;
use std::process::{Command, Stdio};

fn repo() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..")
}

fn json(rel: &str) -> Value {
    let p = repo().join(rel);
    serde_json::from_str(&std::fs::read_to_string(&p).unwrap_or_else(|e| panic!("{p:?}: {e}")))
        .unwrap()
}

const ASYNC_EVENTS: [&str; 9] = [
    "SessionStart",
    "SessionEnd",
    "UserPromptSubmit",
    "PreToolUse",
    "PostToolUse",
    "Notification",
    "Stop",
    "SubagentStop",
    "StopFailure",
];

fn command_of(event: &str) -> (String, Value) {
    let hooks = json("plugin/hooks/hooks.json");
    let entry = &hooks["hooks"][event];
    assert_eq!(entry.as_array().unwrap().len(), 1, "{event}");
    let h = entry[0]["hooks"][0].clone();
    assert_eq!(h["type"], "command");
    (h["command"].as_str().unwrap().to_string(), h)
}

#[test]
fn manifest_has_required_fields() {
    let m = json("plugin/.claude-plugin/plugin.json");
    assert_eq!(m["name"], "shuai");
    assert_eq!(m["version"], env!("CARGO_PKG_VERSION"));
    assert!(m["description"].as_str().unwrap().len() > 10);
    assert_eq!(m["author"]["name"], "moilk");
    assert_eq!(m["license"], "MIT");
}

#[test]
fn async_hooks_registered() {
    for e in ASYNC_EVENTS {
        let (cmd, h) = command_of(e);
        assert_eq!(h["async"], true, "{e} must be async");
        assert!(h["timeout"].as_u64().unwrap() <= 30, "{e}");
        assert!(cmd.contains(&format!("hook {e}")), "{e}: {cmd}");
        assert!(cmd.contains("$HOME/.shuai/bin/shuai-agent"), "{e}: {cmd}");
        assert!(cmd.contains("[ -x"), "guard missing: {cmd}");
        assert!(cmd.contains("|| exit 0"), "guard must exit 0: {cmd}");
    }
}

#[test]
fn permission_request_is_sync_with_120s_timeout() {
    let (cmd, h) = command_of("PermissionRequest");
    assert!(h.get("async").is_none() || h["async"] == false);
    assert_eq!(h["timeout"], 120);
    assert!(cmd.contains("hook PermissionRequest"));
    assert!(cmd.contains("--timeout 110"), "agent waits less than the hook timeout: {cmd}");
}

#[test]
fn no_unexpected_events() {
    let hooks = json("plugin/hooks/hooks.json");
    let mut names: Vec<_> = hooks["hooks"].as_object().unwrap().keys().cloned().collect();
    names.sort();
    let mut want: Vec<String> = ASYNC_EVENTS.iter().map(|s| s.to_string()).collect();
    want.push("PermissionRequest".into());
    want.sort();
    assert_eq!(names, want);
}

#[test]
fn marketplace_lists_plugin() {
    let m = json(".claude-plugin/marketplace.json");
    assert_eq!(m["name"], "shuai");
    assert_eq!(m["owner"]["name"], "moilk");
    let p = &m["plugins"][0];
    assert_eq!(p["name"], "shuai");
    assert_eq!(p["source"], "./plugin");
    assert!(repo().join("plugin/.claude-plugin/plugin.json").exists());
}

fn run_hook_command(cmd: &str, home: &std::path::Path, state: &std::path::Path) -> std::process::Output {
    let mut c = Command::new("sh");
    c.arg("-c")
        .arg(cmd)
        .env("HOME", home)
        .env("SHUAI_HOME", state)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    run_with_stdin(c, &fixture("stop"))
}

#[test]
fn command_runs_installed_binary() {
    let h = home();
    let bin = h.path().join(".shuai/bin");
    std::fs::create_dir_all(&bin).unwrap();
    std::os::unix::fs::symlink(BIN, bin.join("shuai-agent")).unwrap();
    let state = h.path().join(".shuai");
    let (cmd, _) = command_of("Stop");
    let out = run_hook_command(&cmd, h.path(), &state);
    assert_eq!(out.status.code(), Some(0));
    assert_eq!(events(&state).len(), 1);
}

#[test]
fn command_is_silent_noop_when_binary_missing() {
    let h = home();
    let (cmd, _) = command_of("PermissionRequest");
    let out = run_hook_command(&cmd, h.path(), &h.path().join(".shuai"));
    assert_eq!(out.status.code(), Some(0));
    assert!(out.stdout.is_empty());
    assert!(out.stderr.is_empty());
}
