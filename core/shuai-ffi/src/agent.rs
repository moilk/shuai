//! Agent integration exports: the session tracker, the install plan/probe and the remote
//! command builders (all logic lives in `shuai-agentkit`; this is data conversion only).

use std::str::FromStr;
use std::sync::{Arc, Mutex};

use shuai_agentkit::install::{self, InstallPlan, InstallStep, ProbeResult};
use shuai_agentkit::{
    AgentSession, AgentTracker as Tracker, Badge, PendingPermission, SessionKey, SessionState,
    TrackerChange, remote,
};
use shuai_proto::{Envelope, Source, WatchLine};
use shuai_tmux::{PaneId, SessionId, TmuxPane, TmuxSession, TmuxTopology, TmuxWindow, WindowId};

use crate::tmux::FfiTopology;

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error, uniffi::Error)]
pub enum FfiAgentError {
    #[error("invalid line: {message}")]
    InvalidLine { message: String },
    #[error("invalid input: {message}")]
    InvalidInput { message: String },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum FfiAgentSource {
    Claude,
    Codex,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum FfiSessionState {
    Starting,
    Working { tool: Option<String> },
    NeedsPermission,
    NeedsInput,
    Done,
    Failed { error: String },
    Ended,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum FfiBadge {
    Idle,
    Working,
    Done,
    Failed,
    NeedsInput,
    NeedsPermission,
}

#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct FfiSessionKey {
    pub host: String,
    pub session_id: String,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FfiPendingPermission {
    pub request_id: String,
    pub tool_name: String,
    pub input_preview: String,
    /// Full tool input as compact JSON (for Edit/Write diffs).
    pub tool_input_json: String,
    pub since: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FfiAgentSession {
    pub host: String,
    pub session_id: String,
    pub source: FfiAgentSource,
    pub cwd: Option<String>,
    pub title: Option<String>,
    pub model: Option<String>,
    /// tmux pane id such as `%3`.
    pub tmux_pane: Option<String>,
    pub tmux_socket: Option<String>,
    pub pid: Option<u32>,
    pub state: FfiSessionState,
    pub current_tool: Option<String>,
    pub last_prompt: Option<String>,
    pub last_message: Option<String>,
    pub pending_permission: Option<FfiPendingPermission>,
    pub active_subagents: u32,
    pub seen: bool,
    pub needs_attention: bool,
    pub badge: Option<FfiBadge>,
    pub updated_at: u64,
    pub started_at: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum FfiTrackerChange {
    SessionAdded {
        key: FfiSessionKey,
    },
    SessionRemoved {
        key: FfiSessionKey,
    },
    StateChanged {
        key: FfiSessionKey,
        from: FfiSessionState,
        to: FfiSessionState,
    },
    PermissionRequested {
        key: FfiSessionKey,
        request: FfiPendingPermission,
    },
    PermissionCleared {
        key: FfiSessionKey,
    },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum FfiWatchLineKind {
    Heartbeat,
    /// End of the `--since` replay; later lines are live.
    CaughtUp,
    Event,
    Invalid,
}

// ---------------------------------------------------------------- conversions

impl From<SessionState> for FfiSessionState {
    fn from(s: SessionState) -> Self {
        match s {
            SessionState::Starting => Self::Starting,
            SessionState::Working { tool } => Self::Working { tool },
            SessionState::NeedsPermission => Self::NeedsPermission,
            SessionState::NeedsInput => Self::NeedsInput,
            SessionState::Done => Self::Done,
            SessionState::Failed { error } => Self::Failed { error },
            SessionState::Ended => Self::Ended,
        }
    }
}

impl From<Badge> for FfiBadge {
    fn from(b: Badge) -> Self {
        match b {
            Badge::Idle => Self::Idle,
            Badge::Working => Self::Working,
            Badge::Done => Self::Done,
            Badge::Failed => Self::Failed,
            Badge::NeedsInput => Self::NeedsInput,
            Badge::NeedsPermission => Self::NeedsPermission,
        }
    }
}

impl From<SessionKey> for FfiSessionKey {
    fn from(k: SessionKey) -> Self {
        Self {
            host: k.host,
            session_id: k.session_id,
        }
    }
}

impl From<&PendingPermission> for FfiPendingPermission {
    fn from(p: &PendingPermission) -> Self {
        Self {
            request_id: p.request_id.clone(),
            tool_name: p.tool_name.clone(),
            input_preview: p.input_preview.clone(),
            tool_input_json: p.tool_input().to_string(),
            since: p.since,
        }
    }
}

impl From<&AgentSession> for FfiAgentSession {
    fn from(s: &AgentSession) -> Self {
        Self {
            host: s.host.clone(),
            session_id: s.session_id.clone(),
            source: match s.source {
                Source::Claude => FfiAgentSource::Claude,
                Source::Codex => FfiAgentSource::Codex,
            },
            cwd: s.cwd.clone(),
            title: s.title.clone(),
            model: s.model.clone(),
            tmux_pane: s.tmux_pane.map(|p| p.to_string()),
            tmux_socket: s.tmux_socket.clone(),
            pid: s.pid,
            state: s.state.clone().into(),
            current_tool: s.current_tool.clone(),
            last_prompt: s.last_prompt.clone(),
            last_message: s.last_message.clone(),
            pending_permission: s.pending_permission.as_ref().map(Into::into),
            active_subagents: s.active_subagents,
            seen: s.seen,
            needs_attention: s.needs_attention(),
            badge: s.badge().map(Into::into),
            updated_at: s.updated_at,
            started_at: s.started_at,
        }
    }
}

impl From<TrackerChange> for FfiTrackerChange {
    fn from(c: TrackerChange) -> Self {
        match c {
            TrackerChange::SessionAdded { key } => Self::SessionAdded { key: key.into() },
            TrackerChange::SessionRemoved { key } => Self::SessionRemoved { key: key.into() },
            TrackerChange::StateChanged { key, from, to } => Self::StateChanged {
                key: key.into(),
                from: from.into(),
                to: to.into(),
            },
            TrackerChange::PermissionRequested { key, request } => Self::PermissionRequested {
                key: key.into(),
                request: (&request).into(),
            },
            TrackerChange::PermissionCleared { key } => Self::PermissionCleared { key: key.into() },
        }
    }
}

fn changes(v: Vec<TrackerChange>) -> Vec<FfiTrackerChange> {
    v.into_iter().map(Into::into).collect()
}

fn to_topology(t: &FfiTopology) -> TmuxTopology {
    // Ids that do not parse are skipped: such panes can never match a session anyway.
    TmuxTopology {
        sessions: t
            .sessions
            .iter()
            .filter_map(|s| {
                Some(TmuxSession {
                    id: SessionId::from_str(&s.id).ok()?,
                    name: s.name.clone(),
                    attached: s.attached,
                    windows: s
                        .windows
                        .iter()
                        .filter_map(|w| {
                            Some(TmuxWindow {
                                id: WindowId::from_str(&w.id).ok()?,
                                index: w.index,
                                name: w.name.clone(),
                                active: w.active,
                                flags: w.flags.clone(),
                                panes: w
                                    .panes
                                    .iter()
                                    .filter_map(|p| {
                                        Some(TmuxPane {
                                            id: PaneId::from_str(&p.id).ok()?,
                                            index: p.index,
                                            active: p.active,
                                            current_command: p.current_command.clone(),
                                            current_path: p.current_path.clone(),
                                            pid: p.pid,
                                            tty: p.tty.clone(),
                                            title: p.title.clone(),
                                            width: p.width,
                                            height: p.height,
                                        })
                                    })
                                    .collect(),
                            })
                        })
                        .collect(),
                })
            })
            .collect(),
    }
}

fn parse_envelope(line: &str) -> Result<Option<Envelope>, FfiAgentError> {
    match WatchLine::decode(line.trim()) {
        Ok(WatchLine::Event(e)) => Ok(Some(*e)),
        Ok(WatchLine::Heartbeat | WatchLine::CaughtUp) => Ok(None),
        Err(e) => Err(FfiAgentError::InvalidLine {
            message: e.to_string(),
        }),
    }
}

fn key(k: FfiSessionKey) -> SessionKey {
    SessionKey::new(k.host, k.session_id)
}

// ---------------------------------------------------------------- tracker

/// Thread-safe wrapper over the sans-io tracker; see `shuai_agentkit::AgentTracker`.
#[derive(uniffi::Object)]
pub struct AgentTracker {
    inner: Mutex<Tracker>,
}

impl AgentTracker {
    fn with<R>(&self, f: impl FnOnce(&mut Tracker) -> R) -> R {
        f(&mut self.inner.lock().unwrap_or_else(|e| e.into_inner()))
    }
}

#[uniffi::export]
impl AgentTracker {
    #[uniffi::constructor]
    pub fn new() -> Arc<Self> {
        Arc::new(Self {
            inner: Mutex::new(Tracker::new()),
        })
    }

    /// Apply one `shuai-agent watch` line as live. Heartbeat / caught-up lines yield no change;
    /// malformed lines are an error (callers may ignore it).
    pub fn ingest_jsonl_line(&self, line: String) -> Result<Vec<FfiTrackerChange>, FfiAgentError> {
        Ok(match parse_envelope(&line)? {
            Some(e) => changes(self.with(|t| t.ingest(&e))),
            None => vec![],
        })
    }

    /// Apply one line from the `--since` replay: state only, nothing announced.
    pub fn ingest_replay(&self, line: String) -> Result<(), FfiAgentError> {
        if let Some(e) = parse_envelope(&line)? {
            self.with(|t| t.ingest_replay(&e));
        }
        Ok(())
    }

    /// Most urgent first.
    pub fn sessions(&self) -> Vec<FfiAgentSession> {
        self.with(|t| t.sessions().into_iter().map(Into::into).collect())
    }

    pub fn attention_count(&self) -> u32 {
        self.with(|t| t.attention_count() as u32)
    }

    pub fn next_needing_attention(&self, after: Option<FfiSessionKey>) -> Option<FfiAgentSession> {
        self.with(|t| {
            let after = after.map(key);
            t.next_needing_attention(after.as_ref()).map(Into::into)
        })
    }

    pub fn mark_seen(&self, key_: FfiSessionKey) -> bool {
        self.with(|t| t.mark_seen(&key(key_)))
    }

    pub fn session_for_pane(&self, host: String, pane: String) -> Option<FfiAgentSession> {
        let pane = PaneId::from_str(&pane).ok()?;
        self.with(|t| t.session_for_pane(&host, pane).map(Into::into))
    }

    pub fn badge_for_pane(&self, host: String, pane: String) -> Option<FfiBadge> {
        let pane = PaneId::from_str(&pane).ok()?;
        self.with(|t| t.badge_for_pane(&host, pane).map(Into::into))
    }

    pub fn badge_for_window(
        &self,
        host: String,
        topology: FfiTopology,
        window: String,
    ) -> Option<FfiBadge> {
        let window = WindowId::from_str(&window).ok()?;
        let topo = to_topology(&topology);
        self.with(|t| t.badge_for_window(&host, &topo, window).map(Into::into))
    }

    pub fn reconcile_with_live_panes(
        &self,
        host: String,
        topology: FfiTopology,
        now_ms: u64,
    ) -> Vec<FfiTrackerChange> {
        let topo = to_topology(&topology);
        changes(self.with(|t| t.reconcile_with_live_panes(&host, &topo, now_ms)))
    }

    pub fn apply_claude_agents_json(
        &self,
        host: String,
        json: String,
        now_ms: u64,
    ) -> Result<Vec<FfiTrackerChange>, FfiAgentError> {
        self.with(|t| t.apply_claude_agents_json(&host, &json, now_ms))
            .map(changes)
            .map_err(|e| FfiAgentError::InvalidInput {
                message: e.to_string(),
            })
    }

    /// Cursor for `shuai-agent watch --since`.
    pub fn last_seq(&self, host: String) -> Option<u64> {
        self.with(|t| t.last_seq(&host))
    }

    pub fn prune_ended(&self, now_ms: u64, ttl_ms: u64) -> Vec<FfiTrackerChange> {
        changes(self.with(|t| t.prune_ended(now_ms, ttl_ms)))
    }
}

/// Classify a raw watch line (replay boundary detection needs this).
#[uniffi::export]
pub fn classify_watch_line(line: String) -> FfiWatchLineKind {
    match WatchLine::decode(line.trim()) {
        Ok(WatchLine::Heartbeat) => FfiWatchLineKind::Heartbeat,
        Ok(WatchLine::CaughtUp) => FfiWatchLineKind::CaughtUp,
        Ok(WatchLine::Event(_)) => FfiWatchLineKind::Event,
        Err(_) => FfiWatchLineKind::Invalid,
    }
}

// ---------------------------------------------------------------- install

#[derive(Debug, Clone, Default, PartialEq, Eq, uniffi::Record)]
pub struct FfiProbeResult {
    pub uname_s: String,
    pub uname_m: String,
    pub home: String,
    pub shell: String,
    pub claude_path: Option<String>,
    pub tmux_version: Option<String>,
    pub agent_version: Option<String>,
    pub plugin_installed: bool,
    pub codex_path: Option<String>,
    pub codex_notify: Option<String>,
    pub tmux_conf_block: bool,
}

impl From<ProbeResult> for FfiProbeResult {
    fn from(p: ProbeResult) -> Self {
        Self {
            uname_s: p.uname_s,
            uname_m: p.uname_m,
            home: p.home,
            shell: p.shell,
            claude_path: p.claude_path,
            tmux_version: p.tmux_version,
            agent_version: p.agent_version,
            plugin_installed: p.plugin_installed,
            codex_path: p.codex_path,
            codex_notify: p.codex_notify,
            tmux_conf_block: p.tmux_conf_block,
        }
    }
}

impl From<FfiProbeResult> for ProbeResult {
    fn from(p: FfiProbeResult) -> Self {
        Self {
            uname_s: p.uname_s,
            uname_m: p.uname_m,
            home: p.home,
            shell: p.shell,
            claude_path: p.claude_path,
            tmux_version: p.tmux_version,
            agent_version: p.agent_version,
            plugin_installed: p.plugin_installed,
            codex_path: p.codex_path,
            codex_notify: p.codex_notify,
            tmux_conf_block: p.tmux_conf_block,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum FfiInstallStep {
    Unsupported {
        reason: String,
    },
    MakeDirs {
        path: String,
    },
    UploadAgent {
        target_triple: String,
        remote_path: String,
    },
    Chmod {
        path: String,
        mode: u32,
    },
    InstallPluginViaCli {
        claude_path: String,
    },
    MergeSettingsJson {
        path: String,
        agent_path: String,
    },
    ConfigureCodexNotify {
        config_path: String,
        notify_argv: Vec<String>,
    },
    CodexNotifyConflict {
        config_path: String,
        existing: String,
    },
    AppendTmuxConf {
        path: String,
        lines: Vec<String>,
    },
    RunDoctor {
        agent_path: String,
    },
}

impl From<InstallStep> for FfiInstallStep {
    fn from(s: InstallStep) -> Self {
        match s {
            InstallStep::Unsupported { reason } => Self::Unsupported { reason },
            InstallStep::MakeDirs { path } => Self::MakeDirs { path },
            InstallStep::UploadAgent {
                target_triple,
                remote_path,
            } => Self::UploadAgent {
                target_triple,
                remote_path,
            },
            InstallStep::Chmod { path, mode } => Self::Chmod { path, mode },
            InstallStep::InstallPluginViaCli { claude_path } => {
                Self::InstallPluginViaCli { claude_path }
            }
            InstallStep::MergeSettingsJson { path, agent_path } => {
                Self::MergeSettingsJson { path, agent_path }
            }
            InstallStep::ConfigureCodexNotify {
                config_path,
                notify_argv,
            } => Self::ConfigureCodexNotify {
                config_path,
                notify_argv,
            },
            InstallStep::CodexNotifyConflict {
                config_path,
                existing,
            } => Self::CodexNotifyConflict {
                config_path,
                existing,
            },
            InstallStep::AppendTmuxConf { path, lines } => Self::AppendTmuxConf { path, lines },
            InstallStep::RunDoctor { agent_path } => Self::RunDoctor { agent_path },
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FfiPluginFile {
    pub path: String,
    pub contents: String,
}

/// Read-only POSIX sh script to run on the remote host (`sh -s`, script on stdin).
#[uniffi::export]
pub fn probe_script() -> String {
    install::probe_script().to_string()
}

#[uniffi::export]
pub fn parse_probe(text: String) -> FfiProbeResult {
    install::parse_probe(&text).into()
}

#[uniffi::export]
pub fn install_plan(probe: FfiProbeResult, expected_agent_version: String) -> Vec<FfiInstallStep> {
    InstallPlan::for_probe_with(&probe.into(), &expected_agent_version)
        .into_iter()
        .map(Into::into)
        .collect()
}

/// Version the app expects on the remote (`shuai-agent --version`).
#[uniffi::export]
pub fn expected_agent_version() -> String {
    shuai_proto::version().to_string()
}

#[uniffi::export]
pub fn expand_tilde(path: String, home: String) -> String {
    install::expand_tilde(&path, &home)
}

/// GitHub-marketplace install commands (only works while the repo is public).
#[uniffi::export]
pub fn plugin_install_commands(claude_path: String) -> Vec<String> {
    install::plugin_install_commands(&claude_path)
}

#[uniffi::export]
pub fn plugin_bundle() -> Vec<FfiPluginFile> {
    remote::plugin_bundle()
        .into_iter()
        .map(|f| FfiPluginFile {
            path: f.path,
            contents: f.contents,
        })
        .collect()
}

#[uniffi::export]
pub fn plugin_marketplace_dir() -> String {
    remote::PLUGIN_MARKETPLACE_DIR.to_string()
}

#[uniffi::export]
pub fn local_plugin_install_commands(claude_path: String, home: String) -> Vec<String> {
    remote::local_plugin_install_commands(&claude_path, &home)
}

#[uniffi::export]
pub fn plugin_uninstall_commands(claude_path: String) -> Vec<String> {
    remote::plugin_uninstall_commands(&claude_path)
}

#[uniffi::export]
pub fn append_tmux_block_command(path: String, lines: Vec<String>) -> String {
    remote::append_tmux_block_command(&path, &lines)
}

#[uniffi::export]
pub fn remove_tmux_block_command(path: String) -> String {
    remote::remove_tmux_block_command(&path)
}

#[uniffi::export]
pub fn merge_claude_settings(
    existing: String,
    agent_path: String,
) -> Result<String, FfiAgentError> {
    remote::merge_claude_settings(&existing, &agent_path)
        .map_err(|message| FfiAgentError::InvalidInput { message })
}

#[uniffi::export]
pub fn remove_claude_settings_hooks(existing: String) -> Result<String, FfiAgentError> {
    remote::remove_claude_settings_hooks(&existing)
        .map_err(|message| FfiAgentError::InvalidInput { message })
}

/// Shell-quoted `~/.shuai/bin/shuai-agent respond ...` for an exec channel.
#[uniffi::export]
pub fn permission_response_command(
    request_id: String,
    allow: bool,
    message: Option<String>,
) -> Result<String, FfiAgentError> {
    remote::respond_command(&request_id, allow, message.as_deref())
        .map_err(|message| FfiAgentError::InvalidInput { message })
}

#[uniffi::export]
pub fn watch_command(since: u64) -> String {
    remote::watch_command(since)
}

#[uniffi::export]
pub fn claude_agents_command(claude_path: String) -> String {
    remote::claude_agents_command(&claude_path)
}
