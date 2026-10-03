//! tmux command builders, topology parsing and the control-mode side-channel controller.
//! Everything crosses the boundary as data (string ids like `$0`, `@1`, `%2`).

use std::str::FromStr;
use std::sync::{Arc, Mutex};

use shuai_tmux::controller::ControllerEvent;
use shuai_tmux::{
    Direction, PaneId, Target, TmuxCommand, TmuxTopology, TmuxVersion, WindowId, cmd,
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
