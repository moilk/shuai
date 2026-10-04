//! Remote command builders, plugin bundle and settings.json merge used by the app installer.

mod common;
use common::*;
use serde_json::{Value, json};
use shuai_agentkit::AgentTracker;
use shuai_agentkit::remote::*;
use std::process::Command;

fn sh(script: &str) -> (bool, String) {
    let out = Command::new("sh").arg("-c").arg(script).output().unwrap();
    (
        out.status.success(),
        String::from_utf8_lossy(&out.stdout).into_owned(),
    )
}

#[test]
fn respond_command_quotes_everything() {
    assert_eq!(
        respond_command("req-1", true, None).unwrap(),
        "~/.shuai/bin/shuai-agent respond req-1 allow"
    );
    assert_eq!(
        respond_command("req_2", false, Some("it's no; rm -rf /")).unwrap(),
        "~/.shuai/bin/shuai-agent respond req_2 deny --message='it'\\''s no; rm -rf /'"
    );
    // The command actually round-trips through a shell (printf stands in for the agent).
    let cmd = respond_command("r", false, Some("a'b $x `y`")).unwrap();
    let probe = cmd.replace("~/.shuai/bin/shuai-agent", "printf '%s|'");
    assert_eq!(sh(&probe).1, "respond|r|deny|--message=a'b $x `y`|");
}

#[test]
fn respond_command_rejects_bad_ids() {
    for bad in ["", "a b", "../x", "x;y", &"a".repeat(129)] {
        assert!(respond_command(bad, true, None).is_err(), "{bad:?}");
    }
}

#[test]
fn watch_and_agents_commands() {
    assert_eq!(watch_command(0), "~/.shuai/bin/shuai-agent watch --since 0");
    assert_eq!(
        watch_command(42),
        "~/.shuai/bin/shuai-agent watch --since 42"
    );
    assert_eq!(
        claude_agents_command("/home/u/.local/bin/claude"),
        "/home/u/.local/bin/claude agents --json"
    );
    assert_eq!(
        claude_agents_command("/opt/my dir/claude"),
        "'/opt/my dir/claude' agents --json"
    );
}

#[test]
fn plugin_bundle_matches_repo_files() {
    let files = plugin_bundle();
    let paths: Vec<&str> = files.iter().map(|f| f.path.as_str()).collect();
    assert_eq!(
        paths,
        [
            ".claude-plugin/marketplace.json",
            "plugin/.claude-plugin/plugin.json",
            "plugin/hooks/hooks.json"
        ]
    );
    for f in &files {
        serde_json::from_str::<Value>(&f.contents).expect("valid json");
    }
    let m: Value = serde_json::from_str(&files[0].contents).unwrap();
    assert_eq!(m["name"], "shuai");
    assert_eq!(m["plugins"][0]["source"], "./plugin");
    assert_eq!(PLUGIN_MARKETPLACE_DIR, "~/.shuai/plugin-marketplace");
}

#[test]
fn local_plugin_commands() {
    assert_eq!(
        local_plugin_install_commands("/home/u/.local/bin/claude", "/home/u"),
        vec![
            "/home/u/.local/bin/claude plugin marketplace add /home/u/.shuai/plugin-marketplace",
            "/home/u/.local/bin/claude plugin install shuai@shuai",
        ]
    );
    assert_eq!(
        plugin_uninstall_commands("/c/claude"),
        vec![
            "/c/claude plugin uninstall shuai@shuai",
            "/c/claude plugin marketplace remove shuai",
        ]
    );
}

#[test]
fn tmux_block_append_is_idempotent_and_removable() {
    let d = tempfile::tempdir().unwrap();
    let f = d.path().join("tmux.conf");
    std::fs::write(&f, "set -g mouse on\n").unwrap();
    let lines = vec![
        "# >>> shuai >>>".to_string(),
        "set -g set-titles on".into(),
        "it's".into(),
        "# <<< shuai <<<".into(),
    ];
    let append = append_tmux_block_command(f.to_str().unwrap(), &lines);
    assert!(sh(&append).0);
    assert!(sh(&append).0);
    let text = std::fs::read_to_string(&f).unwrap();
    assert_eq!(
        text,
        "set -g mouse on\n# >>> shuai >>>\nset -g set-titles on\nit's\n# <<< shuai <<<\n"
    );
    assert!(sh(&remove_tmux_block_command(f.to_str().unwrap())).0);
    assert_eq!(std::fs::read_to_string(&f).unwrap(), "set -g mouse on\n");
    // Removing from a missing file is not an error.
    assert!(sh(&remove_tmux_block_command("/nonexistent/x/tmux.conf")).0);
}

#[test]
fn append_tmux_block_creates_missing_file() {
    let d = tempfile::tempdir().unwrap();
    let f = d.path().join("new.conf");
    let lines = vec!["# >>> shuai >>>".to_string(), "# <<< shuai <<<".into()];
    assert!(sh(&append_tmux_block_command(f.to_str().unwrap(), &lines)).0);
    assert!(
        std::fs::read_to_string(&f)
            .unwrap()
            .contains("# >>> shuai >>>")
    );
}

const AGENT: &str = "/home/u/.shuai/bin/shuai-agent";

#[test]
fn merge_settings_into_empty_and_missing() {
    for input in ["", "  ", "{}"] {
        let out = merge_claude_settings(input, AGENT).unwrap();
        let v: Value = serde_json::from_str(&out).unwrap();
        let stop = &v["hooks"]["Stop"][0]["hooks"][0];
        assert_eq!(stop["type"], "command");
        assert_eq!(stop["async"], true);
        assert_eq!(
            stop["command"],
            format!("[ -x \"{AGENT}\" ] || exit 0; exec \"{AGENT}\" hook Stop")
        );
        let perm = &v["hooks"]["PermissionRequest"][0]["hooks"][0];
        assert!(perm.get("async").is_none());
        assert_eq!(perm["timeout"], 120);
    }
}

#[test]
fn merge_settings_preserves_user_content_and_is_idempotent() {
    let existing = json!({
        "model": "opus",
        "hooks": {
            "Stop": [{"hooks": [{"type": "command", "command": "echo mine"}]}],
            "PreCompact": [{"hooks": [{"type": "command", "command": "echo c"}]}]
        }
    })
    .to_string();
    let once = merge_claude_settings(&existing, AGENT).unwrap();
    let twice = merge_claude_settings(&once, AGENT).unwrap();
    assert_eq!(once, twice);
    let v: Value = serde_json::from_str(&once).unwrap();
    assert_eq!(v["model"], "opus");
    assert_eq!(v["hooks"]["PreCompact"][0]["hooks"][0]["command"], "echo c");
    let stop = v["hooks"]["Stop"].as_array().unwrap();
    assert_eq!(stop.len(), 2);
    assert_eq!(stop[0]["hooks"][0]["command"], "echo mine");
}

#[test]
fn merge_settings_survives_a_hostile_agent_path() {
    let d = tempfile::tempdir().unwrap();
    let dir = d.path().join("ho me/it's \"q\" $X `y` \\z");
    std::fs::create_dir_all(&dir).unwrap();
    let agent = dir.join("shuai-agent");
    std::fs::write(&agent, "#!/bin/sh\nprintf '%s|' \"$@\"\n").unwrap();
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(&agent, std::fs::Permissions::from_mode(0o755)).unwrap();
    let out = merge_claude_settings("{}", agent.to_str().unwrap()).unwrap();
    let v: Value = serde_json::from_str(&out).expect("still valid JSON");
    let cmd = v["hooks"]["Stop"][0]["hooks"][0]["command"]
        .as_str()
        .unwrap();
    assert_eq!(sh(cmd).1, "hook|Stop|");
}

#[test]
fn remove_settings_hooks_keeps_user_hooks_sharing_a_group_and_empty_arrays() {
    let existing = json!({
        "hooks": {
            "Stop": [{"hooks": [
                {"type": "command", "command": "echo mine"},
                {"type": "command", "command": "\"/h/.shuai/bin/shuai-agent\" hook Stop"}
            ]}],
            "Empty": []
        }
    })
    .to_string();
    let v: Value = serde_json::from_str(&remove_claude_settings_hooks(&existing).unwrap()).unwrap();
    assert_eq!(
        v,
        json!({"hooks": {
            "Stop": [{"hooks": [{"type": "command", "command": "echo mine"}]}],
            "Empty": []
        }})
    );
}

#[test]
fn tmux_block_append_after_unterminated_last_line_and_remove_without_end_marker() {
    let d = tempfile::tempdir().unwrap();
    let f = d.path().join("it's a dir/tmux.conf");
    std::fs::create_dir_all(f.parent().unwrap()).unwrap();
    std::fs::write(&f, "set -g mouse on").unwrap(); // no trailing newline
    let lines = vec!["# >>> shuai >>>".to_string(), "# <<< shuai <<<".into()];
    assert!(sh(&append_tmux_block_command(f.to_str().unwrap(), &lines)).0);
    assert_eq!(
        std::fs::read_to_string(&f).unwrap(),
        "set -g mouse on\n# >>> shuai >>>\n# <<< shuai <<<\n"
    );
    assert!(sh(&remove_tmux_block_command(f.to_str().unwrap())).0);
    assert_eq!(std::fs::read_to_string(&f).unwrap(), "set -g mouse on\n");
    // A begin marker whose end marker is missing must not eat the rest of the file.
    std::fs::write(&f, "a\n# >>> shuai >>>\nb\nc\n").unwrap();
    assert!(sh(&remove_tmux_block_command(f.to_str().unwrap())).0);
    assert_eq!(
        std::fs::read_to_string(&f).unwrap(),
        "a\n# >>> shuai >>>\nb\nc\n"
    );
    assert!(!f.with_extension("conf.shuai-bak").exists());
}

#[test]
fn merge_settings_rejects_garbage_and_non_objects() {
    assert!(merge_claude_settings("{not json", AGENT).is_err());
    assert!(merge_claude_settings("[1]", AGENT).is_err());
    assert!(merge_claude_settings(r#"{"hooks": 3}"#, AGENT).is_err());
}

#[test]
fn remove_settings_hooks_only_removes_ours() {
    let existing = json!({
        "model": "opus",
        "hooks": {"Stop": [{"hooks": [{"type": "command", "command": "echo mine"}]}]}
    })
    .to_string();
    let merged = merge_claude_settings(&existing, AGENT).unwrap();
    let removed = remove_claude_settings_hooks(&merged).unwrap();
    assert_eq!(
        serde_json::from_str::<Value>(&removed).unwrap(),
        serde_json::from_str::<Value>(&existing).unwrap()
    );
    // Only our hooks: the hooks key disappears entirely.
    let only = merge_claude_settings("{}", AGENT).unwrap();
    let v: Value = serde_json::from_str(&remove_claude_settings_hooks(&only).unwrap()).unwrap();
    assert!(v.get("hooks").is_none());
}

#[test]
fn pending_permission_exposes_tool_input() {
    let mut t = AgentTracker::new();
    t.ingest(&start(1));
    t.ingest(&perm_req(
        2,
        "r1",
        "Edit",
        json!({"file_path":"/a","old_string":"x","new_string":"y"}),
    ));
    let s = &t.sessions()[0];
    let p = s.pending_permission.as_ref().unwrap();
    assert_eq!(p.tool_input()["new_string"], "y");
}

#[test]
fn removing_the_block_deletes_a_file_that_is_left_empty() {
    let d = tempfile::tempdir().unwrap();
    let f = d.path().join("created-by-install.conf");
    let lines = vec![
        "# >>> shuai >>>".to_string(),
        "set -g x on".into(),
        "# <<< shuai <<<".into(),
    ];
    assert!(sh(&append_tmux_block_command(f.to_str().unwrap(), &lines)).0);
    assert!(f.exists());
    assert!(sh(&remove_tmux_block_command(f.to_str().unwrap())).0);
    assert!(!f.exists(), "an install-created file that ends up empty is removed");
    // a file with other content is kept
    std::fs::write(&f, "keep\n").unwrap();
    assert!(sh(&append_tmux_block_command(f.to_str().unwrap(), &lines)).0);
    assert!(sh(&remove_tmux_block_command(f.to_str().unwrap())).0);
    assert_eq!(std::fs::read_to_string(&f).unwrap(), "keep\n");
}
