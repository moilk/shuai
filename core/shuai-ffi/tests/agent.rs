use shuai_ffi::*;

const GOLDEN: &str = include_str!("../../shuai-agent/tests/fixtures/e2e-claude-2.1.288.jsonl");
const HOST: &str = "e2e-host";

fn lines() -> Vec<&'static str> {
    GOLDEN.lines().filter(|l| !l.trim().is_empty()).collect()
}

#[test]
fn classify_watch_lines() {
    assert_eq!(
        classify_watch_line(r#"{"type":"heartbeat"}"#.into()),
        FfiWatchLineKind::Heartbeat
    );
    assert_eq!(
        classify_watch_line(r#"{"type":"caught_up"}"#.into()),
        FfiWatchLineKind::CaughtUp
    );
    assert_eq!(
        classify_watch_line(lines()[0].into()),
        FfiWatchLineKind::Event
    );
    assert_eq!(classify_watch_line("garbage".into()), FfiWatchLineKind::Invalid);
}

#[test]
fn golden_transcript_replay_then_live() {
    let t = AgentTracker::new();
    let ls = lines();
    for l in &ls[..8] {
        t.ingest_replay(l.to_string()).unwrap();
    }
    assert_eq!(t.last_seq(HOST.into()), Some(8));
    let mut changes = Vec::new();
    for l in &ls[8..] {
        changes.extend(t.ingest_jsonl_line(l.to_string()).unwrap());
    }
    assert_eq!(t.last_seq(HOST.into()), Some(25));
    // The second request is announced live and later cleared.
    assert!(changes.iter().any(|c| matches!(
        c,
        FfiTrackerChange::PermissionRequested { request, .. }
            if request.request_id == "1a23454a068676828d4d9b715ce4f480"
                && request.tool_name == "Bash"
                && request.tool_input_json.contains("command")
    )));
    assert!(
        changes
            .iter()
            .any(|c| matches!(c, FfiTrackerChange::PermissionCleared { .. }))
    );
    let sessions = t.sessions();
    assert_eq!(sessions.len(), 1);
    let s = &sessions[0];
    assert_eq!(s.host, HOST);
    assert_eq!(s.session_id, "08a5dc1c-d8a0-49d8-bce4-62a495c70dab");
    assert_eq!(s.source, FfiAgentSource::Claude);
    assert_eq!(s.tmux_pane.as_deref(), Some("%0"));
    assert!(s.pending_permission.is_none());
    assert_eq!(s.model.as_deref(), Some("claude-opus-5-5"));
}

#[test]
fn replay_never_reports_changes_and_heartbeats_are_ignored() {
    let t = AgentTracker::new();
    assert!(
        t.ingest_jsonl_line(r#"{"type":"heartbeat"}"#.into())
            .unwrap()
            .is_empty()
    );
    assert!(t.ingest_jsonl_line("not json".into()).is_err());
    assert!(t.ingest_replay("{\"x\":".into()).is_err());
}

#[test]
fn pane_badges_attention_and_next() {
    let t = AgentTracker::new();
    for l in &lines()[..4] {
        t.ingest_jsonl_line(l.to_string()).unwrap();
    }
    assert_eq!(t.attention_count(), 1);
    assert_eq!(
        t.badge_for_pane(HOST.into(), "%0".into()),
        Some(FfiBadge::NeedsPermission)
    );
    assert_eq!(t.badge_for_pane(HOST.into(), "%9".into()), None);
    assert_eq!(t.badge_for_pane(HOST.into(), "bogus".into()), None);
    let s = t.session_for_pane(HOST.into(), "%0".into()).unwrap();
    assert!(s.pending_permission.is_some());
    let next = t.next_needing_attention(None).unwrap();
    assert_eq!(next.session_id, s.session_id);

    let topo = parse_topology(pane_text("%0")).unwrap();
    assert_eq!(
        t.badge_for_window(HOST.into(), topo.clone(), "@1".into()),
        Some(FfiBadge::NeedsPermission)
    );
    assert_eq!(t.badge_for_window(HOST.into(), topo, "@7".into()), None);

    // Pane gone from a fresh topology: the session ends.
    let other = parse_topology(pane_text("%5")).unwrap();
    let ch = t.reconcile_with_live_panes(HOST.into(), other, 1_791_018_700_000);
    assert!(
        ch.iter()
            .any(|c| matches!(c, FfiTrackerChange::SessionRemoved { .. }
                | FfiTrackerChange::StateChanged { to: FfiSessionState::Ended, .. }))
    );
    assert_eq!(t.attention_count(), 0);
}

#[test]
fn mark_seen_and_prune() {
    let t = AgentTracker::new();
    for l in &lines()[..8] {
        t.ingest_jsonl_line(l.to_string()).unwrap();
    }
    // Stop => Done, unseen.
    assert_eq!(t.attention_count(), 1);
    let key = FfiSessionKey {
        host: HOST.into(),
        session_id: "08a5dc1c-d8a0-49d8-bce4-62a495c70dab".into(),
    };
    assert!(t.mark_seen(key.clone()));
    assert!(!t.mark_seen(key));
    assert_eq!(t.attention_count(), 0);
    assert!(t.prune_ended(u64::MAX, 1).is_empty());
}

#[test]
fn claude_agents_json_reconcile() {
    let t = AgentTracker::new();
    for l in &lines()[..4] {
        t.ingest_jsonl_line(l.to_string()).unwrap();
    }
    let r = t.apply_claude_agents_json(
        HOST.into(),
        r#"[{"sessionId":"08a5dc1c-d8a0-49d8-bce4-62a495c70dab","status":"idle"}]"#.into(),
        1_791_018_700_000,
    );
    assert!(r.is_ok());
    assert!(t.apply_claude_agents_json(HOST.into(), "{nope".into(), 0).is_err());
}

fn pane_text(pane: &str) -> String {
    let us = '\u{1f}'.to_string();
    [
        "$0", "main", "1", "@1", "0", "zsh", "1", "*", pane, "0", "1", "claude", "/home/u", "123",
        "/dev/pts/1", "title", "80", "24",
    ]
    .join(&us)
        + "\n"
}

#[test]
fn probe_script_and_parse() {
    let s = probe_script();
    assert!(s.contains("__SHUAI_PROBE_BEGIN__"));
    let p = parse_probe(
        "banner\n__SHUAI_PROBE_BEGIN__\nuname_s=Linux\nuname_m=x86_64\nhome=/home/u\nshell=/bin/zsh\nclaude_path=/home/u/.local/bin/claude\ntmux_version=tmux 3.4\nagent_version=\nplugin_installed=0\ncodex_path=\ncodex_notify=\ntmux_conf_block=0\n__SHUAI_PROBE_END__\n".into(),
    );
    assert_eq!(p.uname_m, "x86_64");
    assert_eq!(p.claude_path.as_deref(), Some("/home/u/.local/bin/claude"));
    assert_eq!(p.tmux_version.as_deref(), Some("3.4"));
    assert!(!p.plugin_installed);
}

#[test]
fn install_plan_for_fresh_host() {
    let p = parse_probe(
        "__SHUAI_PROBE_BEGIN__\nuname_s=Linux\nuname_m=aarch64\nhome=/home/u\nclaude_path=/c/claude\ntmux_version=tmux 3.4\n__SHUAI_PROBE_END__\n".into(),
    );
    let steps = install_plan(p.clone(), "0.1.0".into());
    assert!(matches!(&steps[0], FfiInstallStep::MakeDirs { path } if path == "~/.shuai/bin"));
    assert!(matches!(&steps[1], FfiInstallStep::UploadAgent { target_triple, .. }
        if target_triple == "aarch64-unknown-linux-musl"));
    assert!(steps
        .iter()
        .any(|s| matches!(s, FfiInstallStep::InstallPluginViaCli { claude_path } if claude_path == "/c/claude")));
    assert!(steps
        .iter()
        .any(|s| matches!(s, FfiInstallStep::AppendTmuxConf { .. })));
    assert!(matches!(steps.last(), Some(FfiInstallStep::RunDoctor { agent_path })
        if agent_path == "/home/u/.shuai/bin/shuai-agent"));
    let unsupported = install_plan(
        FfiProbeResult {
            uname_s: "Plan9".into(),
            ..p
        },
        "0.1.0".into(),
    );
    assert!(matches!(unsupported[0], FfiInstallStep::Unsupported { .. }));
}

#[test]
fn install_plan_conflict_and_expand_tilde() {
    let p = parse_probe(
        "__SHUAI_PROBE_BEGIN__\nuname_s=Linux\nuname_m=x86_64\nhome=/home/u\ncodex_path=/c/codex\ncodex_notify=notify = [\"x\"]\n__SHUAI_PROBE_END__\n".into(),
    );
    let steps = install_plan(p, "0.1.0".into());
    assert!(steps
        .iter()
        .any(|s| matches!(s, FfiInstallStep::CodexNotifyConflict { existing, .. } if existing.contains("notify"))));
    assert_eq!(expand_tilde("~/.shuai/bin".into(), "/home/u".into()), "/home/u/.shuai/bin");
    assert_eq!(expand_tilde("/abs".into(), "/home/u".into()), "/abs");
}

#[test]
fn command_builders() {
    assert_eq!(
        permission_response_command("abc-1".into(), true, None).unwrap(),
        "~/.shuai/bin/shuai-agent respond abc-1 allow"
    );
    assert_eq!(
        permission_response_command("abc-1".into(), false, Some("no way".into())).unwrap(),
        "~/.shuai/bin/shuai-agent respond abc-1 deny --message='no way'"
    );
    assert!(permission_response_command("a;b".into(), true, None).is_err());
    assert_eq!(watch_command(7), "~/.shuai/bin/shuai-agent watch --since 7");
    assert_eq!(
        claude_agents_command("/c/claude".into()),
        "/c/claude agents --json"
    );
}

#[test]
fn plugin_and_settings_helpers() {
    let files = plugin_bundle();
    assert_eq!(files.len(), 3);
    assert_eq!(plugin_marketplace_dir(), "~/.shuai/plugin-marketplace");
    assert_eq!(
        local_plugin_install_commands("/c/claude".into(), "/home/u".into()).len(),
        2
    );
    assert_eq!(plugin_uninstall_commands("/c/claude".into()).len(), 2);
    let merged = merge_claude_settings("{}".into(), "/a/shuai-agent".into()).unwrap();
    assert!(merged.contains("/a/shuai-agent"));
    let removed = remove_claude_settings_hooks(merged).unwrap();
    assert!(!removed.contains("shuai-agent"));
    assert!(merge_claude_settings("[".into(), "/a".into()).is_err());
    let lines = vec!["# >>> shuai >>>".to_string(), "# <<< shuai <<<".to_string()];
    assert!(append_tmux_block_command("~/.tmux.conf".into(), lines).contains("grep -qF"));
    assert!(remove_tmux_block_command("~/.tmux.conf".into()).contains("sed -i"));
    assert!(plugin_install_commands("/c/claude".into())[0].contains("moilk/shuai"));
}
