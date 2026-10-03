mod common;
use common::*;
use serde_json::{Value, json};
use shuai_agentkit::{AgentTracker, Badge, SessionKey, SessionState, TrackerChange};
use shuai_proto::Envelope;
use shuai_tmux::{PaneId, SessionId, TmuxPane, TmuxSession, TmuxTopology, TmuxWindow, WindowId};

fn sev(seq: u64, sid: &str, pane: &str, mut event: Value) -> Envelope {
    event["session_id"] = json!(sid);
    ev_at(seq, pane, event)
}

fn k(sid: &str) -> SessionKey {
    SessionKey::new(HOST, sid)
}

fn order(t: &AgentTracker) -> Vec<String> {
    t.sessions().iter().map(|s| s.session_id.clone()).collect()
}

/// a: needs permission, b: needs input, c: failed, d: done, e: working, f: starting, g: ended
fn zoo() -> AgentTracker {
    let mut t = AgentTracker::new();
    let mut seq = 0;
    let mut n = || {
        seq += 1;
        seq
    };
    for (i, sid) in ["a", "b", "c", "d", "e", "f", "g"].iter().enumerate() {
        let pane = format!("%{i}");
        t.ingest(&sev(
            n(),
            sid,
            &pane,
            json!({"type":"session_start","source":"startup"}),
        ));
    }
    t.ingest(&sev(
        n(),
        "a",
        "%0",
        json!({"type":"permission_request","request_id":"r","tool_name":"Bash","tool_input":{}}),
    ));
    t.ingest(&sev(
        n(),
        "b",
        "%1",
        json!({"type":"notification","notification_type":"idle_prompt"}),
    ));
    t.ingest(&sev(
        n(),
        "c",
        "%2",
        json!({"type":"stop_failure","error_message":"boom"}),
    ));
    t.ingest(&sev(n(), "d", "%3", json!({"type":"stop"})));
    t.ingest(&sev(
        n(),
        "e",
        "%4",
        json!({"type":"user_prompt_submit","prompt":"x"}),
    ));
    t.ingest(&sev(n(), "g", "%6", json!({"type":"session_end"})));
    t
}

#[test]
fn sessions_sorted_by_attention_priority() {
    let t = zoo();
    assert_eq!(order(&t), ["a", "b", "c", "d", "e", "f", "g"]);
}

#[test]
fn same_rank_sorted_by_recency_then_key() {
    let mut t = AgentTracker::new();
    t.ingest(&sev(
        1,
        "old",
        "%0",
        json!({"type":"user_prompt_submit","prompt":"x"}),
    ));
    t.ingest(&sev(
        2,
        "new",
        "%1",
        json!({"type":"user_prompt_submit","prompt":"x"}),
    ));
    assert_eq!(order(&t), ["new", "old"]);
}

#[test]
fn seen_done_drops_below_working() {
    let mut t = zoo();
    assert_eq!(t.attention_count(), 4); // a b c d
    assert!(t.mark_seen(&k("d")));
    assert_eq!(order(&t), ["a", "b", "c", "e", "f", "d", "g"]);
    assert_eq!(t.attention_count(), 3);
    assert!(!t.mark_seen(&k("d")), "already seen");
    assert!(!t.mark_seen(&k("nope")));
}

#[test]
fn seen_resets_on_next_state_change() {
    let mut t = zoo();
    t.mark_seen(&k("d"));
    t.ingest(&sev(
        100,
        "d",
        "%3",
        json!({"type":"user_prompt_submit","prompt":"x"}),
    ));
    t.ingest(&sev(101, "d", "%3", json!({"type":"stop"})));
    assert!(t.attention_count() >= 4);
    assert!(!t.session(&k("d")).unwrap().seen);
}

#[test]
fn needs_permission_ignores_seen() {
    let mut t = zoo();
    t.mark_seen(&k("a"));
    assert_eq!(t.attention_count(), 4);
}

#[test]
fn next_needing_attention_cycles() {
    let t = zoo();
    let nxt = |after: Option<&SessionKey>| {
        t.next_needing_attention(after)
            .map(|s| s.session_id.clone())
    };
    assert_eq!(nxt(None).as_deref(), Some("a"));
    assert_eq!(nxt(Some(&k("a"))).as_deref(), Some("b"));
    assert_eq!(nxt(Some(&k("c"))).as_deref(), Some("d"));
    assert_eq!(nxt(Some(&k("d"))).as_deref(), Some("a"), "wraps around");
    // `after` that no longer needs attention restarts from the top
    assert_eq!(nxt(Some(&k("e"))).as_deref(), Some("a"));
    assert_eq!(nxt(Some(&k("zzz"))).as_deref(), Some("a"));
}

#[test]
fn next_needing_attention_none_when_quiet() {
    let mut t = AgentTracker::new();
    assert!(t.next_needing_attention(None).is_none());
    t.ingest(&prompt(1, "x"));
    assert!(t.next_needing_attention(None).is_none());
}

#[test]
fn session_for_pane_and_badges() {
    let t = zoo();
    let p = |n| PaneId(n);
    assert_eq!(t.session_for_pane(HOST, p(0)).unwrap().session_id, "a");
    assert!(t.session_for_pane("other", p(0)).is_none());
    assert!(t.session_for_pane(HOST, p(6)).is_none(), "ended session");
    assert!(t.session_for_pane(HOST, p(42)).is_none());
    assert_eq!(t.badge_for_pane(HOST, p(0)), Some(Badge::NeedsPermission));
    assert_eq!(t.badge_for_pane(HOST, p(1)), Some(Badge::NeedsInput));
    assert_eq!(t.badge_for_pane(HOST, p(2)), Some(Badge::Failed));
    assert_eq!(t.badge_for_pane(HOST, p(3)), Some(Badge::Done));
    assert_eq!(t.badge_for_pane(HOST, p(4)), Some(Badge::Working));
    assert_eq!(t.badge_for_pane(HOST, p(5)), Some(Badge::Idle));
    assert_eq!(t.badge_for_pane(HOST, p(6)), None);
    assert_eq!(t.badge_for_pane(HOST, p(42)), None);
}

#[test]
fn seen_done_badge_is_idle() {
    let mut t = zoo();
    t.mark_seen(&k("d"));
    assert_eq!(t.badge_for_pane(HOST, PaneId(3)), Some(Badge::Idle));
}

#[test]
fn badge_ordering() {
    assert!(Badge::NeedsPermission > Badge::NeedsInput);
    assert!(Badge::NeedsInput > Badge::Failed);
    assert!(Badge::Failed > Badge::Done);
    assert!(Badge::Done > Badge::Working);
    assert!(Badge::Working > Badge::Idle);
}

fn pane(id: u32) -> TmuxPane {
    TmuxPane {
        id: PaneId(id),
        index: id,
        active: false,
        current_command: "claude".into(),
        current_path: "/".into(),
        pid: 1,
        tty: "/dev/pts/0".into(),
        title: String::new(),
        width: 80,
        height: 24,
    }
}

fn topo(windows: &[(u32, &[u32])]) -> TmuxTopology {
    TmuxTopology {
        sessions: vec![TmuxSession {
            id: SessionId(0),
            name: "main".into(),
            attached: 1,
            windows: windows
                .iter()
                .map(|(w, panes)| TmuxWindow {
                    id: WindowId(*w),
                    index: *w,
                    name: format!("w{w}"),
                    active: false,
                    flags: String::new(),
                    panes: panes.iter().map(|p| pane(*p)).collect(),
                })
                .collect(),
        }],
    }
}

#[test]
fn window_badge_is_highest_priority_pane() {
    let t = zoo();
    // window @0: panes %4 (working) %3 (done) %0 (needs permission); @1: %4 only; @2: %6 ended; @3: none
    let tp = topo(&[(0, &[4, 3, 0]), (1, &[4]), (2, &[6]), (3, &[99])]);
    assert_eq!(
        t.badge_for_window(HOST, &tp, WindowId(0)),
        Some(Badge::NeedsPermission)
    );
    assert_eq!(
        t.badge_for_window(HOST, &tp, WindowId(1)),
        Some(Badge::Working)
    );
    assert_eq!(t.badge_for_window(HOST, &tp, WindowId(2)), None);
    assert_eq!(t.badge_for_window(HOST, &tp, WindowId(3)), None);
    assert_eq!(t.badge_for_window(HOST, &tp, WindowId(77)), None);
}

// ---------------- reconcile with live panes ----------------

#[test]
fn reconcile_ends_sessions_whose_pane_vanished() {
    let mut t = zoo();
    // only %0 and %4 survive; %5 (f) and others vanish
    let tp = topo(&[(0, &[0, 4])]);
    let ch = t.reconcile_with_live_panes(HOST, &tp, 999_000);
    assert_eq!(
        t.session(&k("a")).unwrap().state,
        SessionState::NeedsPermission
    );
    assert_eq!(
        t.session(&k("e")).unwrap().state,
        SessionState::Working { tool: None }
    );
    for sid in ["b", "c", "d", "f"] {
        assert_eq!(
            t.session(&k(sid)).unwrap().state,
            SessionState::Ended,
            "{sid}"
        );
    }
    assert!(ch.contains(&TrackerChange::StateChanged {
        key: k("b"),
        from: SessionState::NeedsInput,
        to: SessionState::Ended
    }));
    // g was already ended: no change reported
    assert!(
        !ch.iter()
            .any(|c| matches!(c, TrackerChange::StateChanged { key, .. } if key == &k("g")))
    );
    assert_eq!(t.session(&k("b")).unwrap().updated_at, 999_000);
    // ended sessions no longer count for attention
    assert_eq!(t.attention_count(), 1);
}

#[test]
fn reconcile_clears_pending_permission() {
    let mut t = zoo();
    let ch = t.reconcile_with_live_panes(HOST, &topo(&[(0, &[])]), 5);
    assert!(ch.contains(&TrackerChange::PermissionCleared { key: k("a") }));
    assert!(t.session(&k("a")).unwrap().pending_permission.is_none());
}

#[test]
fn reconcile_only_touches_given_host_and_paned_sessions() {
    let mut t = zoo();
    t.ingest(&env(
        "h2",
        1,
        1,
        None,
        json!({"type":"user_prompt_submit","session_id":"nopane","prompt":"x"}),
    ));
    t.ingest(&env(
        "h2",
        2,
        2,
        Some("%0"),
        json!({"type":"user_prompt_submit","session_id":"other","prompt":"x"}),
    ));
    t.reconcile_with_live_panes(HOST, &topo(&[(0, &[])]), 10);
    let h2 = |sid: &str| SessionKey::new("h2", sid);
    assert_eq!(
        t.session(&h2("nopane")).unwrap().state,
        SessionState::Working { tool: None }
    );
    assert_eq!(
        t.session(&h2("other")).unwrap().state,
        SessionState::Working { tool: None }
    );
    // paneless session on the reconciled host is left alone, too
    t.ingest(&env(
        HOST,
        500,
        500,
        None,
        json!({"type":"user_prompt_submit","session_id":"nopane2","prompt":"x"}),
    ));
    t.reconcile_with_live_panes(HOST, &topo(&[(0, &[])]), 600);
    assert_eq!(
        t.session(&k("nopane2")).unwrap().state,
        SessionState::Working { tool: None }
    );
}

// ---------------- claude agents --json ----------------

const REAL: &str = r#"[
  {"pid": 8179, "cwd": "/home/ubuntu/w", "kind": "interactive", "startedAt": 1781881465511,
   "sessionId": "558aed0d", "status": "waiting", "waitingFor": "permission prompt"},
  {"pid": 579265, "cwd": "/home/ubuntu/r", "kind": "interactive", "startedAt": 1791020173483,
   "sessionId": "25e5e660", "name": "rainbaby-60", "status": "idle"}
]"#;

fn tracker_with(sid: &str, events: Vec<Envelope>) -> AgentTracker {
    let _ = sid;
    let mut t = AgentTracker::new();
    for e in &events {
        t.ingest(e);
    }
    t
}

fn st(t: &AgentTracker, sid: &str) -> SessionState {
    t.session(&k(sid)).unwrap().state.clone()
}

#[test]
fn agents_json_corrects_stale_states_real_sample() {
    let mut t = AgentTracker::new();
    t.ingest(&sev(
        1,
        "558aed0d",
        "%0",
        json!({"type":"user_prompt_submit","prompt":"x"}),
    ));
    t.ingest(&sev(
        2,
        "25e5e660",
        "%1",
        json!({"type":"user_prompt_submit","prompt":"x"}),
    ));
    let ch = t.apply_claude_agents_json(HOST, REAL, 9000).unwrap();
    assert_eq!(st(&t, "558aed0d"), SessionState::NeedsPermission);
    assert_eq!(st(&t, "25e5e660"), SessionState::Done);
    assert_eq!(ch.len(), 2);
    assert_eq!(
        t.session(&k("25e5e660")).unwrap().title.as_deref(),
        Some("rainbaby-60")
    );
    assert_eq!(t.session(&k("25e5e660")).unwrap().pid, Some(579265));
    // idempotent
    assert!(
        t.apply_claude_agents_json(HOST, REAL, 9001)
            .unwrap()
            .is_empty()
    );
}

#[test]
fn agents_json_unknown_sessions_ignored_and_ended_not_resurrected() {
    let mut t = tracker_with("x", vec![start(1), end(2)]);
    let json = r#"[{"sessionId":"s1","state":"working","status":"busy"},{"sessionId":"zzz","state":"failed"}]"#;
    let ch = t.apply_claude_agents_json(HOST, json, 5).unwrap();
    assert!(ch.is_empty());
    assert_eq!(st(&t, "s1"), SessionState::Ended);
    assert!(t.session(&k("zzz")).is_none());
}

#[test]
fn agents_json_state_mapping() {
    let cases: Vec<(&str, SessionState, SessionState)> = vec![
        // (json entry, tracker state before (built below), expected after)
        (
            r#"{"sessionId":"s1","state":"working","status":"busy"}"#,
            SessionState::Done,
            SessionState::Working { tool: None },
        ),
        (
            r#"{"sessionId":"s1","state":"done","status":"idle"}"#,
            SessionState::Working {
                tool: Some("Bash".into()),
            },
            SessionState::Done,
        ),
        (
            r#"{"sessionId":"s1","state":"failed"}"#,
            SessionState::Working { tool: None },
            SessionState::Failed {
                error: "failed".into(),
            },
        ),
        (
            r#"{"sessionId":"s1","state":"stopped"}"#,
            SessionState::Working { tool: None },
            SessionState::Ended,
        ),
        (
            r#"{"sessionId":"s1","state":"blocked","status":"waiting","waitingFor":"permission prompt"}"#,
            SessionState::Working { tool: None },
            SessionState::NeedsPermission,
        ),
        (
            r#"{"sessionId":"s1","state":"blocked","status":"waiting","waitingFor":"input"}"#,
            SessionState::Working { tool: None },
            SessionState::NeedsInput,
        ),
        (
            // status only (as printed by 2.1.288), no state
            r#"{"sessionId":"s1","status":"busy"}"#,
            SessionState::NeedsInput,
            SessionState::Working { tool: None },
        ),
        (
            // already consistent: untouched, tool detail preserved
            r#"{"sessionId":"s1","state":"working","status":"busy"}"#,
            SessionState::Working {
                tool: Some("Bash".into()),
            },
            SessionState::Working {
                tool: Some("Bash".into()),
            },
        ),
        (
            // blocked on permission and we already know: untouched
            r#"{"sessionId":"s1","state":"blocked","status":"waiting","waitingFor":"permission prompt"}"#,
            SessionState::NeedsPermission,
            SessionState::NeedsPermission,
        ),
        (
            // missing everything but the id
            r#"{"sessionId":"s1"}"#,
            SessionState::Done,
            SessionState::Done,
        ),
        (
            // unknown values and extra fields are ignored
            r#"{"sessionId":"s1","state":"hibernating","status":"zzz","extra":{"a":1}}"#,
            SessionState::Done,
            SessionState::Done,
        ),
        (
            // `id` fallback when sessionId is absent
            r#"{"id":"s1","state":"stopped"}"#,
            SessionState::Done,
            SessionState::Ended,
        ),
    ];
    for (entry, before, after) in cases {
        let mut t = AgentTracker::new();
        t.ingest(&start(1));
        match &before {
            SessionState::Done => {
                t.ingest(&stop(2, "x"));
            }
            SessionState::NeedsInput => {
                t.ingest(&stop(2, "x"));
                t.ingest(&notif(3, "idle_prompt"));
            }
            SessionState::NeedsPermission => {
                t.ingest(&notif(2, "permission_prompt"));
            }
            SessionState::Working { tool: Some(tool) } => {
                t.ingest(&pre(2, tool));
            }
            _ => {
                t.ingest(&prompt(2, "x"));
            }
        }
        assert_eq!(st(&t, "s1"), before, "setup for {entry}");
        t.apply_claude_agents_json(HOST, &format!("[{entry}]"), 100)
            .unwrap();
        assert_eq!(st(&t, "s1"), after, "{entry}");
    }
}

#[test]
fn agents_json_correction_clears_pending_permission() {
    let mut t = AgentTracker::new();
    t.ingest(&perm_req(1, "r", "Bash", json!({"command":"x"})));
    let ch = t
        .apply_claude_agents_json(
            HOST,
            r#"[{"sessionId":"s1","state":"done","status":"idle"}]"#,
            7,
        )
        .unwrap();
    assert_eq!(st(&t, "s1"), SessionState::Done);
    assert!(t.session(&k("s1")).unwrap().pending_permission.is_none());
    assert!(ch.contains(&TrackerChange::PermissionCleared { key: k("s1") }));
}

#[test]
fn agents_json_accepts_wrapped_object_and_rejects_garbage() {
    let mut t = tracker_with("x", vec![prompt(1, "x")]);
    let wrapped = r#"{"agents":[{"sessionId":"s1","state":"done"}]}"#;
    t.apply_claude_agents_json(HOST, wrapped, 1).unwrap();
    assert_eq!(st(&t, "s1"), SessionState::Done);
    assert!(t.apply_claude_agents_json(HOST, "not json", 2).is_err());
    assert!(t.apply_claude_agents_json(HOST, "", 2).is_err());
    assert!(
        t.apply_claude_agents_json(HOST, "[]", 2)
            .unwrap()
            .is_empty()
    );
    assert!(
        t.apply_claude_agents_json(HOST, "{}", 2)
            .unwrap()
            .is_empty()
    );
    // an entry of the wrong type is skipped, others still apply
    t.ingest(&prompt(5, "again"));
    t.apply_claude_agents_json(HOST, r#"[42, null, {"sessionId":"s1","state":"done"}]"#, 3)
        .unwrap();
    assert_eq!(st(&t, "s1"), SessionState::Done);
}

#[test]
fn agents_json_only_matches_given_host() {
    let mut t = tracker_with("x", vec![prompt(1, "x")]);
    t.apply_claude_agents_json("other", r#"[{"sessionId":"s1","state":"done"}]"#, 1)
        .unwrap();
    assert_eq!(st(&t, "s1"), SessionState::Working { tool: None });
}
