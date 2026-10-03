//! Per-session agent state machine.

use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::str::FromStr;

use serde_json::Value;
use shuai_proto::{AgentEvent, Envelope, HookCtx, PermissionOutcome, Source};
use shuai_tmux::PaneId;

const PROMPT_MAX: usize = 200;
const MESSAGE_MAX: usize = 300;
const PREVIEW_MAX: usize = 200;
/// How many out-of-order seqs per host are remembered for deduplication.
const SEEN_WINDOW: usize = 8192;

/// Identity of a session: agent host + agent session id (Codex: thread id).
#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct SessionKey {
    pub host: String,
    pub session_id: String,
}

impl SessionKey {
    pub fn new(host: impl Into<String>, session_id: impl Into<String>) -> Self {
        Self {
            host: host.into(),
            session_id: session_id.into(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SessionState {
    Starting,
    Working { tool: Option<String> },
    NeedsPermission,
    NeedsInput,
    Done,
    Failed { error: String },
    Ended,
}

/// A permission request the user can answer natively.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PendingPermission {
    pub request_id: String,
    pub tool_name: String,
    /// Short human preview of the tool input (command / path / compact JSON), truncated.
    pub input_preview: String,
    /// Timestamp (ms) of the request event.
    pub since: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AgentSession {
    pub host: String,
    pub session_id: String,
    pub source: Source,
    pub cwd: Option<String>,
    pub title: Option<String>,
    pub model: Option<String>,
    pub tmux_pane: Option<PaneId>,
    pub tmux_socket: Option<String>,
    pub pid: Option<u32>,
    pub state: SessionState,
    pub current_tool: Option<String>,
    pub last_prompt: Option<String>,
    pub last_message: Option<String>,
    pub pending_permission: Option<PendingPermission>,
    /// Subagents currently running (display only; they never affect `state`).
    pub active_subagents: u32,
    /// The user has looked at this session since its last state change.
    pub seen: bool,
    pub updated_at: u64,
    pub started_at: u64,
    /// Highest seq applied to this session (older late events are ignored).
    pub last_seq: u64,
    pub(crate) subagent_ids: BTreeSet<String>,
}

impl AgentSession {
    pub fn key(&self) -> SessionKey {
        SessionKey::new(self.host.clone(), self.session_id.clone())
    }

    /// Does this session want the user right now?
    pub fn needs_attention(&self) -> bool {
        match self.state {
            SessionState::NeedsPermission => true,
            SessionState::NeedsInput | SessionState::Failed { .. } | SessionState::Done => {
                !self.seen
            }
            _ => false,
        }
    }

    /// Lower = more urgent.
    pub(crate) fn rank(&self) -> u8 {
        match &self.state {
            SessionState::NeedsPermission => 0,
            SessionState::NeedsInput => 1,
            SessionState::Failed { .. } => 2,
            SessionState::Done if !self.seen => 3,
            SessionState::Working { .. } => 4,
            SessionState::Starting => 5,
            SessionState::Done => 6,
            SessionState::Ended => 7,
        }
    }
}

/// Aggregated status shown on a pane / window. Ordered: later variants are more urgent.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum Badge {
    Idle,
    Working,
    Done,
    Failed,
    NeedsInput,
    NeedsPermission,
}

/// Something the app may want to react to (banner, haptic, card). Never emitted on replay.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TrackerChange {
    SessionAdded {
        key: SessionKey,
    },
    SessionRemoved {
        key: SessionKey,
    },
    StateChanged {
        key: SessionKey,
        from: SessionState,
        to: SessionState,
    },
    PermissionRequested {
        key: SessionKey,
        request: PendingPermission,
    },
    PermissionCleared {
        key: SessionKey,
    },
}

#[derive(Debug, Default)]
struct HostCursor {
    max: u64,
    /// Seqs <= floor were evicted from `seen` and are treated as already applied.
    floor: u64,
    seen: BTreeSet<u64>,
}

impl HostCursor {
    fn is_dup(&self, seq: u64) -> bool {
        seq <= self.floor || self.seen.contains(&seq)
    }
    fn record(&mut self, seq: u64) {
        self.seen.insert(seq);
        self.max = self.max.max(seq);
        while self.seen.len() > SEEN_WINDOW {
            if let Some(first) = self.seen.pop_first() {
                self.floor = self.floor.max(first);
            }
        }
    }
}

#[derive(Debug, Default)]
pub struct AgentTracker {
    pub(crate) sessions: BTreeMap<SessionKey, AgentSession>,
    hosts: HashMap<String, HostCursor>,
}

pub(crate) fn truncate(s: &str, max: usize) -> String {
    if s.chars().count() <= max {
        s.to_string()
    } else {
        let mut out: String = s.chars().take(max).collect();
        out.push('…');
        out
    }
}

fn input_preview(input: &Value) -> String {
    for k in [
        "command",
        "file_path",
        "notebook_path",
        "path",
        "url",
        "pattern",
    ] {
        if let Some(s) = input.get(k).and_then(Value::as_str) {
            return truncate(s, PREVIEW_MAX);
        }
    }
    if input.is_null() {
        return String::new();
    }
    truncate(&input.to_string(), PREVIEW_MAX)
}

fn is_subagent(ctx: &HookCtx) -> bool {
    ctx.agent_id.as_deref().is_some_and(|a| !a.is_empty())
}

impl AgentTracker {
    pub fn new() -> Self {
        Self::default()
    }

    /// Apply a live envelope. Returns the changes the app may announce.
    pub fn ingest(&mut self, env: &Envelope) -> Vec<TrackerChange> {
        self.apply(env)
    }

    /// Apply an envelope from a `--since` replay: state is updated, nothing is announced.
    pub fn ingest_replay(&mut self, env: &Envelope) {
        let _ = self.apply(env);
    }

    /// Highest seq seen for `host`: pass it as `shuai-agent watch --since` after a reconnect.
    pub fn last_seq(&self, host: &str) -> Option<u64> {
        self.hosts.get(host).map(|c| c.max)
    }

    pub fn session(&self, key: &SessionKey) -> Option<&AgentSession> {
        self.sessions.get(key)
    }

    /// All sessions, most urgent first: NeedsPermission > NeedsInput > Failed > unseen Done >
    /// Working > Starting > seen Done > Ended; ties broken by recency, then key.
    pub fn sessions(&self) -> Vec<&AgentSession> {
        let mut v: Vec<&AgentSession> = self.sessions.values().collect();
        v.sort_by(|a, b| {
            a.rank()
                .cmp(&b.rank())
                .then(b.updated_at.cmp(&a.updated_at))
                .then_with(|| a.host.cmp(&b.host))
                .then_with(|| a.session_id.cmp(&b.session_id))
        });
        v
    }

    pub fn attention_count(&self) -> usize {
        self.sessions
            .values()
            .filter(|s| s.needs_attention())
            .count()
    }

    /// Drop Ended sessions whose last update is at least `ttl_ms` old.
    pub fn prune_ended(&mut self, now_ms: u64, ttl_ms: u64) -> Vec<TrackerChange> {
        let dead: Vec<SessionKey> = self
            .sessions
            .values()
            .filter(|s| s.state == SessionState::Ended && s.updated_at + ttl_ms <= now_ms)
            .map(AgentSession::key)
            .collect();
        dead.into_iter()
            .map(|key| {
                self.sessions.remove(&key);
                TrackerChange::SessionRemoved { key }
            })
            .collect()
    }

    // ------------------------------------------------------------------ internals

    fn apply(&mut self, env: &Envelope) -> Vec<TrackerChange> {
        let cursor = self.hosts.entry(env.host.clone()).or_default();
        if cursor.is_dup(env.seq) {
            return Vec::new();
        }
        cursor.record(env.seq);

        let mut changes = Vec::new();
        let ev = &env.event;
        let sub = ev.ctx().is_some_and(is_subagent);

        let key = match ev {
            AgentEvent::PermissionResolved {
                request_id,
                session_id,
                ..
            } => self
                .sessions
                .values()
                .find(|s| {
                    s.host == env.host
                        && s.pending_permission
                            .as_ref()
                            .is_some_and(|p| &p.request_id == request_id)
                })
                .map(AgentSession::key)
                .or_else(|| {
                    session_id
                        .as_ref()
                        .map(|sid| SessionKey::new(env.host.clone(), sid.clone()))
                        .filter(|k| self.sessions.contains_key(k))
                }),
            AgentEvent::AgentTurnComplete { thread_id, .. } => Some(SessionKey::new(
                env.host.clone(),
                thread_id.clone().unwrap_or_else(|| "codex".into()),
            )),
            AgentEvent::Other { .. } => None,
            other => other
                .session_id()
                .filter(|s| !s.is_empty())
                .map(|sid| SessionKey::new(env.host.clone(), sid)),
        };
        let Some(key) = key else {
            return changes;
        };

        let exists = self.sessions.contains_key(&key);
        // Events that must not create a session on their own.
        let creates = !(sub && !matches!(ev, AgentEvent::PermissionRequest { .. })
            || matches!(
                ev,
                AgentEvent::SessionEnd { .. }
                    | AgentEvent::SubagentStop { .. }
                    | AgentEvent::PermissionResolved { .. }
            ));
        if !exists {
            if !creates {
                return changes;
            }
            self.sessions.insert(key.clone(), new_session(&key, env));
            changes.push(TrackerChange::SessionAdded { key: key.clone() });
        }

        let stale = exists && env.seq < self.sessions[&key].last_seq;
        if stale {
            // A late SessionStart may still fill in metadata; everything else is history.
            if let AgentEvent::SessionStart {
                ctx,
                model,
                session_title,
                ..
            } = ev
            {
                let s = self.sessions.get_mut(&key).expect("exists");
                fill_start_meta(s, ctx, model, session_title);
                s.started_at = s.started_at.min(env.ts_ms);
            }
            return Vec::new();
        }

        // SessionStart in a pane evicts whatever agent previously lived there.
        if let AgentEvent::SessionStart { .. } = ev {
            self.evict_pane_others(&key, env, &mut changes);
        }

        let s = self.sessions.get_mut(&key).expect("exists");
        s.last_seq = env.seq;
        let before = s.state.clone();
        let subagent_noise = sub
            && !matches!(
                ev,
                AgentEvent::PermissionRequest { .. } | AgentEvent::Notification { .. }
            );
        if !subagent_noise {
            s.updated_at = s.updated_at.max(env.ts_ms);
            if let Some(t) = &env.tmux {
                if let Ok(p) = PaneId::from_str(&t.pane) {
                    s.tmux_pane = Some(p);
                }
                if t.socket.is_some() {
                    s.tmux_socket = t.socket.clone();
                }
            }
            if env.pid.is_some() {
                s.pid = env.pid;
            }
        }
        let mut pending_cleared = false;
        let mut pending_new: Option<PendingPermission> = None;

        match ev {
            AgentEvent::SessionStart {
                ctx,
                source,
                model,
                session_title,
                ..
            } => {
                fill_start_meta(s, ctx, model, session_title);
                if !exists {
                    if source.as_deref() == Some("resume") {
                        s.state = SessionState::Done;
                        s.seen = true;
                    }
                } else if s.state == SessionState::Ended {
                    s.state = SessionState::Starting;
                }
            }
            AgentEvent::SessionEnd { .. } => {
                pending_cleared |= take_pending(s);
                s.subagent_ids.clear();
                s.active_subagents = 0;
                s.current_tool = None;
                s.state = SessionState::Ended;
            }
            AgentEvent::UserPromptSubmit { ctx, prompt, .. } if !sub => {
                pending_cleared |= take_pending(s);
                set_cwd(s, ctx);
                if let Some(p) = prompt {
                    s.last_prompt = Some(truncate(p, PROMPT_MAX));
                }
                s.current_tool = None;
                s.state = SessionState::Working { tool: None };
            }
            AgentEvent::PreToolUse { ctx, tool_name, .. } => {
                if sub {
                    s.subagent_ids
                        .insert(ctx.agent_id.clone().unwrap_or_default());
                    s.active_subagents = s.subagent_ids.len() as u32;
                } else {
                    set_cwd(s, ctx);
                    s.current_tool = Some(tool_name.clone());
                    if s.pending_permission.is_none() {
                        s.state = SessionState::Working {
                            tool: Some(tool_name.clone()),
                        };
                    }
                }
            }
            AgentEvent::PostToolUse { .. } if !sub => {
                s.current_tool = None;
                if s.pending_permission.is_none() {
                    s.state = SessionState::Working { tool: None };
                }
            }
            AgentEvent::PermissionRequest {
                request_id,
                tool_name,
                tool_input,
                ..
            } => {
                let p = PendingPermission {
                    request_id: request_id.clone(),
                    tool_name: tool_name.clone(),
                    input_preview: input_preview(tool_input),
                    since: env.ts_ms,
                };
                s.pending_permission = Some(p.clone());
                pending_new = Some(p);
                s.state = SessionState::NeedsPermission;
            }
            AgentEvent::PermissionResolved {
                request_id,
                outcome,
                ..
            } => {
                if s.pending_permission
                    .as_ref()
                    .is_some_and(|p| &p.request_id == request_id)
                {
                    pending_cleared |= take_pending(s);
                    if matches!(
                        outcome,
                        PermissionOutcome::Allowed | PermissionOutcome::Denied
                    ) && s.state == SessionState::NeedsPermission
                    {
                        s.current_tool = None;
                        s.state = SessionState::Working { tool: None };
                    }
                }
            }
            AgentEvent::Notification {
                notification_type, ..
            } if s.state != SessionState::Ended => match notification_type.as_deref() {
                Some("permission_prompt") => s.state = SessionState::NeedsPermission,
                Some("idle_prompt") | Some("elicitation_dialog") => {
                    pending_cleared |= take_pending(s);
                    s.state = SessionState::NeedsInput;
                }
                _ => {}
            },
            AgentEvent::Stop {
                ctx,
                last_assistant_message,
                ..
            } if !sub => {
                pending_cleared |= take_pending(s);
                set_cwd(s, ctx);
                if let Some(m) = last_assistant_message {
                    s.last_message = Some(truncate(m, MESSAGE_MAX));
                }
                s.current_tool = None;
                s.state = SessionState::Done;
            }
            AgentEvent::SubagentStop { ctx, .. } => {
                if let Some(a) = &ctx.agent_id {
                    s.subagent_ids.remove(a);
                    s.active_subagents = s.subagent_ids.len() as u32;
                }
            }
            AgentEvent::StopFailure {
                error_type,
                error_message,
                ..
            } if !sub => {
                pending_cleared |= take_pending(s);
                s.current_tool = None;
                let error = error_message
                    .clone()
                    .filter(|e| !e.is_empty())
                    .or_else(|| error_type.clone())
                    .unwrap_or_else(|| "unknown error".into());
                s.state = SessionState::Failed { error };
            }
            AgentEvent::AgentTurnComplete {
                cwd,
                input_messages,
                last_assistant_message,
                ..
            } => {
                pending_cleared |= take_pending(s);
                if cwd.is_some() {
                    s.cwd = cwd.clone();
                }
                if let Some(p) = input_messages.last() {
                    s.last_prompt = Some(truncate(p, PROMPT_MAX));
                }
                if let Some(m) = last_assistant_message {
                    s.last_message = Some(truncate(m, MESSAGE_MAX));
                }
                s.current_tool = None;
                s.state = SessionState::Done;
            }
            _ => {}
        }

        if s.state != before {
            if !(s.seen && !exists) {
                s.seen = false;
            }
            changes.push(TrackerChange::StateChanged {
                key: key.clone(),
                from: before,
                to: s.state.clone(),
            });
        }
        if let Some(request) = pending_new {
            changes.push(TrackerChange::PermissionRequested {
                key: key.clone(),
                request,
            });
        } else if pending_cleared {
            changes.push(TrackerChange::PermissionCleared { key });
        }
        changes
    }

    fn evict_pane_others(
        &mut self,
        key: &SessionKey,
        env: &Envelope,
        out: &mut Vec<TrackerChange>,
    ) {
        let Some(t) = &env.tmux else { return };
        let Ok(pane) = PaneId::from_str(&t.pane) else {
            return;
        };
        let others: Vec<SessionKey> = self
            .sessions
            .values()
            .filter(|o| {
                o.host == key.host
                    && o.session_id != key.session_id
                    && o.tmux_pane == Some(pane)
                    && o.state != SessionState::Ended
                    && (o.tmux_socket.is_none() || t.socket.is_none() || o.tmux_socket == t.socket)
            })
            .map(AgentSession::key)
            .collect();
        for k in others {
            self.end_session(&k, env.ts_ms, out);
        }
    }

    /// Force a state from ground truth (not from an event): clears the pending card.
    pub(crate) fn set_state_external(
        &mut self,
        key: &SessionKey,
        new: SessionState,
        now_ms: u64,
        out: &mut Vec<TrackerChange>,
    ) {
        let Some(s) = self.sessions.get_mut(key) else {
            return;
        };
        if s.state == new {
            return;
        }
        let cleared = take_pending(s);
        let from = std::mem::replace(&mut s.state, new.clone());
        s.current_tool = None;
        s.seen = false;
        s.updated_at = s.updated_at.max(now_ms);
        out.push(TrackerChange::StateChanged {
            key: key.clone(),
            from,
            to: new,
        });
        if cleared {
            out.push(TrackerChange::PermissionCleared { key: key.clone() });
        }
    }

    /// Mark a session Ended (pane gone, session replaced, ...), clearing its pending card.
    pub(crate) fn end_session(
        &mut self,
        key: &SessionKey,
        now_ms: u64,
        out: &mut Vec<TrackerChange>,
    ) {
        let Some(o) = self.sessions.get_mut(key) else {
            return;
        };
        if o.state == SessionState::Ended {
            return;
        }
        let had_pending = take_pending(o);
        let from = std::mem::replace(&mut o.state, SessionState::Ended);
        o.current_tool = None;
        o.subagent_ids.clear();
        o.active_subagents = 0;
        o.seen = false;
        o.updated_at = o.updated_at.max(now_ms);
        out.push(TrackerChange::StateChanged {
            key: key.clone(),
            from,
            to: SessionState::Ended,
        });
        if had_pending {
            out.push(TrackerChange::PermissionCleared { key: key.clone() });
        }
    }
}

fn take_pending(s: &mut AgentSession) -> bool {
    s.pending_permission.take().is_some()
}

fn set_cwd(s: &mut AgentSession, ctx: &HookCtx) {
    if ctx.cwd.is_some() {
        s.cwd = ctx.cwd.clone();
    }
}

fn fill_start_meta(
    s: &mut AgentSession,
    ctx: &HookCtx,
    model: &Option<String>,
    title: &Option<String>,
) {
    set_cwd(s, ctx);
    if model.is_some() {
        s.model = model.clone();
    }
    if title.is_some() {
        s.title = title.clone();
    }
}

fn new_session(key: &SessionKey, env: &Envelope) -> AgentSession {
    AgentSession {
        host: key.host.clone(),
        session_id: key.session_id.clone(),
        source: env.source,
        cwd: None,
        title: None,
        model: None,
        tmux_pane: None,
        tmux_socket: None,
        pid: None,
        state: SessionState::Starting,
        current_tool: None,
        last_prompt: None,
        last_message: None,
        pending_permission: None,
        active_subagents: 0,
        seen: false,
        updated_at: env.ts_ms,
        started_at: env.ts_ms,
        last_seq: 0,
        subagent_ids: BTreeSet::new(),
    }
}
