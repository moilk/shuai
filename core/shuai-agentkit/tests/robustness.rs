mod common;
use common::*;
use serde_json::json;
use shuai_agentkit::{AgentTracker, SessionKey, SessionState, TrackerChange};

fn key() -> SessionKey {
    SessionKey::new(HOST, SID)
}

fn st(t: &AgentTracker) -> SessionState {
    t.session(&key()).unwrap().state.clone()
}

fn working() -> SessionState {
    SessionState::Working { tool: None }
}

// ---- missed permission_resolved ----

#[test]
fn post_tool_use_for_the_pending_tool_use_id_clears_a_missed_resolution() {
    let mut t = AgentTracker::new();
    t.ingest(&prompt(1, "go"));
    t.ingest(&ev(
        2,
        json!({"type":"permission_request","request_id":"r1","tool_name":"Bash",
               "tool_input":{"command":"x"},"tool_use_id":"tu1"}),
    ));
    // parallel tool with another id must not clear
    t.ingest(&ev(
        3,
        json!({"type":"post_tool_use","tool_name":"Read","tool_input":{},"tool_use_id":"tu2"}),
    ));
    assert_eq!(st(&t), SessionState::NeedsPermission);
    assert!(t.session(&key()).unwrap().pending_permission.is_some());
    // the user answered at the terminal: the tool ran, resolved was lost
    let ch = t.ingest(&ev(
        4,
        json!({"type":"post_tool_use","tool_name":"Bash","tool_input":{"command":"x"},"tool_use_id":"tu1"}),
    ));
    assert_eq!(st(&t), working());
    assert!(t.session(&key()).unwrap().pending_permission.is_none());
    assert!(ch.contains(&TrackerChange::PermissionCleared { key: key() }));
}

#[test]
fn post_tool_use_same_tool_and_input_clears_when_ids_are_absent() {
    let mut t = AgentTracker::new();
    t.ingest(&perm_req(1, "r1", "Bash", json!({"command":"ls"})));
    t.ingest(&post(2, "Read")); // different tool: keeps the card
    assert_eq!(st(&t), SessionState::NeedsPermission);
    t.ingest(&post(3, "Bash")); // helper input is {"command":"ls"}
    assert_eq!(st(&t), working());
    assert!(t.session(&key()).unwrap().pending_permission.is_none());
}

// ---- stale Working flag ----

fn ev_sid(seq: u64, sid: &str, mut e: serde_json::Value) -> shuai_proto::Envelope {
    e["session_id"] = json!(sid);
    ev_at(seq, "%1", e)
}

#[test]
fn working_session_with_no_events_is_flagged_stale_but_state_is_unchanged() {
    let mut t = AgentTracker::new();
    t.ingest(&prompt(1, "go"));
    t.ingest(&stop(2, "ok"));
    t.ingest(&ev_sid(
        3,
        "s2",
        json!({"type":"user_prompt_submit","prompt":"x"}),
    )); // ts 3000
    let ttl = 60_000;
    assert!(t.stale_working(3_000 + ttl - 1, ttl).is_empty());
    let stale = t.stale_working(3_000 + ttl, ttl);
    assert_eq!(stale.len(), 1);
    assert_eq!(stale[0].session_id, "s2");
    assert!(stale[0].is_possibly_stale(3_000 + ttl, ttl));
    assert!(matches!(stale[0].state, SessionState::Working { .. }));
    // Done sessions are never "stale working"
    assert!(!t.session(&key()).unwrap().is_possibly_stale(u64::MAX, ttl));
}

// ---- epoch / wiped server state ----

#[test]
fn seq_restart_after_server_wipe_is_a_new_epoch_not_a_duplicate() {
    let mut t = AgentTracker::new();
    t.ingest(&start(1));
    t.ingest(&prompt(2, "a"));
    t.ingest(&pre(3, "Bash"));
    t.ingest(&perm_req(4, "r1", "Bash", json!({"command":"x"})));
    assert_eq!(t.last_seq(HOST), Some(4));

    // an hour later the agent state was reinstalled: seq restarts at 1
    let hour = 3_600_000;
    let ch = t.ingest(&env(
        HOST,
        1,
        hour,
        Some("%0"),
        json!({"type":"stop","session_id":SID,"last_assistant_message":"fresh"}),
    ));
    assert_eq!(st(&t), SessionState::Done, "{ch:?}");
    assert_eq!(t.last_seq(HOST), Some(1));
    // the old request can never be answered any more
    assert!(t.session(&key()).unwrap().pending_permission.is_none());
    assert!(ch.contains(&TrackerChange::PermissionCleared { key: key() }));
    // and the stream keeps flowing
    t.ingest(&env(
        HOST,
        2,
        hour + 1000,
        Some("%0"),
        json!({"type":"user_prompt_submit","session_id":SID,"prompt":"b"}),
    ));
    assert_eq!(st(&t), working());
}

#[test]
fn genuine_duplicates_and_old_replays_do_not_trigger_an_epoch_reset() {
    let mut t = AgentTracker::new();
    for e in [start(1), prompt(2, "a"), pre(3, "Bash"), stop(4, "done")] {
        t.ingest(&e);
    }
    for e in [start(1), prompt(2, "a"), pre(3, "Bash"), stop(4, "done")] {
        assert!(t.ingest(&e).is_empty());
        t.ingest_replay(&e);
    }
    assert_eq!(st(&t), SessionState::Done);
    assert_eq!(t.last_seq(HOST), Some(4));
    // slightly newer ts within the skew margin is still a duplicate
    let near = env(
        HOST,
        2,
        4_000 + 500,
        Some("%0"),
        json!({"type":"user_prompt_submit","session_id":SID,"prompt":"a"}),
    );
    assert!(t.ingest(&near).is_empty());
    assert_eq!(st(&t), SessionState::Done);
}

#[test]
fn epoch_reset_is_per_host() {
    let mut t = AgentTracker::new();
    let p = |h: &str, sid: &str| {
        env(
            h,
            5,
            1000,
            None,
            json!({"type":"user_prompt_submit","session_id":sid,"prompt":"p"}),
        )
    };
    t.ingest(&p("a", "x"));
    t.ingest(&p("b", "y"));
    t.ingest(&env(
        "a",
        1,
        10_000_000,
        None,
        json!({"type":"stop","session_id":"x"}),
    ));
    assert_eq!(t.last_seq("a"), Some(1));
    assert_eq!(t.last_seq("b"), Some(5));
}

// ---- performance ----

#[test]
fn ten_thousand_events_over_two_hundred_sessions_is_fast() {
    let mut t = AgentTracker::new();
    let started = std::time::Instant::now();
    for i in 0..10_000u64 {
        let sid = format!("s{}", i % 200);
        let mut e = match i % 5 {
            0 => json!({"type":"user_prompt_submit","prompt":"p"}),
            1 => json!({"type":"pre_tool_use","tool_name":"Bash","tool_input":{"command":"ls"}}),
            2 => json!({"type":"post_tool_use","tool_name":"Bash","tool_input":{"command":"ls"}}),
            3 => {
                json!({"type":"permission_request","request_id":format!("r{i}"),"tool_name":"Bash","tool_input":{}})
            }
            _ => json!({"type":"stop","last_assistant_message":"m"}),
        };
        e["session_id"] = json!(sid);
        t.ingest(&env(HOST, i + 1, i * 10, Some(&format!("%{}", i % 200)), e));
    }
    for _ in 0..100 {
        assert_eq!(t.sessions().len(), 200);
        let _ = t.attention_count();
    }
    assert!(started.elapsed() < std::time::Duration::from_secs(5));
}
