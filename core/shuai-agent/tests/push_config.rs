//! The config file the Swift app renders must be understood by the agent.
mod common;
use common::*;
use std::time::Duration;

/// `fixtures/agent-config/hostile.toml` is asserted byte for byte by the app's tests
/// (`AgentConfigTomlTests`); here the agent must parse it and behave as intended.
#[test]
fn app_rendered_hostile_config_parses() {
    let h = home();
    let m = mock_server();
    let golden = std::fs::read_to_string(format!(
        "{}/../../fixtures/agent-config/hostile.toml",
        env!("CARGO_MANIFEST_DIR")
    ))
    .unwrap()
    .replace("https://ntfy.example.com", &m.url);
    write_config(h.path(), &golden);
    let mut c = agent(h.path());
    c.args(["hook", "Stop"])
        .env("TMUX_PANE", "%5")
        .env("TMUX", "/tmp/tmux-1000/default,1,0");
    run_with_stdin(c, r#"{"session_id":"s","hook_event_name":"Stop"}"#);
    let r = m.rx.recv_timeout(Duration::from_secs(5)).unwrap();
    // control characters are dropped from the label, everything else survives
    assert_eq!(r.body, "a\"b\\cü");
    assert_eq!(r.headers["authorization"], "Bearer tk\"\\x");
    assert_eq!(r.request_line, "POST /shuai-abc HTTP/1.1");
    assert_eq!(
        r.headers["click"],
        "shuai://open?host=11111111-2222-3333-4444-555555555555&pane=%255"
    );
}
