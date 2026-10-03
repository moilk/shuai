use serde_json::{Value, json};
use shuai_proto::*;

fn fx(name: &str) -> Value {
    let p = format!("{}/tests/fixtures/{name}.json", env!("CARGO_MANIFEST_DIR"));
    serde_json::from_str(&std::fs::read_to_string(p).unwrap()).unwrap()
}

fn envelope(event: AgentEvent) -> Envelope {
    Envelope {
        v: PROTOCOL_VERSION,
        seq: 7,
        ts_ms: 1_700_000_000_123,
        host: "dev".into(),
        source: Source::Claude,
        tmux: Some(TmuxCtx {
            pane: "%3".into(),
            socket: Some("/tmp/tmux-1000/default".into()),
        }),
        pid: Some(4242),
        event,
    }
}

#[test]
fn session_start_fixture() {
    match AgentEvent::from_hook("SessionStart", &fx("session_start")) {
        AgentEvent::SessionStart {
            ctx,
            source,
            model,
            session_title,
            raw,
        } => {
            assert_eq!(ctx.session_id, "5f1c2a9e-7b3d-4c1e-9a55-0d2f6e8b1a44");
            assert_eq!(ctx.cwd.as_deref(), Some("/home/dev/proj"));
            assert_eq!(ctx.permission_mode.as_deref(), Some("default"));
            assert_eq!(ctx.prompt_id.as_deref(), Some("p-0192"));
            assert_eq!(source.as_deref(), Some("startup"));
            assert_eq!(model.as_deref(), Some("claude-opus-4-5"));
            assert_eq!(session_title.as_deref(), Some("Fix flaky test"));
            assert_eq!(raw["hook_event_name"], "SessionStart");
        }
        other => panic!("unexpected {other:?}"),
    }
}

#[test]
fn simple_events_fixtures() {
    assert!(matches!(
        AgentEvent::from_hook("SessionEnd", &fx("session_end")),
        AgentEvent::SessionEnd { reason: Some(r), .. } if r == "prompt_input_exit"
    ));
    assert!(matches!(
        AgentEvent::from_hook("UserPromptSubmit", &fx("user_prompt_submit")),
        AgentEvent::UserPromptSubmit { prompt: Some(p), .. } if p.contains("flaky")
    ));
    assert!(matches!(
        AgentEvent::from_hook("Stop", &fx("stop")),
        AgentEvent::Stop { last_assistant_message: Some(m), .. } if m == "All tests pass now."
    ));
    match AgentEvent::from_hook("SubagentStop", &fx("subagent_stop")) {
        AgentEvent::SubagentStop { ctx, .. } => {
            assert_eq!(ctx.agent_id.as_deref(), Some("agent-77"));
            assert_eq!(ctx.agent_type.as_deref(), Some("Explore"));
        }
        other => panic!("unexpected {other:?}"),
    }
    assert!(matches!(
        AgentEvent::from_hook("StopFailure", &fx("stop_failure")),
        AgentEvent::StopFailure { error_type: Some(t), error_message: Some(_), .. } if t == "rate_limit"
    ));
}

#[test]
fn tool_events_fixtures() {
    match AgentEvent::from_hook("PreToolUse", &fx("pre_tool_use")) {
        AgentEvent::PreToolUse {
            tool_name,
            tool_input,
            tool_use_id,
            ..
        } => {
            assert_eq!(tool_name, "Bash");
            assert_eq!(tool_input["command"], "cargo test --workspace");
            assert_eq!(tool_use_id.as_deref(), Some("toolu_01ABC"));
        }
        other => panic!("unexpected {other:?}"),
    }
    assert!(matches!(
        AgentEvent::from_hook("PostToolUse", &fx("post_tool_use")),
        AgentEvent::PostToolUse { .. }
    ));
    assert!(matches!(
        AgentEvent::from_hook("PermissionDenied", &fx("permission_denied")),
        AgentEvent::PermissionDenied { .. }
    ));
}

#[test]
fn permission_request_fixture_has_empty_request_id_until_assigned() {
    match AgentEvent::from_hook("PermissionRequest", &fx("permission_request")) {
        AgentEvent::PermissionRequest {
            request_id,
            tool_name,
            tool_input,
            ..
        } => {
            assert_eq!(request_id, "");
            assert_eq!(tool_name, "Bash");
            assert_eq!(tool_input["command"], "rm -rf target");
        }
        other => panic!("unexpected {other:?}"),
    }
}

#[test]
fn notification_fixtures() {
    match AgentEvent::from_hook("Notification", &fx("notification_permission")) {
        AgentEvent::Notification {
            notification_type,
            message,
            ..
        } => {
            assert_eq!(notification_type.as_deref(), Some("permission_prompt"));
            assert!(message.unwrap().contains("permission"));
        }
        other => panic!("unexpected {other:?}"),
    }
}

#[test]
fn event_name_normalisation() {
    for n in [
        "PermissionRequest",
        "permission_request",
        "permission-request",
    ] {
        assert!(matches!(
            AgentEvent::from_hook(n, &fx("permission_request")),
            AgentEvent::PermissionRequest { .. }
        ));
    }
}

#[test]
fn unknown_hook_event_becomes_other() {
    match AgentEvent::from_hook("PreCompact", &fx("future_event")) {
        AgentEvent::Other { name, raw } => {
            assert_eq!(name, "PreCompact");
            assert_eq!(raw["trigger"], "auto");
        }
        other => panic!("unexpected {other:?}"),
    }
}

#[test]
fn known_event_with_wrong_types_degrades_to_other() {
    let e = AgentEvent::from_hook("PreToolUse", &json!({"tool_name": 5}));
    assert!(matches!(e, AgentEvent::Other { .. }));
}

#[test]
fn empty_payload_still_parses_known_event() {
    let e = AgentEvent::from_hook("Stop", &json!({}));
    assert!(matches!(e, AgentEvent::Stop { .. }));
    assert_eq!(e.kind(), "stop");
    assert_eq!(e.session_id(), Some(""));
}

#[test]
fn envelope_roundtrip_all_fixture_events() {
    for (name, f) in [
        ("SessionStart", "session_start"),
        ("PreToolUse", "pre_tool_use"),
        ("PermissionRequest", "permission_request"),
        ("Notification", "notification_idle"),
        ("PreCompact", "future_event"),
    ] {
        let env = envelope(AgentEvent::from_hook(name, &fx(f)));
        let line = encode_line(&env);
        assert!(line.ends_with('\n'));
        assert_eq!(line.matches('\n').count(), 1, "single line");
        let back: Envelope = serde_json::from_str(line.trim_end()).unwrap();
        assert_eq!(back, env);
    }
}

#[test]
fn envelope_wire_shape() {
    let env = envelope(AgentEvent::PermissionResolved {
        request_id: "r1".into(),
        outcome: PermissionOutcome::Timeout,
        session_id: None,
    });
    let v = serde_json::to_value(&env).unwrap();
    assert_eq!(v["v"], 1);
    assert_eq!(v["seq"], 7);
    assert_eq!(v["source"], "claude");
    assert_eq!(v["tmux"]["pane"], "%3");
    assert_eq!(v["event"]["type"], "permission_resolved");
    assert_eq!(v["event"]["outcome"], "timeout");
}

#[test]
fn envelope_without_optional_fields() {
    let line = r#"{"v":1,"seq":1,"ts_ms":2,"host":"h","source":"codex","event":{"type":"stop"}}"#;
    let e: Envelope = serde_json::from_str(line).unwrap();
    assert!(e.tmux.is_none() && e.pid.is_none());
    assert_eq!(e.source, Source::Codex);
}

#[test]
fn envelope_with_unknown_event_type_and_extra_fields_decodes_as_other() {
    let line = r#"{"v":1,"seq":1,"ts_ms":2,"host":"h","source":"claude","future":true,
        "event":{"type":"brand_new","x":[1,2]}}"#;
    let e: Envelope = serde_json::from_str(line).unwrap();
    match e.event {
        AgentEvent::Other { name, raw } => {
            assert_eq!(name, "brand_new");
            assert_eq!(raw["x"], json!([1, 2]));
        }
        other => panic!("unexpected {other:?}"),
    }
}

#[test]
fn codex_notify_payload() {
    match AgentEvent::from_codex_notify(&fx("codex_notify")) {
        AgentEvent::AgentTurnComplete {
            thread_id,
            turn_id,
            cwd,
            last_assistant_message,
            input_messages,
            ..
        } => {
            assert_eq!(
                thread_id.as_deref(),
                Some("b5f6c1c2-9e5c-4a7e-8f1a-2f4f0f3c9d11")
            );
            assert_eq!(turn_id.as_deref(), Some("12345"));
            assert_eq!(cwd.as_deref(), Some("/home/dev/proj"));
            assert_eq!(
                last_assistant_message.as_deref(),
                Some("Renamed foo to bar across 4 files.")
            );
            assert_eq!(input_messages, vec!["Rename foo to bar".to_string()]);
        }
        other => panic!("unexpected {other:?}"),
    }
}

#[test]
fn permission_response_hook_output() {
    let allow = PermissionResponse {
        request_id: "r".into(),
        behavior: Behavior::Allow,
        message: None,
    };
    assert_eq!(
        allow.to_hook_output(),
        json!({"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}})
    );
    let deny = PermissionResponse {
        request_id: "r".into(),
        behavior: Behavior::Deny,
        message: Some("no".into()),
    };
    assert_eq!(
        deny.to_hook_output(),
        json!({"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"no"}}})
    );
    let back: PermissionResponse =
        serde_json::from_str(r#"{"request_id":"r","behavior":"deny","message":"no"}"#).unwrap();
    assert_eq!(back, deny);
}

#[test]
fn request_id_validation() {
    assert!(is_valid_request_id("19a3-bc_4"));
    assert!(!is_valid_request_id(""));
    assert!(!is_valid_request_id("../etc/passwd"));
    assert!(!is_valid_request_id("a/b"));
    assert!(!is_valid_request_id(&"a".repeat(129)));
}

#[test]
fn decode_envelopes_tolerates_partial_trailing_line() {
    let a = encode_line(&envelope(AgentEvent::from_hook("Stop", &fx("stop"))));
    let mut b = encode_line(&envelope(AgentEvent::from_hook("Stop", &fx("stop"))));
    b.pop(); // drop newline
    let half = &b[..b.len() / 2];
    let input = format!("{a}garbage not json\n{half}");
    let (items, consumed) = decode_envelopes(&input);
    assert_eq!(items.len(), 1, "garbage line skipped, partial line left");
    assert_eq!(consumed, a.len() + "garbage not json\n".len());
    // completing the line later yields it
    let rest = format!("{}{}\n", &input[consumed..], &b[half.len()..]);
    let (items, consumed) = decode_envelopes(&rest);
    assert_eq!(items.len(), 1);
    assert_eq!(consumed, rest.len());
}

#[test]
fn line_decoder_streams_chunks() {
    let line = encode_line(&envelope(AgentEvent::from_hook("Stop", &fx("stop"))));
    let bytes = line.as_bytes();
    let mut d = LineDecoder::default();
    assert!(d.push(&bytes[..10]).is_empty());
    let out = d.push(&[&bytes[10..], b"{\"type\":\"heart"].concat());
    assert_eq!(out.len(), 1);
    let out = d.push(b"beat\"}\n");
    assert_eq!(out, vec!["{\"type\":\"heartbeat\"}".to_string()]);
}

#[test]
fn watch_line_decodes_heartbeat_and_event() {
    assert_eq!(
        WatchLine::decode(r#"{"type":"heartbeat"}"#).unwrap(),
        WatchLine::Heartbeat
    );
    let env = envelope(AgentEvent::from_hook("Stop", &fx("stop")));
    let line = encode_line(&env);
    assert_eq!(
        WatchLine::decode(line.trim_end()).unwrap(),
        WatchLine::Event(Box::new(env))
    );
    assert!(WatchLine::decode("nope").is_err());
}

#[test]
fn watch_line_decodes_caught_up_marker() {
    assert_eq!(
        WatchLine::decode(r#"{"type":"caught_up"}"#).unwrap(),
        WatchLine::CaughtUp
    );
}

/// Golden transcript recorded from real Claude Code 2.1.288 (see shuai-agent e2e).
#[test]
fn real_claude_transcript_decodes() {
    let text = include_str!("../../shuai-agent/tests/fixtures/e2e-claude-2.1.288.jsonl");
    let mut types = Vec::new();
    let mut last = 0;
    for l in text.lines() {
        let WatchLine::Event(env) = WatchLine::decode(l).unwrap() else {
            panic!("heartbeat in event log")
        };
        assert!(env.seq > last);
        last = env.seq;
        assert!(
            !matches!(env.event, AgentEvent::Other { .. }),
            "unmodelled event {l}"
        );
        types.push(
            serde_json::to_value(&env.event).unwrap()["type"]
                .as_str()
                .unwrap()
                .to_string(),
        );
    }
    assert_eq!(
        &types[..9],
        [
            "session_start",
            "user_prompt_submit",
            "pre_tool_use",
            "permission_request",
            "notification",
            "permission_resolved",
            "post_tool_use",
            "stop",
            "subagent_stop"
        ]
    );
}
