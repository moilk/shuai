mod common;
use common::*;
use serde_json::Value;
use std::time::Duration;

#[test]
fn codex_notify_records_turn_complete() {
    let h = home();
    let mut c = agent(h.path());
    c.arg("codex-notify")
        .arg(fixture("codex_notify"))
        .env("TMUX_PANE", "%2");
    let out = c.output().unwrap();
    assert_eq!(out.status.code(), Some(0));
    let evs = events(h.path());
    assert_eq!(evs.len(), 1);
    assert_eq!(evs[0]["source"], "codex");
    assert_eq!(evs[0]["tmux"]["pane"], "%2");
    assert_eq!(evs[0]["event"]["type"], "agent_turn_complete");
    assert_eq!(
        evs[0]["event"]["thread_id"],
        "b5f6c1c2-9e5c-4a7e-8f1a-2f4f0f3c9d11"
    );
    assert_eq!(
        evs[0]["event"]["last_assistant_message"],
        "Renamed foo to bar across 4 files."
    );
}

#[test]
fn codex_notify_bad_json_exits_zero() {
    let h = home();
    let out = agent(h.path())
        .args(["codex-notify", "{nope"])
        .output()
        .unwrap();
    assert_eq!(out.status.code(), Some(0));
    assert!(events(h.path()).is_empty());
}

#[test]
fn codex_notify_pushes_when_app_absent() {
    let h = home();
    let m = mock_server();
    write_config(
        h.path(),
        &format!("[ntfy]\nserver = \"{}\"\ntopic = \"t\"\n", m.url),
    );
    agent(h.path())
        .arg("codex-notify")
        .arg(fixture("codex_notify"))
        .output()
        .unwrap();
    let r = m.rx.recv_timeout(Duration::from_secs(5)).unwrap();
    assert!(r.body.contains("Renamed foo"));
}

#[test]
fn doctor_reports_json() {
    let h = home();
    write_config(h.path(), "[ntfy]\nserver = \"http://x\"\ntopic = \"t\"\n");
    let out = agent(h.path())
        .arg("doctor")
        .env("SHELL", "/bin/sh")
        .output()
        .unwrap();
    assert!(out.status.success());
    let v: Value = serde_json::from_slice(&out.stdout).unwrap();
    assert_eq!(v["version"], env!("CARGO_PKG_VERSION"));
    assert_eq!(v["protocol"], 1);
    assert_eq!(v["state_dir"], h.path().to_str().unwrap());
    assert_eq!(v["state_dir_writable"], true);
    assert_eq!(v["ntfy_configured"], true);
    for k in [
        "claude_path",
        "plugin_installed",
        "tmux_version",
        "tmux_allow_passthrough",
        "arch",
        "os",
    ] {
        assert!(v.get(k).is_some(), "missing key {k}: {v}");
    }
}

#[test]
fn doctor_without_config_and_missing_state_dir() {
    let h = home();
    let sub = h.path().join("fresh");
    let out = agent(&sub)
        .arg("doctor")
        .env("SHELL", "/bin/sh")
        .output()
        .unwrap();
    assert!(out.status.success());
    let v: Value = serde_json::from_slice(&out.stdout).unwrap();
    assert_eq!(v["ntfy_configured"], false);
    assert_eq!(
        v["state_dir_writable"], true,
        "doctor creates the state dir"
    );
}

#[test]
fn doctor_finds_claude_via_login_shell() {
    let h = home();
    let bin = h.path().join("bin");
    std::fs::create_dir_all(&bin).unwrap();
    let fake = bin.join("claude");
    std::fs::write(&fake, "#!/bin/sh\necho fake\n").unwrap();
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(&fake, std::fs::Permissions::from_mode(0o755)).unwrap();
    // a fake $SHELL that ignores -l and exposes our dir on PATH
    let sh = h.path().join("fakesh");
    std::fs::write(
        &sh,
        format!(
            "#!/bin/sh\nPATH={}:$PATH\nshift\nexec /bin/sh -c \"$@\"\n",
            bin.display()
        ),
    )
    .unwrap();
    std::fs::set_permissions(&sh, std::fs::Permissions::from_mode(0o755)).unwrap();
    let out = agent(&h.path().join("state"))
        .arg("doctor")
        .env("SHELL", &sh)
        .output()
        .unwrap();
    let v: Value = serde_json::from_slice(&out.stdout).unwrap();
    assert_eq!(v["claude_path"], fake.to_str().unwrap());
}

#[test]
fn doctor_detects_installed_plugin() {
    let h = home();
    let fake_home = h.path().join("fakehome");
    let dir = fake_home.join(".claude/plugins");
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(
        dir.join("installed_plugins.json"),
        r#"{"version":2,"plugins":{"shuai@shuai":[{"scope":"user"}]}}"#,
    )
    .unwrap();
    let out = agent(&h.path().join("state"))
        .arg("doctor")
        .env("HOME", &fake_home)
        .env("SHELL", "/bin/sh")
        .output()
        .unwrap();
    let v: Value = serde_json::from_slice(&out.stdout).unwrap();
    assert_eq!(v["plugin_installed"], true);
}

#[test]
fn doctor_falls_back_to_known_install_locations() {
    // `claude` is often put on PATH only by ~/.zshrc, which a login shell does not read.
    let h = home();
    let fake_home = h.path().join("fakehome");
    let bin = fake_home.join(".local/bin");
    std::fs::create_dir_all(&bin).unwrap();
    let fake = bin.join("claude");
    std::fs::write(&fake, "#!/bin/sh\n").unwrap();
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(&fake, std::fs::Permissions::from_mode(0o755)).unwrap();
    let out = agent(&h.path().join("state"))
        .arg("doctor")
        .env("HOME", &fake_home)
        .env("SHELL", "/bin/sh")
        .env("PATH", "/usr/bin:/bin")
        .output()
        .unwrap();
    let v: Value = serde_json::from_slice(&out.stdout).unwrap();
    assert_eq!(v["claude_path"], fake.to_str().unwrap());
}
