//! `shuai-agent hook <event>` and `codex-notify`.

use crate::state::{Result, State, hostname, now_ms};
use crate::{ntfy, store};
use serde_json::Value;
use shuai_proto::{
    AgentEvent, Envelope, PROTOCOL_VERSION, PermissionOutcome, PermissionResponse, Source, TmuxCtx,
    encode_line, is_valid_request_id,
};
use std::collections::hash_map::RandomState;
use std::hash::{BuildHasher, Hasher};
use std::time::{Duration, Instant};

/// Payload strings longer than this are clipped when the payload is huge.
const BIG_PAYLOAD: usize = 100_000;
const CLIP_CHARS: usize = 8192;

fn tmux_ctx() -> Option<TmuxCtx> {
    let pane = std::env::var("TMUX_PANE").ok().filter(|p| !p.is_empty())?;
    let socket = std::env::var("TMUX")
        .ok()
        .and_then(|t| t.split(',').next().map(str::to_string))
        .filter(|s| !s.is_empty());
    Some(TmuxCtx { pane, socket })
}

fn clip_strings(v: &mut Value) {
    match v {
        Value::String(s) if s.chars().count() > CLIP_CHARS => {
            let mut t: String = s.chars().take(CLIP_CHARS).collect();
            t.push_str("…[truncated]");
            *s = t;
        }
        Value::Array(a) => a.iter_mut().for_each(clip_strings),
        Value::Object(o) => o.values_mut().for_each(clip_strings),
        _ => {}
    }
}

fn new_request_id() -> String {
    // 128 random bits: the id names the response file, so it must be unguessable.
    let mut b = [0u8; 16];
    let ok = std::fs::File::open("/dev/urandom")
        .and_then(|mut f| std::io::Read::read_exact(&mut f, &mut b))
        .is_ok();
    if !ok {
        for chunk in b.chunks_mut(8) {
            let mut h = RandomState::new().build_hasher();
            h.write_u64(now_ms());
            h.write_u32(std::process::id());
            chunk.copy_from_slice(&h.finish().to_le_bytes());
        }
    }
    b.iter().map(|x| format!("{x:02x}")).collect()
}

/// Append an envelope for `event`; returns it (with its assigned seq).
pub fn record(state: &State, source: Source, event: AgentEvent) -> Result<Envelope> {
    let mut slot: Option<Envelope> = None;
    let tmux = tmux_ctx();
    let pid = std::os::unix::process::parent_id();
    store::append_with(state, |seq| {
        let env = Envelope {
            v: PROTOCOL_VERSION,
            seq,
            ts_ms: now_ms(),
            host: hostname(),
            source,
            tmux,
            pid: Some(pid),
            event,
        };
        let line = encode_line(&env);
        slot = Some(env);
        line.trim_end().to_string()
    })?;
    Ok(slot.expect("closure ran"))
}

/// Handle one hook invocation. Returns the text to print on stdout, if any.
pub fn run(
    state: &State,
    event_name: &str,
    timeout: Duration,
    stdin: &str,
) -> Result<Option<String>> {
    let mut payload: Value =
        serde_json::from_str(stdin).map_err(|e| format!("stdin is not JSON: {e}"))?;
    if event_name.eq_ignore_ascii_case("PostToolUse")
        && let Some(o) = payload.as_object_mut()
    {
        o.remove("tool_response"); // can be megabytes; the app has no use for it
    }
    if stdin.len() > BIG_PAYLOAD {
        clip_strings(&mut payload);
    }
    let mut event = AgentEvent::from_hook(event_name, &payload);

    if let AgentEvent::PermissionRequest { request_id, .. } = &mut event {
        *request_id = new_request_id();
        return permission_request(state, event, timeout);
    }
    let env = record(state, Source::Claude, event)?;
    ntfy::maybe_push(state, &env);
    Ok(None)
}

fn resolve(state: &State, id: &str, session: Option<String>, outcome: PermissionOutcome) {
    let ev = AgentEvent::PermissionResolved {
        request_id: id.to_string(),
        outcome,
        session_id: session,
    };
    if let Err(e) = record(state, Source::Claude, ev) {
        state.log(&format!("cannot record permission_resolved: {e}"));
    }
}

fn permission_request(
    state: &State,
    event: AgentEvent,
    timeout: Duration,
) -> Result<Option<String>> {
    let session = event.session_id().map(str::to_string);
    let id = match &event {
        AgentEvent::PermissionRequest { request_id, .. } => request_id.clone(),
        _ => unreachable!(),
    };
    let present = state.present();
    record(state, Source::Claude, event)?;
    if !present {
        resolve(state, &id, session, PermissionOutcome::NotPresent);
        return Ok(None);
    }

    let path = state.responses_dir().join(format!("{id}.json"));
    debug_assert!(is_valid_request_id(&id));
    let deadline = Instant::now() + timeout;
    loop {
        if let Ok(bytes) = std::fs::read(&path) {
            match serde_json::from_slice::<PermissionResponse>(&bytes) {
                Ok(r) if r.request_id == id => {
                    let _ = std::fs::remove_file(&path);
                    let outcome = match r.behavior {
                        shuai_proto::Behavior::Allow => PermissionOutcome::Allowed,
                        shuai_proto::Behavior::Deny => PermissionOutcome::Denied,
                    };
                    resolve(state, &id, session, outcome);
                    return Ok(Some(r.to_hook_output().to_string()));
                }
                _ => state.log(&format!("ignoring invalid response file for {id}")),
            }
            // Do not re-read the same garbage every poll.
            let _ = std::fs::remove_file(&path);
        }
        if !state.present() {
            resolve(state, &id, session, PermissionOutcome::NotPresent);
            return Ok(None);
        }
        if Instant::now() >= deadline {
            resolve(state, &id, session, PermissionOutcome::Timeout);
            return Ok(None);
        }
        std::thread::sleep(state.poll_interval().min(deadline - Instant::now()));
    }
}

/// `codex-notify '<json>'`.
pub fn codex_notify(state: &State, json: &str) -> Result<()> {
    let payload: Value =
        serde_json::from_str(json).map_err(|e| format!("argv is not JSON: {e}"))?;
    let env = record(
        state,
        Source::Codex,
        AgentEvent::from_codex_notify(&payload),
    )?;
    ntfy::maybe_push(state, &env);
    Ok(())
}
