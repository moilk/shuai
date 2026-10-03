mod common;
use common::*;
use serde_json::json;
use shuai_agentkit::{AgentTracker, SessionKey, SessionState, TrackerChange};
use shuai_proto::{Envelope, Source};
use shuai_tmux::PaneId;

fn key() -> SessionKey {
    SessionKey::new(HOST, SID)
}

fn state(t: &AgentTracker) -> SessionState {
    t.session(&key()).unwrap().state.clone()
}

fn working(tool: Option<&str>) -> SessionState {
    SessionState::Working {
        tool: tool.map(str::to_string),
    }
}

#[test]
fn basic_lifecycle() {
    let mut t = AgentTracker::new();
    t.ingest(&start(1));
    assert_eq!(state(&t), SessionState::Starting);
    let s = t.session(&key()).unwrap();
    assert_eq!(s.source, Source::Claude);
    assert_eq!(s.cwd.as_deref(), Some("/w"));
    assert_eq!(s.model.as_deref(), Some("opus"));
    assert_eq!(s.tmux_pane, Some(PaneId(0)));
    assert_eq!(s.tmux_socket.as_deref(), Some("/tmp/tmux-1000/default"));
    assert_eq!(s.started_at, 1000);

    t.ingest(&prompt(2, "hello"));
    assert_eq!(state(&t), working(None));
    assert_eq!(
        t.session(&key()).unwrap().last_prompt.as_deref(),
        Some("hello")
    );
    t.ingest(&pre(3, "Bash"));
    assert_eq!(state(&t), working(Some("Bash")));
    assert_eq!(
        t.session(&key()).unwrap().current_tool.as_deref(),
        Some("Bash")
    );
    t.ingest(&post(4, "Bash"));
    assert_eq!(state(&t), working(None));
    assert_eq!(t.session(&key()).unwrap().current_tool, None);
    t.ingest(&stop(5, "all done"));
    assert_eq!(state(&t), SessionState::Done);
    assert_eq!(
        t.session(&key()).unwrap().last_message.as_deref(),
        Some("all done")
    );
    assert_eq!(t.session(&key()).unwrap().updated_at, 5000);
    t.ingest(&end(6));
    assert_eq!(state(&t), SessionState::Ended);
}

#[test]
fn resume_start_is_done_and_seen() {
    let mut t = AgentTracker::new();
    t.ingest(&ev(
        1,
        json!({"type":"session_start","source":"resume","cwd":"/w"}),
    ));
    assert_eq!(state(&t), SessionState::Done);
    assert!(t.session(&key()).unwrap().seen);
    assert_eq!(t.attention_count(), 0);
}

#[test]
fn session_created_from_midstream_event() {
    let mut t = AgentTracker::new();
    t.ingest(&pre(7, "Read"));
    assert_eq!(state(&t), working(Some("Read")));
    assert_eq!(t.session(&key()).unwrap().started_at, 7000);
}

#[test]
fn permission_flow_allowed() {
    let mut t = AgentTracker::new();
    t.ingest(&start(1));
    t.ingest(&pre(2, "Bash"));
    let ch = t.ingest(&perm_req(3, "r1", "Bash", json!({"command":"touch x"})));
    assert_eq!(state(&t), SessionState::NeedsPermission);
    let p = t
        .session(&key())
        .unwrap()
        .pending_permission
        .clone()
        .unwrap();
    assert_eq!(p.request_id, "r1");
    assert_eq!(p.tool_name, "Bash");
    assert_eq!(p.input_preview, "touch x");
    assert_eq!(p.since, 3000);
    assert!(ch.contains(&TrackerChange::PermissionRequested {
        key: key(),
        request: p.clone()
    }));
    assert!(ch.contains(&TrackerChange::StateChanged {
        key: key(),
        from: working(Some("Bash")),
        to: SessionState::NeedsPermission
    }));

    // Notification:permission_prompt after the request keeps pending.
    let ch = t.ingest(&notif(4, "permission_prompt"));
    assert!(ch.is_empty());
    assert!(t.session(&key()).unwrap().pending_permission.is_some());

    let ch = t.ingest(&resolved(5, "r1", "allowed"));
    assert_eq!(state(&t), working(None));
    assert!(t.session(&key()).unwrap().pending_permission.is_none());
    assert!(ch.contains(&TrackerChange::PermissionCleared { key: key() }));
}

#[test]
fn permission_denied_goes_working_then_stop() {
    let mut t = AgentTracker::new();
    t.ingest(&pre(1, "Bash"));
    t.ingest(&perm_req(2, "r1", "Bash", json!({"command":"rm x"})));
    t.ingest(&resolved(3, "r1", "denied"));
    assert_eq!(state(&t), working(None));
    // a denied tool produces no post_tool_use; Stop follows
    t.ingest(&stop(4, "denied"));
    assert_eq!(state(&t), SessionState::Done);
}

#[test]
fn timeout_and_not_present_stay_needs_permission_until_post_tool_use() {
    for outcome in ["timeout", "not_present"] {
        let mut t = AgentTracker::new();
        t.ingest(&pre(1, "Bash"));
        t.ingest(&perm_req(2, "r1", "Bash", json!({"command":"x"})));
        let ch = t.ingest(&resolved(3, "r1", outcome));
        assert_eq!(state(&t), SessionState::NeedsPermission, "{outcome}");
        assert!(t.session(&key()).unwrap().pending_permission.is_none());
        assert_eq!(ch, vec![TrackerChange::PermissionCleared { key: key() }]);
        t.ingest(&notif(4, "permission_prompt"));
        assert_eq!(state(&t), SessionState::NeedsPermission);
        t.ingest(&post(5, "Bash"));
        assert_eq!(state(&t), working(None));
    }
}

#[test]
fn timeout_then_stop_is_done() {
    let mut t = AgentTracker::new();
    t.ingest(&perm_req(1, "r1", "Bash", json!({})));
    t.ingest(&resolved(2, "r1", "timeout"));
    t.ingest(&stop(3, "x"));
    assert_eq!(state(&t), SessionState::Done);
}

#[test]
fn notification_permission_prompt_without_request_has_no_card() {
    let mut t = AgentTracker::new();
    t.ingest(&pre(1, "Bash"));
    let ch = t.ingest(&notif(2, "permission_prompt"));
    assert_eq!(state(&t), SessionState::NeedsPermission);
    assert!(t.session(&key()).unwrap().pending_permission.is_none());
    assert!(
        !ch.iter()
            .any(|c| matches!(c, TrackerChange::PermissionRequested { .. }))
    );
}

#[test]
fn pending_permission_survives_parallel_tool_events() {
    let mut t = AgentTracker::new();
    t.ingest(&perm_req(1, "r1", "Bash", json!({"command":"x"})));
    t.ingest(&pre(2, "Read"));
    assert_eq!(state(&t), SessionState::NeedsPermission);
    t.ingest(&post(3, "Read"));
    assert_eq!(state(&t), SessionState::NeedsPermission);
    assert!(t.session(&key()).unwrap().pending_permission.is_some());
}

#[test]
fn idle_prompt_needs_input_and_prompt_resumes() {
    let mut t = AgentTracker::new();
    t.ingest(&stop(1, "x"));
    t.ingest(&notif(2, "idle_prompt"));
    assert_eq!(state(&t), SessionState::NeedsInput);
    t.ingest(&prompt(3, "go"));
    assert_eq!(state(&t), working(None));
}

#[test]
fn stop_failure_sets_failed() {
    let mut t = AgentTracker::new();
    t.ingest(&prompt(1, "x"));
    t.ingest(&ev(
        2,
        json!({"type":"stop_failure","error_type":"rate_limit","error_message":"429 slow down"}),
    ));
    assert_eq!(
        state(&t),
        SessionState::Failed {
            error: "429 slow down".into()
        }
    );
    t.ingest(&ev(
        3,
        json!({"type":"stop_failure","error_type":"billing"}),
    ));
    assert_eq!(
        state(&t),
        SessionState::Failed {
            error: "billing".into()
        }
    );
}

#[test]
fn codex_turn_complete_is_done() {
    let mut t = AgentTracker::new();
    let mut e = env(
        "h2",
        1,
        5000,
        Some("%3"),
        json!({"type":"agent_turn_complete","thread_id":"th1","cwd":"/c","input_messages":["a","fix it"],"last_assistant_message":"fixed"}),
    );
    e.source = Source::Codex;
    t.ingest(&e);
    let s = t.session(&SessionKey::new("h2", "th1")).unwrap();
    assert_eq!(s.state, SessionState::Done);
    assert_eq!(s.source, Source::Codex);
    assert_eq!(s.cwd.as_deref(), Some("/c"));
    assert_eq!(s.last_prompt.as_deref(), Some("fix it"));
    assert_eq!(s.last_message.as_deref(), Some("fixed"));
    assert_eq!(s.tmux_pane, Some(PaneId(3)));
}

#[test]
fn unknown_event_is_ignored() {
    let mut t = AgentTracker::new();
    t.ingest(&prompt(1, "x"));
    let ch = t.ingest(&ev(2, json!({"type":"something_new","session_id":SID})));
    assert!(ch.is_empty());
    assert_eq!(state(&t), working(None));
}

#[test]
fn truncation_is_char_safe() {
    let mut t = AgentTracker::new();
    let long: String = "你".repeat(500);
    t.ingest(&prompt(1, &long));
    let p = t.session(&key()).unwrap().last_prompt.clone().unwrap();
    assert!(p.chars().count() <= 201);
    assert!(p.ends_with('…'));
    t.ingest(&perm_req(2, "r", "Bash", json!({"command": long})));
    let pv = t
        .session(&key())
        .unwrap()
        .pending_permission
        .clone()
        .unwrap()
        .input_preview;
    assert!(pv.chars().count() <= 201);
}

#[test]
fn input_preview_per_tool() {
    let mut t = AgentTracker::new();
    t.ingest(&perm_req(
        1,
        "a",
        "Edit",
        json!({"file_path":"/a/b.rs","old_string":"x","new_string":"y"}),
    ));
    let pv = |t: &AgentTracker| {
        t.session(&key())
            .unwrap()
            .pending_permission
            .clone()
            .unwrap()
            .input_preview
    };
    assert_eq!(pv(&t), "/a/b.rs");
    t.ingest(&perm_req(2, "b", "mcp__x__y", json!({"q":1})));
    assert_eq!(pv(&t), r#"{"q":1}"#);
}

// ---------- subagent quirk ----------

#[test]
fn subagent_events_do_not_change_parent_state() {
    let mut t = AgentTracker::new();
    t.ingest(&stop(1, "done"));
    assert_eq!(state(&t), SessionState::Done);
    let before = t.session(&key()).unwrap().updated_at;
    t.ingest(&ev(
        2,
        json!({"type":"pre_tool_use","tool_name":"Bash","tool_input":{},"agent_id":"a1"}),
    ));
    assert_eq!(state(&t), SessionState::Done);
    assert_eq!(t.session(&key()).unwrap().active_subagents, 1);
    t.ingest(&ev(
        3,
        json!({"type":"subagent_stop","agent_id":"a1","agent_type":""}),
    ));
    assert_eq!(state(&t), SessionState::Done);
    assert_eq!(t.session(&key()).unwrap().active_subagents, 0);
    assert_eq!(t.session(&key()).unwrap().updated_at, before);
    assert_eq!(t.session(&key()).unwrap().current_tool, None);
}

#[test]
fn subagent_permission_request_still_needs_user() {
    let mut t = AgentTracker::new();
    t.ingest(&prompt(1, "x"));
    t.ingest(&ev(
        2,
        json!({"type":"permission_request","request_id":"r","tool_name":"Bash","tool_input":{"command":"c"},"agent_id":"a1"}),
    ));
    assert_eq!(state(&t), SessionState::NeedsPermission);
}

// ---------- dedupe / ordering ----------

#[test]
fn duplicates_are_ignored_and_last_seq_tracked() {
    let mut t = AgentTracker::new();
    assert_eq!(t.last_seq(HOST), None);
    t.ingest(&prompt(1, "x"));
    t.ingest(&pre(2, "Bash"));
    assert_eq!(t.last_seq(HOST), Some(2));
    let ch = t.ingest(&stop(2, "dup seq with different payload"));
    assert!(ch.is_empty());
    assert_eq!(state(&t), working(Some("Bash")));
    let ch = t.ingest(&prompt(1, "x"));
    assert!(ch.is_empty());
    assert_eq!(t.last_seq(HOST), Some(2));
    assert_eq!(t.last_seq("other"), None);
}

#[test]
fn seq_is_deduped_per_host() {
    let mut t = AgentTracker::new();
    t.ingest(&env(
        "a",
        1,
        1000,
        None,
        json!({"type":"user_prompt_submit","session_id":"x","prompt":"p"}),
    ));
    t.ingest(&env(
        "b",
        1,
        1000,
        None,
        json!({"type":"user_prompt_submit","session_id":"y","prompt":"p"}),
    ));
    assert_eq!(t.sessions().len(), 2);
    assert_eq!(t.last_seq("a"), Some(1));
    assert_eq!(t.last_seq("b"), Some(1));
}

#[test]
fn out_of_order_event_does_not_regress_state() {
    let mut t = AgentTracker::new();
    t.ingest(&prompt(1, "x"));
    t.ingest(&stop(5, "done"));
    // late, older event arrives after reconnect replay
    let ch = t.ingest(&pre(3, "Bash"));
    assert!(ch.is_empty());
    assert_eq!(state(&t), SessionState::Done);
    assert_eq!(t.last_seq(HOST), Some(5));
    // and is deduped on a second delivery
    assert!(t.ingest(&pre(3, "Bash")).is_empty());
}

#[test]
fn late_session_start_fills_metadata_only() {
    let mut t = AgentTracker::new();
    t.ingest(&prompt(2, "x"));
    t.ingest(&start(1));
    let s = t.session(&key()).unwrap();
    assert_eq!(s.state, working(None));
    assert_eq!(s.model.as_deref(), Some("opus"));
    assert_eq!(s.started_at, 1000);
}

// ---------- changes / replay ----------

#[test]
fn state_changed_only_on_actual_transitions() {
    let mut t = AgentTracker::new();
    let ch = t.ingest(&prompt(1, "x"));
    assert!(ch.contains(&TrackerChange::StateChanged {
        key: key(),
        from: SessionState::Starting,
        to: working(None)
    }));
    let ch = t.ingest(&prompt(2, "y"));
    assert!(
        ch.iter()
            .all(|c| !matches!(c, TrackerChange::StateChanged { .. }))
    );
    let ch = t.ingest(&pre(3, "Bash"));
    assert_eq!(ch.len(), 1);
}

#[test]
fn replay_applies_state_but_emits_nothing() {
    let mut t = AgentTracker::new();
    t.ingest_replay(&start(1));
    t.ingest_replay(&pre(2, "Bash"));
    t.ingest_replay(&perm_req(3, "r", "Bash", json!({"command":"x"})));
    assert_eq!(state(&t), SessionState::NeedsPermission);
    assert!(t.session(&key()).unwrap().pending_permission.is_some());
    assert_eq!(t.last_seq(HOST), Some(3));
    // live ingest after replay is not suppressed
    let ch = t.ingest(&resolved(4, "r", "allowed"));
    assert!(!ch.is_empty());
    // replayed duplicates stay deduped
    t.ingest_replay(&start(1));
    assert_eq!(state(&t), working(None));
}

#[test]
fn new_session_in_same_pane_ends_the_old_one() {
    let mut t = AgentTracker::new();
    t.ingest(&start(1));
    t.ingest(&prompt(2, "x"));
    let ch = t.ingest(&ev(
        3,
        json!({"type":"session_start","session_id":"s2","source":"startup"}),
    ));
    assert_eq!(state(&t), SessionState::Ended);
    assert!(ch.contains(&TrackerChange::StateChanged {
        key: key(),
        from: working(None),
        to: SessionState::Ended
    }));
    assert_eq!(
        t.session(&SessionKey::new(HOST, "s2")).unwrap().state,
        SessionState::Starting
    );
}

#[test]
fn ended_sessions_are_pruned_after_ttl() {
    let mut t = AgentTracker::new();
    t.ingest(&start(1));
    t.ingest(&end(2)); // ended at ts 2000
    assert!(t.prune_ended(2000 + 59_999, 60_000).is_empty());
    assert!(t.session(&key()).is_some());
    let ch = t.prune_ended(2000 + 60_000, 60_000);
    assert_eq!(ch, vec![TrackerChange::SessionRemoved { key: key() }]);
    assert!(t.session(&key()).is_none());
}

// ---------- golden transcript ----------

fn golden() -> Vec<Envelope> {
    let path = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../shuai-agent/tests/fixtures/e2e-claude-2.1.288.jsonl"
    );
    std::fs::read_to_string(path)
        .unwrap()
        .lines()
        .map(|l| serde_json::from_str(l).unwrap())
        .collect()
}

#[test]
fn golden_transcript_states_after_each_event() {
    use SessionState::*;
    let w = |t: &str| Working {
        tool: Some(t.to_string()),
    };
    let wn = Working { tool: None };
    // state expected after seq N (index N-1)
    let expected = vec![
        Starting,        // 1 session_start
        wn.clone(),      // 2 user_prompt_submit
        w("Bash"),       // 3 pre_tool_use
        NeedsPermission, // 4 permission_request
        NeedsPermission, // 5 notification permission_prompt
        wn.clone(),      // 6 resolved allowed
        wn.clone(),      // 7 post_tool_use
        Done,            // 8 stop
        Done,            // 9 subagent_stop (agent_id)
        wn.clone(),      // 10 prompt
        w("Bash"),       // 11 pre
        NeedsPermission, // 12 request
        NeedsPermission, // 13 notification
        wn.clone(),      // 14 resolved denied
        Done,            // 15 stop (no post_tool_use for denied tool)
        Done,            // 16 subagent_stop
        wn.clone(),      // 17 prompt
        w("Bash"),       // 18 pre
        NeedsPermission, // 19 request
        NeedsPermission, // 20 resolved not_present
        NeedsPermission, // 21 notification
        wn.clone(),      // 22 post_tool_use
        Done,            // 23 stop
        Done,            // 24 helper pre_tool_use (agent_id) after stop
        Done,            // 25 subagent_stop
    ];
    let evs = golden();
    assert_eq!(evs.len(), expected.len());
    let mut t = AgentTracker::new();
    let k = SessionKey::new("e2e-host", "08a5dc1c-d8a0-49d8-bce4-62a495c70dab");
    for (e, want) in evs.iter().zip(&expected) {
        t.ingest(e);
        assert_eq!(&t.session(&k).unwrap().state, want, "after seq {}", e.seq);
    }
    let s = t.session(&k).unwrap();
    assert_eq!(s.active_subagents, 0);
    assert_eq!(s.tmux_pane, Some(PaneId(0)));
    assert_eq!(t.last_seq("e2e-host"), Some(25));
    assert_eq!(t.sessions().len(), 1);
}

#[test]
fn golden_transcript_replayed_twice_and_reversed_is_stable() {
    let evs = golden();
    let mut a = AgentTracker::new();
    for e in &evs {
        a.ingest(e);
    }
    let mut b = AgentTracker::new();
    for e in &evs {
        b.ingest_replay(e);
    }
    for e in evs.iter().rev() {
        b.ingest_replay(e);
    } // duplicates, reversed
    let k = SessionKey::new("e2e-host", "08a5dc1c-d8a0-49d8-bce4-62a495c70dab");
    assert_eq!(a.session(&k), b.session(&k));
}
