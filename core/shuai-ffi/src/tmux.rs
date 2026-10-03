//! tmux command builders, topology parsing and the control-mode side-channel controller.
//! Everything crosses the boundary as data (string ids like `$0`, `@1`, `%2`).

use std::str::FromStr;
use std::sync::{Arc, Mutex};

use shuai_tmux::clients::TmuxClient;
use shuai_tmux::cmd::PaneDirection;
use shuai_tmux::controller::ControllerEvent;
use shuai_tmux::{
    Capabilities, Direction, PaneId, SessionId, Target, TmuxCommand, TmuxPane, TmuxSession,
    TmuxTopology, TmuxVersion, TmuxWindow, TopologyChange, WindowId, cmd,
};

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error, uniffi::Error)]
pub enum FfiTmuxError {
    #[error("invalid tmux id: {value}")]
    InvalidId { value: String },
    #[error("parse error: {message}")]
    Parse { message: String },
    #[error("unrecognised tmux version: {value}")]
    BadVersion { value: String },
}

/// A tmux command in the three forms callers need.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FfiTmuxCommand {
    /// Raw arguments after `tmux`.
    pub argv: Vec<String>,
    /// Shell line (`tmux ...`) for an SSH exec channel.
    pub shell: String,
    /// Control-mode stdin line (no trailing newline).
    pub control_line: String,
}

impl From<TmuxCommand> for FfiTmuxCommand {
    fn from(c: TmuxCommand) -> Self {
        Self {
            argv: c.argv().to_vec(),
            shell: c.to_shell(),
            control_line: c.to_control_line(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FfiTmuxPane {
    pub id: String,
    pub index: u32,
    pub active: bool,
    pub current_command: String,
    pub current_path: String,
    pub pid: u32,
    pub tty: String,
    pub title: String,
    pub width: u32,
    pub height: u32,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FfiTmuxWindow {
    pub id: String,
    pub index: u32,
    pub name: String,
    pub active: bool,
    pub flags: String,
    pub panes: Vec<FfiTmuxPane>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FfiTmuxSession {
    pub id: String,
    pub name: String,
    pub attached: u32,
    pub windows: Vec<FfiTmuxWindow>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FfiTopology {
    pub sessions: Vec<FfiTmuxSession>,
}

impl From<&TmuxTopology> for FfiTopology {
    fn from(t: &TmuxTopology) -> Self {
        FfiTopology {
            sessions: t
                .sessions
                .iter()
                .map(|s| FfiTmuxSession {
                    id: s.id.to_string(),
                    name: s.name.clone(),
                    attached: s.attached,
                    windows: s
                        .windows
                        .iter()
                        .map(|w| FfiTmuxWindow {
                            id: w.id.to_string(),
                            index: w.index,
                            name: w.name.clone(),
                            active: w.active,
                            flags: w.flags.clone(),
                            panes: w
                                .panes
                                .iter()
                                .map(|p| FfiTmuxPane {
                                    id: p.id.to_string(),
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
                                .collect(),
                        })
                        .collect(),
                })
                .collect(),
        }
    }
}

fn invalid(value: &str) -> FfiTmuxError {
    FfiTmuxError::InvalidId {
        value: value.to_string(),
    }
}

fn window_target(id: &str) -> Result<Target, FfiTmuxError> {
    WindowId::from_str(id)
        .map(Target::window)
        .map_err(|_| invalid(id))
}

fn pane_target(id: &str) -> Result<Target, FfiTmuxError> {
    PaneId::from_str(id)
        .map(Target::pane)
        .map_err(|_| invalid(id))
}

/// Parses the output of `tmux list-panes -a -F PANE_FORMAT` (see [`tmux_list_panes_all`]).
#[uniffi::export]
pub fn parse_topology(text: String) -> Result<FfiTopology, FfiTmuxError> {
    shuai_tmux::parse::parse_topology(&text)
        .map(|t| FfiTopology::from(&t))
        .map_err(|e| FfiTmuxError::Parse {
            message: e.to_string(),
        })
}

#[uniffi::export]
pub fn tmux_list_panes_all() -> FfiTmuxCommand {
    cmd::list_panes_all().into()
}

#[uniffi::export]
pub fn tmux_version_command() -> FfiTmuxCommand {
    cmd::tmux_version().into()
}

/// `new-session -A -s NAME [-x W -y H] [-c CWD]`: attach, creating the session if needed.
#[uniffi::export]
pub fn tmux_new_session_attach(
    name: String,
    size: Option<FfiSize>,
    cwd: Option<String>,
) -> FfiTmuxCommand {
    cmd::new_session_attach(&name, size.map(|s| (s.cols, s.rows)), cwd.as_deref()).into()
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct FfiSize {
    pub cols: u32,
    pub rows: u32,
}

#[uniffi::export]
pub fn tmux_select_window(window_id: String) -> Result<FfiTmuxCommand, FfiTmuxError> {
    Ok(cmd::select_window(&window_target(&window_id)?).into())
}

#[uniffi::export]
pub fn tmux_select_pane(pane_id: String) -> Result<FfiTmuxCommand, FfiTmuxError> {
    Ok(cmd::select_pane(&pane_target(&pane_id)?).into())
}

/// `session` is a session name (exact match is enforced).
#[uniffi::export]
pub fn tmux_new_window(
    session: String,
    cwd: Option<String>,
    name: Option<String>,
) -> FfiTmuxCommand {
    cmd::new_window(&Target::session(&session), cwd.as_deref(), name.as_deref()).into()
}

#[uniffi::export]
pub fn tmux_kill_window(window_id: String) -> Result<FfiTmuxCommand, FfiTmuxError> {
    Ok(cmd::kill_window(&window_target(&window_id)?).into())
}

#[uniffi::export]
pub fn tmux_rename_window(window_id: String, name: String) -> Result<FfiTmuxCommand, FfiTmuxError> {
    Ok(cmd::rename_window(&window_target(&window_id)?, &name).into())
}

/// Splits `pane_id`; `horizontal` puts the panes side by side.
#[uniffi::export]
pub fn tmux_split_window(
    pane_id: String,
    horizontal: bool,
    cwd: Option<String>,
) -> Result<FfiTmuxCommand, FfiTmuxError> {
    let dir = if horizontal {
        Direction::Horizontal
    } else {
        Direction::Vertical
    };
    Ok(cmd::split_window(&pane_target(&pane_id)?, dir, cwd.as_deref()).into())
}

#[uniffi::export]
pub fn tmux_send_keys_literal(
    pane_id: String,
    text: String,
) -> Result<FfiTmuxCommand, FfiTmuxError> {
    Ok(cmd::send_keys_literal(&pane_target(&pane_id)?, &text).into())
}

#[uniffi::export]
pub fn tmux_zoom_pane(pane_id: String) -> Result<FfiTmuxCommand, FfiTmuxError> {
    Ok(cmd::zoom_pane(&pane_target(&pane_id)?).into())
}

/// Next/previous/last window of the session with this exact name.
#[uniffi::export]
pub fn tmux_next_window(session: String) -> FfiTmuxCommand {
    cmd::next_window(&Target::session(&session)).into()
}

#[uniffi::export]
pub fn tmux_previous_window(session: String) -> FfiTmuxCommand {
    cmd::previous_window(&Target::session(&session)).into()
}

#[uniffi::export]
pub fn tmux_last_window(session: String) -> FfiTmuxCommand {
    cmd::last_window(&Target::session(&session)).into()
}

/// `switch-client -c CLIENT_TTY -t SESSION_ID`: moves the named client (our PTY terminal).
#[uniffi::export]
pub fn tmux_switch_client(
    client_tty: String,
    session_id: String,
) -> Result<FfiTmuxCommand, FfiTmuxError> {
    let id = SessionId::from_str(&session_id).map_err(|_| invalid(&session_id))?;
    Ok(cmd::switch_client(&client_tty, &Target::session_id(id)).into())
}

#[uniffi::export]
pub fn tmux_list_clients() -> FfiTmuxCommand {
    cmd::list_clients().into()
}

/// `display-message -p -- FORMAT`.
#[uniffi::export]
pub fn tmux_display_message(format: String) -> FfiTmuxCommand {
    cmd::display_message(None, &format).into()
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum FfiPaneDirection {
    Left,
    Right,
    Up,
    Down,
}

/// Selects the neighbour pane of the active pane in window `window_id`.
#[uniffi::export]
pub fn tmux_select_pane_direction(
    window_id: String,
    direction: FfiPaneDirection,
) -> Result<FfiTmuxCommand, FfiTmuxError> {
    let d = match direction {
        FfiPaneDirection::Left => PaneDirection::Left,
        FfiPaneDirection::Right => PaneDirection::Right,
        FfiPaneDirection::Up => PaneDirection::Up,
        FfiPaneDirection::Down => PaneDirection::Down,
    };
    Ok(cmd::select_pane_direction(&window_target(&window_id)?, d).into())
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FfiTmuxClient {
    pub tty: String,
    pub pid: u32,
    pub session_id: String,
    pub session_name: String,
    pub control_mode: bool,
    pub created: u64,
    pub width: u32,
    pub height: u32,
}

impl From<&TmuxClient> for FfiTmuxClient {
    fn from(c: &TmuxClient) -> Self {
        Self {
            tty: c.tty.clone(),
            pid: c.pid,
            session_id: c.session_id.to_string(),
            session_name: c.session_name.clone(),
            control_mode: c.control_mode,
            created: c.created,
            width: c.width,
            height: c.height,
        }
    }
}

impl TryFrom<&FfiTmuxClient> for TmuxClient {
    type Error = FfiTmuxError;
    fn try_from(c: &FfiTmuxClient) -> Result<Self, Self::Error> {
        Ok(Self {
            tty: c.tty.clone(),
            pid: c.pid,
            session_id: SessionId::from_str(&c.session_id).map_err(|_| invalid(&c.session_id))?,
            session_name: c.session_name.clone(),
            control_mode: c.control_mode,
            created: c.created,
            width: c.width,
            height: c.height,
        })
    }
}

/// Parses the output of `list-clients` (see [`tmux_list_clients`]).
#[uniffi::export]
pub fn parse_clients(text: String) -> Result<Vec<FfiTmuxClient>, FfiTmuxError> {
    shuai_tmux::clients::parse_clients(&text)
        .map(|v| v.iter().map(FfiTmuxClient::from).collect())
        .map_err(|e| FfiTmuxError::Parse {
            message: e.to_string(),
        })
}

fn to_core_clients(clients: &[FfiTmuxClient]) -> Vec<TmuxClient> {
    // Rows with an unparseable session id cannot be our client: drop them.
    clients.iter().filter_map(|c| c.try_into().ok()).collect()
}

/// tty of our PTY client among the clients attached to `session` (see
/// `shuai_tmux::clients::pick_pty_client`).
#[uniffi::export]
pub fn pick_pty_client(
    clients: Vec<FfiTmuxClient>,
    session: String,
    control_pid: Option<u32>,
    size: Option<FfiSize>,
) -> Option<String> {
    shuai_tmux::clients::pick_pty_client(
        &to_core_clients(&clients),
        &session,
        control_pid,
        size.map(|s| (s.cols, s.rows)),
    )
}

/// Like [`pick_pty_client`] but whichever session the client currently shows.
#[uniffi::export]
pub fn pick_pty_client_any_session(
    clients: Vec<FfiTmuxClient>,
    control_pid: Option<u32>,
    size: Option<FfiSize>,
) -> Option<String> {
    shuai_tmux::clients::pick_pty_client_any_session(
        &to_core_clients(&clients),
        control_pid,
        size.map(|s| (s.cols, s.rows)),
    )
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct FfiTmuxCapabilities {
    pub control_mode: bool,
    /// `refresh-client -f no-output` (the control channel is then notification-only).
    pub no_output: bool,
    pub subscriptions: bool,
}

/// `version_output` is the text printed by `tmux -V`.
#[uniffi::export]
pub fn tmux_capabilities(version_output: String) -> Result<FfiTmuxCapabilities, FfiTmuxError> {
    let v = TmuxVersion::parse(&version_output).ok_or(FfiTmuxError::BadVersion {
        value: version_output,
    })?;
    let c = Capabilities::for_version(&v);
    Ok(FfiTmuxCapabilities {
        control_mode: c.control_mode,
        no_output: c.no_output,
        subscriptions: c.subscriptions,
    })
}

impl TryFrom<&FfiTopology> for TmuxTopology {
    type Error = FfiTmuxError;
    fn try_from(t: &FfiTopology) -> Result<Self, Self::Error> {
        fn id<T: FromStr>(s: &str) -> Result<T, FfiTmuxError> {
            T::from_str(s).map_err(|_| invalid(s))
        }
        let mut sessions = vec![];
        for s in &t.sessions {
            let mut windows = vec![];
            for w in &s.windows {
                let mut panes = vec![];
                for p in &w.panes {
                    panes.push(TmuxPane {
                        id: id(&p.id)?,
                        index: p.index,
                        active: p.active,
                        current_command: p.current_command.clone(),
                        current_path: p.current_path.clone(),
                        pid: p.pid,
                        tty: p.tty.clone(),
                        title: p.title.clone(),
                        width: p.width,
                        height: p.height,
                    });
                }
                windows.push(TmuxWindow {
                    id: id(&w.id)?,
                    index: w.index,
                    name: w.name.clone(),
                    active: w.active,
                    flags: w.flags.clone(),
                    panes,
                });
            }
            sessions.push(TmuxSession {
                id: id(&s.id)?,
                name: s.name.clone(),
                attached: s.attached,
                windows,
            });
        }
        Ok(TmuxTopology { sessions })
    }
}

/// One difference between two topologies (see `shuai_tmux::TopologyChange`).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum FfiTopologyChange {
    SessionAdded {
        session_id: String,
        name: String,
    },
    SessionRemoved {
        session_id: String,
    },
    SessionRenamed {
        session_id: String,
        old: String,
        new: String,
    },
    SessionAttachedChanged {
        session_id: String,
        attached: u32,
    },
    WindowAdded {
        session_id: String,
        window_id: String,
        index: u32,
        name: String,
    },
    WindowRemoved {
        session_id: String,
        window_id: String,
    },
    WindowRenamed {
        session_id: String,
        window_id: String,
        old: String,
        new: String,
    },
    WindowIndexChanged {
        session_id: String,
        window_id: String,
        old: u32,
        new: u32,
    },
    ActiveWindowChanged {
        session_id: String,
        window_id: String,
    },
    PaneAdded {
        session_id: String,
        window_id: String,
        pane_id: String,
    },
    PaneRemoved {
        session_id: String,
        window_id: String,
        pane_id: String,
    },
    ActivePaneChanged {
        session_id: String,
        window_id: String,
        pane_id: String,
    },
    PaneCommandChanged {
        pane_id: String,
        old: String,
        new: String,
    },
    PanePathChanged {
        pane_id: String,
        old: String,
        new: String,
    },
    PaneTitleChanged {
        pane_id: String,
        old: String,
        new: String,
    },
    PaneResized {
        pane_id: String,
        width: u32,
        height: u32,
    },
}

impl From<TopologyChange> for FfiTopologyChange {
    fn from(c: TopologyChange) -> Self {
        use TopologyChange as T;
        let s = |x: SessionId| x.to_string();
        let w = |x: WindowId| x.to_string();
        let p = |x: PaneId| x.to_string();
        match c {
            T::SessionAdded { id, name } => Self::SessionAdded {
                session_id: s(id),
                name,
            },
            T::SessionRemoved { id } => Self::SessionRemoved { session_id: s(id) },
            T::SessionRenamed { id, old, new } => Self::SessionRenamed {
                session_id: s(id),
                old,
                new,
            },
            T::SessionAttachedChanged { id, attached } => Self::SessionAttachedChanged {
                session_id: s(id),
                attached,
            },
            T::WindowAdded {
                session,
                window,
                index,
                name,
            } => Self::WindowAdded {
                session_id: s(session),
                window_id: w(window),
                index,
                name,
            },
            T::WindowRemoved { session, window } => Self::WindowRemoved {
                session_id: s(session),
                window_id: w(window),
            },
            T::WindowRenamed {
                session,
                window,
                old,
                new,
            } => Self::WindowRenamed {
                session_id: s(session),
                window_id: w(window),
                old,
                new,
            },
            T::WindowIndexChanged {
                session,
                window,
                old,
                new,
            } => Self::WindowIndexChanged {
                session_id: s(session),
                window_id: w(window),
                old,
                new,
            },
            T::ActiveWindowChanged { session, window } => Self::ActiveWindowChanged {
                session_id: s(session),
                window_id: w(window),
            },
            T::PaneAdded {
                session,
                window,
                pane,
            } => Self::PaneAdded {
                session_id: s(session),
                window_id: w(window),
                pane_id: p(pane),
            },
            T::PaneRemoved {
                session,
                window,
                pane,
            } => Self::PaneRemoved {
                session_id: s(session),
                window_id: w(window),
                pane_id: p(pane),
            },
            T::ActivePaneChanged {
                session,
                window,
                pane,
            } => Self::ActivePaneChanged {
                session_id: s(session),
                window_id: w(window),
                pane_id: p(pane),
            },
            T::PaneCommandChanged { pane, old, new } => Self::PaneCommandChanged {
                pane_id: p(pane),
                old,
                new,
            },
            T::PanePathChanged { pane, old, new } => Self::PanePathChanged {
                pane_id: p(pane),
                old,
                new,
            },
            T::PaneTitleChanged { pane, old, new } => Self::PaneTitleChanged {
                pane_id: p(pane),
                old,
                new,
            },
            T::PaneResized {
                pane,
                width,
                height,
            } => Self::PaneResized {
                pane_id: p(pane),
                width,
                height,
            },
        }
    }
}

/// Changes needed to go from `old` to `new` (removals, additions, then modifications).
#[uniffi::export]
pub fn diff_topology(
    old: FfiTopology,
    new: FfiTopology,
) -> Result<Vec<FfiTopologyChange>, FfiTmuxError> {
    let old = TmuxTopology::try_from(&old)?;
    let new = TmuxTopology::try_from(&new)?;
    Ok(old.diff(&new).into_iter().map(Into::into).collect())
}

/// A command registered with the controller: write `line` + `\n` to the channel's stdin and
/// match the reply by `token`.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FfiSentCommand {
    pub token: u64,
    pub line: String,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum FfiControllerEvent {
    /// Structure changed: re-run `list-panes -a` and re-parse.
    NeedsRefresh,
    WindowRenamed {
        window_id: String,
        name: String,
    },
    SessionRenamed {
        session_id: String,
        name: String,
    },
    Reply {
        token: u64,
        ok: bool,
        lines: Vec<String>,
    },
    Exited {
        reason: Option<String>,
    },
}

/// Control-mode (`tmux -C`) side-channel helper (sans-io, see `shuai_tmux::controller`).
#[derive(uniffi::Object)]
pub struct TmuxController {
    inner: Mutex<shuai_tmux::controller::TmuxController>,
}

#[uniffi::export]
impl TmuxController {
    /// `version_output` is the text printed by `tmux -V`.
    #[uniffi::constructor]
    pub fn new(session: String, version_output: String) -> Result<Arc<Self>, FfiTmuxError> {
        let v = TmuxVersion::parse(&version_output).ok_or(FfiTmuxError::BadVersion {
            value: version_output,
        })?;
        Ok(Arc::new(Self {
            inner: Mutex::new(shuai_tmux::controller::TmuxController::new(&session, v)),
        }))
    }

    /// Command to exec for the side channel.
    pub fn attach_command(&self) -> FfiTmuxCommand {
        self.inner.lock().unwrap().attach_command().into()
    }

    /// Lines (without `\n`) to write to stdin once the channel is up.
    pub fn on_connected(&self) -> Vec<String> {
        self.inner.lock().unwrap().on_connected()
    }

    pub fn send(&self, command: FfiTmuxCommand) -> FfiSentCommand {
        let (token, line) = self
            .inner
            .lock()
            .unwrap()
            .send(&TmuxCommand::from_argv(command.argv));
        FfiSentCommand { token, line }
    }

    /// Feeds stdout bytes of the side channel.
    pub fn push(&self, data: Vec<u8>) -> Vec<FfiControllerEvent> {
        self.inner
            .lock()
            .unwrap()
            .push(&data)
            .into_iter()
            .map(|e| match e {
                ControllerEvent::NeedsRefresh => FfiControllerEvent::NeedsRefresh,
                ControllerEvent::WindowRenamed { window, name } => {
                    FfiControllerEvent::WindowRenamed {
                        window_id: window.to_string(),
                        name,
                    }
                }
                ControllerEvent::SessionRenamed { session, name } => {
                    FfiControllerEvent::SessionRenamed {
                        session_id: session.to_string(),
                        name,
                    }
                }
                ControllerEvent::Reply(r) => FfiControllerEvent::Reply {
                    token: r.token.unwrap_or(0),
                    ok: r.ok,
                    lines: r.lines,
                },
                ControllerEvent::Exited(reason) => FfiControllerEvent::Exited { reason },
            })
            .collect()
    }
}
