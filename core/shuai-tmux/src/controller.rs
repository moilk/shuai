//! Sans-io helper for the `tmux -C attach` notification side channel.
//!
//! Usage: exec [`TmuxController::attach_command`] on a channel, write every line returned by
//! [`TmuxController::on_connected`] (plus `\n`) to its stdin, feed its stdout to
//! [`TmuxController::push`] and react to the [`ControllerEvent`]s. Topology itself is read
//! with `list-panes -a -F PANE_FORMAT` (via exec or [`TmuxController::send`]) whenever
//! [`ControllerEvent::NeedsRefresh`] arrives.

use std::collections::HashSet;

use crate::cmd::{self, TmuxCommand};
use crate::control::{CommandReply, ControlEvent, ControlParser};
use crate::ids::{SessionId, WindowId};
use crate::version::{TmuxVersion, suppress_output_commands};

/// Tokens at or above this are used for the controller's own setup commands.
const INTERNAL_BASE: u64 = 1 << 63;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ControllerEvent {
    /// Something structural changed: re-run `list-panes -a -F PANE_FORMAT`. At most one per
    /// [`TmuxController::push`] call.
    NeedsRefresh,
    /// Direct patch: see [`crate::topology::TmuxTopology::rename_window`].
    WindowRenamed { window: WindowId, name: String },
    /// Direct patch: see [`crate::topology::TmuxTopology::rename_session`].
    SessionRenamed { session: SessionId, name: String },
    /// Reply to a command sent through [`TmuxController::send`].
    Reply(CommandReply),
    /// The control client ended (`%exit`).
    Exited(Option<String>),
}

#[derive(Debug)]
pub struct TmuxController {
    session: String,
    version: TmuxVersion,
    parser: ControlParser,
    next_token: u64,
    internal: HashSet<u64>,
}

impl TmuxController {
    pub fn new(session: &str, version: TmuxVersion) -> Self {
        Self {
            session: session.to_string(),
            version,
            parser: ControlParser::new(),
            next_token: 0,
            internal: HashSet::new(),
        }
    }

    /// The command to exec for the side channel (`tmux -C attach-session -t =S:`).
    pub fn attach_command(&self) -> TmuxCommand {
        cmd::control_attach(&self.session, false)
    }

    /// Shell line to exec for the side channel: [`attach_command`](Self::attach_command) under
    /// the supervisor that makes it exit with its SSH session (see
    /// [`TmuxCommand::to_supervised_shell`]).
    pub fn attach_shell(&self) -> String {
        self.attach_command().to_supervised_shell()
    }

    /// Lines to write to stdin once the channel is up (output suppression). Empty on tmux
    /// without `no-output`; `%output` is discarded by [`push`](Self::push) regardless.
    pub fn on_connected(&mut self) -> Vec<String> {
        suppress_output_commands(&self.version)
            .iter()
            .map(|c| {
                let tok = INTERNAL_BASE + self.next_token;
                self.next_token += 1;
                self.internal.insert(tok);
                self.parser.expect_reply(tok);
                c.to_control_line()
            })
            .collect()
    }

    /// Register a command to be written to stdin; returns its reply token and the line.
    pub fn send(&mut self, c: &TmuxCommand) -> (u64, String) {
        let tok = self.next_token;
        self.next_token += 1;
        self.parser.expect_reply(tok);
        (tok, c.to_control_line())
    }

    /// Feed stdout bytes.
    pub fn push(&mut self, data: &[u8]) -> Vec<ControllerEvent> {
        use ControlEvent as C;
        let mut out = vec![];
        let mut refresh = false;
        for ev in self.parser.push(data) {
            match ev {
                C::Reply(r) => match r.token {
                    Some(t) if self.internal.remove(&t) => {}
                    Some(_) => out.push(ControllerEvent::Reply(r)),
                    None => {}
                },
                C::WindowRenamed { window, name } | C::UnlinkedWindowRenamed { window, name } => {
                    out.push(ControllerEvent::WindowRenamed { window, name })
                }
                C::SessionRenamed {
                    session: Some(session),
                    name,
                } => out.push(ControllerEvent::SessionRenamed { session, name }),
                C::SessionRenamed { session: None, .. }
                | C::WindowAdd { .. }
                | C::WindowClose { .. }
                | C::UnlinkedWindowAdd { .. }
                | C::UnlinkedWindowClose { .. }
                | C::WindowPaneChanged { .. }
                | C::SessionChanged { .. }
                | C::SessionsChanged
                | C::SessionWindowChanged { .. }
                | C::LayoutChange { .. }
                | C::ClientSessionChanged { .. }
                | C::SubscriptionChanged { .. } => refresh = true,
                C::Exit { reason } => out.push(ControllerEvent::Exited(reason)),
                C::Output { .. }
                | C::ExtendedOutput { .. }
                | C::PaneModeChanged { .. }
                | C::ClientDetached { .. }
                | C::Pause { .. }
                | C::Continue { .. }
                | C::Unknown(_) => {}
            }
        }
        if refresh {
            out.push(ControllerEvent::NeedsRefresh);
        }
        out
    }
}
