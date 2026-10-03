#![allow(dead_code)]
use serde_json::{Value, json};
use shuai_proto::Envelope;

pub const SID: &str = "s1";
pub const HOST: &str = "h";

/// Build an envelope from a compact event JSON (`type` + fields).
pub fn env(host: &str, seq: u64, ts_ms: u64, pane: Option<&str>, event: Value) -> Envelope {
    let mut v = json!({
        "v": 1, "seq": seq, "ts_ms": ts_ms, "host": host, "source": "claude",
        "event": event,
    });
    if let Some(p) = pane {
        v["tmux"] = json!({"pane": p, "socket": "/tmp/tmux-1000/default"});
    }
    serde_json::from_value(v).unwrap()
}

/// Event on session `SID`, host `HOST`, pane `%0`, ts = seq * 1000.
pub fn ev(seq: u64, event: Value) -> Envelope {
    ev_at(seq, "%0", event)
}

pub fn ev_at(seq: u64, pane: &str, event: Value) -> Envelope {
    let mut e = event;
    if e.get("session_id").is_none() && e["type"] != "permission_resolved" {
        e["session_id"] = json!(SID);
    }
    env(HOST, seq, seq * 1000, Some(pane), e)
}

pub fn start(seq: u64) -> Envelope {
    ev(
        seq,
        json!({"type":"session_start","cwd":"/w","source":"startup","model":"opus","session_title":null}),
    )
}
pub fn prompt(seq: u64, p: &str) -> Envelope {
    ev(seq, json!({"type":"user_prompt_submit","prompt":p}))
}
pub fn pre(seq: u64, tool: &str) -> Envelope {
    ev(
        seq,
        json!({"type":"pre_tool_use","tool_name":tool,"tool_input":{"command":"ls"}}),
    )
}
pub fn post(seq: u64, tool: &str) -> Envelope {
    ev(
        seq,
        json!({"type":"post_tool_use","tool_name":tool,"tool_input":{"command":"ls"}}),
    )
}
pub fn perm_req(seq: u64, id: &str, tool: &str, input: Value) -> Envelope {
    ev(
        seq,
        json!({"type":"permission_request","request_id":id,"tool_name":tool,"tool_input":input}),
    )
}
pub fn resolved(seq: u64, id: &str, outcome: &str) -> Envelope {
    ev(
        seq,
        json!({"type":"permission_resolved","request_id":id,"outcome":outcome,"session_id":SID}),
    )
}
pub fn notif(seq: u64, kind: &str) -> Envelope {
    ev(
        seq,
        json!({"type":"notification","notification_type":kind,"message":"m"}),
    )
}
pub fn stop(seq: u64, msg: &str) -> Envelope {
    ev(seq, json!({"type":"stop","last_assistant_message":msg}))
}
pub fn end(seq: u64) -> Envelope {
    ev(seq, json!({"type":"session_end","reason":"other"}))
}
