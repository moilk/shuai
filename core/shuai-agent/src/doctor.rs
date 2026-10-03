//! `shuai-agent doctor`: environment self-check, printed as JSON.

use crate::state::State;
use serde_json::{Value, json};
use std::path::PathBuf;
use std::process::Command;

fn out_of(cmd: &mut Command) -> Option<String> {
    let o = cmd.output().ok()?;
    if !o.status.success() {
        return None;
    }
    Some(String::from_utf8_lossy(&o.stdout).trim().to_string())
}

/// `claude` usually only lives on the login-shell PATH (~/.local/bin).
fn find_claude() -> Option<String> {
    let shell = std::env::var("SHELL").unwrap_or_else(|_| "/bin/sh".into());
    let out = out_of(Command::new(shell).args(["-lc", "command -v claude"]))?;
    out.lines()
        .rev()
        .find(|l| l.starts_with('/'))
        .map(str::to_string)
}

fn claude_dir() -> PathBuf {
    if let Some(d) = std::env::var_os("CLAUDE_CONFIG_DIR") {
        return PathBuf::from(d);
    }
    PathBuf::from(std::env::var_os("HOME").unwrap_or_default()).join(".claude")
}

fn plugin_installed() -> bool {
    let dir = claude_dir();
    let has = |rel: &str, needle: &str| {
        std::fs::read_to_string(dir.join(rel))
            .map(|s| s.contains(needle))
            .unwrap_or(false)
    };
    has("plugins/installed_plugins.json", "\"shuai@") || has("settings.json", "shuai-agent")
}

fn writable(state: &State) -> bool {
    if state.ensure().is_err() {
        return false;
    }
    let p = state.dir.join(".doctor-probe");
    let ok = std::fs::write(&p, b"ok").is_ok();
    let _ = std::fs::remove_file(p);
    ok
}

pub fn report(state: &State) -> Value {
    let cfg = state.config();
    let last_seq = std::fs::read_to_string(state.seq_path())
        .ok()
        .and_then(|s| s.trim().parse::<u64>().ok());
    json!({
        "version": shuai_proto::version(),
        "protocol": shuai_proto::PROTOCOL_VERSION,
        "os": std::env::consts::OS,
        "arch": std::env::consts::ARCH,
        "binary": std::env::current_exe().ok().map(|p| p.display().to_string()),
        "state_dir": state.dir.display().to_string(),
        "state_dir_writable": writable(state),
        "last_seq": last_seq,
        "app_present": state.present(),
        "claude_path": find_claude(),
        "plugin_installed": plugin_installed(),
        "tmux_version": out_of(Command::new("tmux").arg("-V")),
        "tmux_allow_passthrough": out_of(Command::new("tmux").args(["show-options", "-gv", "allow-passthrough"])),
        "ntfy_configured": cfg.ntfy.is_some(),
    })
}
