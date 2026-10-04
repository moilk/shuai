//! Push notifications through an ntfy server.
//!
//! Privacy: a push carries *status only* (what happened, which host, which tmux window). No
//! prompt, command, tool input, assistant message or path ever goes into a push; the builders
//! below never read those fields of an event, and `tests/push.rs` asserts it end to end.

use crate::state::{Ntfy, Result, State, hostname, now_ms, private_open};
use shuai_proto::{AgentEvent, Envelope};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

#[derive(Debug, Default, Clone)]
pub struct Message<'a> {
    pub title: &'a str,
    pub body: &'a str,
    pub click: Option<&'a str>,
    pub priority: Option<&'a str>,
    pub tags: Option<&'a str>,
}

pub fn send(cfg: &Ntfy, m: &Message) -> Result<()> {
    let url = format!("{}/{}", cfg.server.trim_end_matches('/'), cfg.topic);
    let agent: ureq::Agent = ureq::Agent::config_builder()
        .timeout_global(Some(Duration::from_secs(5)))
        .build()
        .into();
    let mut req = agent.post(&url).header("Title", m.title);
    if let Some(c) = m.click {
        req = req.header("Click", c);
    }
    if let Some(p) = m.priority {
        req = req.header("Priority", p);
    }
    if let Some(t) = m.tags {
        req = req.header("Tags", t);
    }
    if let Some(tok) = &cfg.token {
        req = req.header("Authorization", format!("Bearer {tok}"));
    }
    req.send(m.body)?;
    Ok(())
}

fn percent_encode(s: &str) -> String {
    let mut out = String::new();
    for b in s.bytes() {
        if b.is_ascii_alphanumeric() || b == b'-' || b == b'_' || b == b'.' {
            out.push(b as char);
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
}

/// Deep link back to the pane: `shuai://open?host=<host_id>&pane=<%N>` (both percent-encoded).
pub fn click_url(state: &State, env: &Envelope) -> Option<String> {
    let pane = &env.tmux.as_ref()?.pane;
    let host = state.config().host_id.unwrap_or_else(hostname);
    Some(format!(
        "shuai://open?host={}&pane={}",
        percent_encode(&host),
        percent_encode(pane)
    ))
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Kind {
    /// `PermissionRequest` hook.
    ApprovalRequest,
    /// `Notification` with `permission_prompt`.
    ApprovalPrompt,
    Idle,
    Done,
    Failed,
    CodexDone,
}

impl Kind {
    fn is_approval(self) -> bool {
        matches!(self, Kind::ApprovalRequest | Kind::ApprovalPrompt)
    }
    fn title(self) -> &'static str {
        match self {
            Kind::ApprovalRequest | Kind::ApprovalPrompt => "Claude needs approval",
            Kind::Idle => "Claude is waiting for input",
            Kind::Done => "Claude finished",
            Kind::Failed => "Claude stopped with an error",
            Kind::CodexDone => "Codex finished",
        }
    }
    fn priority(self) -> &'static str {
        if self.is_approval() {
            "high"
        } else {
            "default"
        }
    }
    fn tags(self) -> &'static str {
        match self {
            Kind::ApprovalRequest | Kind::ApprovalPrompt => "warning",
            Kind::Idle => "hourglass",
            Kind::Done | Kind::CodexDone => "white_check_mark",
            Kind::Failed => "x",
        }
    }
}

/// What kind of push (if any) an event deserves, plus the key of its session. Reads *only* the
/// event type, never its content (apart from ids used for dedupe, which are not sent).
fn classify(env: &Envelope) -> Option<(Kind, String)> {
    let key = |s: &str| {
        if !s.is_empty() {
            s.to_string()
        } else {
            env.tmux
                .as_ref()
                .map(|t| t.pane.clone())
                .unwrap_or_else(|| "-".into())
        }
    };
    Some(match &env.event {
        AgentEvent::PermissionRequest { ctx, .. } => (Kind::ApprovalRequest, key(&ctx.session_id)),
        AgentEvent::Notification {
            ctx,
            notification_type,
            ..
        } => match notification_type.as_deref() {
            Some("permission_prompt") => (Kind::ApprovalPrompt, key(&ctx.session_id)),
            Some("idle_prompt") => (Kind::Idle, key(&ctx.session_id)),
            _ => return None,
        },
        AgentEvent::Stop { ctx, .. } if ctx.agent_id.is_none() => {
            (Kind::Done, key(&ctx.session_id))
        }
        AgentEvent::StopFailure { ctx, .. } => (Kind::Failed, key(&ctx.session_id)),
        AgentEvent::AgentTurnComplete { thread_id, .. } => (
            Kind::CodexDone,
            key(thread_id.as_deref().unwrap_or_default()),
        ),
        _ => return None,
    })
}

/// A `PermissionRequest` and the `Notification:permission_prompt` that follows it describe the
/// same prompt; they pair up within this window.
const PAIR_WINDOW_MS: u64 = 60_000;
/// Entries not touched for this long are forgotten.
const GATE_TTL_MS: u64 = 3_600_000;

/// Longest a hook waits for the gate lock; past it the gate fails open (a push is better than
/// holding up Claude's PermissionRequest hook).
const LOCK_WAIT: Duration = Duration::from_millis(250);

fn lock_gate(state: &State) -> Option<std::fs::File> {
    state.ensure().ok()?;
    let f = private_open()
        .create(true)
        .truncate(false)
        .write(true)
        .open(state.push_lock_path())
        .ok()?;
    let deadline = Instant::now() + LOCK_WAIT;
    loop {
        match f.try_lock() {
            Ok(()) => return Some(f),
            Err(std::fs::TryLockError::WouldBlock) if Instant::now() < deadline => {
                std::thread::sleep(Duration::from_millis(5));
            }
            Err(_) => return None,
        }
    }
}

/// Dedupe and rate limit. Returns whether a push for `kind` in `session` may go out now, and
/// records the decision. State lives in `push.json` (under `push.lock`); a broken gate fails open.
fn admit(state: &State, session: &str, kind: Kind) -> bool {
    let Some(_lock) = lock_gate(state) else {
        state.log("push gate busy: sending without dedupe");
        return true;
    };
    // Read the clock only once the lock is ours, so a waiter never sees the previous holder's
    // timestamp as "from the future".
    let now = now_ms();
    let mut root: serde_json::Value = std::fs::read_to_string(state.push_gate_path())
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
        .filter(serde_json::Value::is_object)
        .unwrap_or_else(|| serde_json::json!({}));
    let map = root.as_object_mut().expect("object");
    // Forget stale entries and anything malformed (wrong shape, timestamps from the future).
    map.retain(|_, v| {
        v.is_object()
            && ["last", "req", "prompt"]
                .iter()
                .filter_map(|k| v.get(k).and_then(|n| n.as_u64()))
                .max()
                .is_some_and(|t| t <= now && now - t < GATE_TTL_MS)
    });
    let entry = map
        .entry(session.to_string())
        .or_insert_with(|| serde_json::json!({}));
    let get = |e: &serde_json::Value, k: &str| e.get(k).and_then(|n| n.as_u64());
    let fresh = |t: Option<u64>| t.is_some_and(|t| t <= now && now - t < PAIR_WINDOW_MS);
    let e = entry
        .as_object_mut()
        .expect("entries are objects after retain");
    let allowed = match kind {
        Kind::ApprovalRequest => {
            if fresh(get(&serde_json::Value::Object(e.clone()), "prompt")) {
                e.remove("prompt");
                false
            } else {
                e.insert("req".into(), now.into());
                true
            }
        }
        Kind::ApprovalPrompt => {
            if fresh(get(&serde_json::Value::Object(e.clone()), "req")) {
                e.remove("req");
                false
            } else {
                e.insert("prompt".into(), now.into());
                true
            }
        }
        _ => {
            let min = state.push_min_interval().as_millis() as u64;
            let last = get(&serde_json::Value::Object(e.clone()), "last");
            if min > 0 && last.is_some_and(|l| l <= now && now - l < min) {
                false
            } else {
                e.insert("last".into(), now.into());
                true
            }
        }
    };
    let tmp = state.dir.join("push.json.tmp");
    let write = private_open()
        .create(true)
        .write(true)
        .truncate(true)
        .open(&tmp)
        .and_then(|mut f| std::io::Write::write_all(&mut f, root.to_string().as_bytes()))
        .and_then(|()| std::fs::rename(&tmp, state.push_gate_path()));
    if let Err(e) = write {
        state.log(&format!("push gate: {e}"));
    }
    allowed
}

/// `session › index` of the pane (plus `: window` when the user opted in), best effort (short
/// timeout, never fails). The window name is off by default: tmux's automatic-rename sets it to
/// the running command (`vim secrets.env`, `ssh prod-db`), which must not leave the server.
fn tmux_label(pane: &str, window_names: bool) -> Option<String> {
    if !is_pane_id(pane) {
        return None;
    }
    let format = if window_names {
        "#{session_name} › #{window_index}: #{window_name}"
    } else {
        "#{session_name} › #{window_index}"
    };
    let mut child = Command::new("tmux")
        .args(["display-message", "-p", "-t", pane, format])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .ok()?;
    let deadline = Instant::now() + Duration::from_millis(1500);
    let status = loop {
        match child.try_wait() {
            Ok(Some(s)) => break s,
            Ok(None) if Instant::now() < deadline => std::thread::sleep(Duration::from_millis(10)),
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                return None;
            }
        }
    };
    if !status.success() {
        return None;
    }
    let mut out = String::new();
    std::io::Read::read_to_string(&mut child.stdout.take()?, &mut out).ok()?;
    let label = out.trim();
    if label.is_empty() || label.chars().any(char::is_control) {
        return None;
    }
    Some(label.chars().take(80).collect())
}

fn is_pane_id(s: &str) -> bool {
    s.strip_prefix('%')
        .is_some_and(|d| (1..=9).contains(&d.len()) && d.bytes().all(|b| b.is_ascii_digit()))
}

/// Replace the topic and token of `cfg` in `msg`, whatever an error message decides to quote.
pub fn redact(cfg: &Ntfy, msg: &str) -> String {
    let mut out = msg.to_string();
    for secret in [Some(cfg.topic.as_str()), cfg.token.as_deref()]
        .into_iter()
        .flatten()
        .filter(|s| !s.is_empty())
    {
        out = out.replace(secret, "<redacted>");
    }
    out
}

/// Push a status-only notification for "attention worthy" events when ntfy is configured and no
/// app is watching. Failures are logged, never returned.
pub fn maybe_push(state: &State, env: &Envelope) {
    let cfg = state.config();
    let Some(ntfy) = cfg.ntfy.clone() else { return };
    if state.present() {
        return;
    }
    let Some((kind, session)) = classify(env) else {
        return;
    };
    if !admit(state, &session, kind) {
        return;
    }
    let host = cfg
        .host_name
        .clone()
        .filter(|n| !n.is_empty())
        .unwrap_or_else(hostname);
    let host: String = host.chars().filter(|c| !c.is_control()).take(80).collect();
    let body = match env
        .tmux
        .as_ref()
        .and_then(|t| tmux_label(&t.pane, ntfy.window_names))
    {
        Some(label) => format!("{host} · {label}"),
        None => host,
    };
    let click = click_url(state, env);
    let m = Message {
        title: kind.title(),
        body: &body,
        click: click.as_deref(),
        priority: Some(kind.priority()),
        tags: Some(kind.tags()),
    };
    if let Err(e) = send(&ntfy, &m) {
        state.log(&format!(
            "ntfy push failed: {}",
            redact(&ntfy, &e.to_string())
        ));
    }
}
