//! Sans-io parser for the tmux control-mode (`-C` / `-CC`) protocol.

use crate::ids::{PaneId, SessionId, WindowId};
use crate::layout::Layout;

/// A completed command reply block (`%begin` ... `%end` / `%error`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CommandReply {
    pub time: u64,
    /// tmux's command number.
    pub number: u64,
    pub flags: u32,
    /// `%end` -> true, `%error` -> false.
    pub ok: bool,
    /// Body lines (lossy UTF-8, without line terminators).
    pub lines: Vec<String>,
    /// Token registered with [`ControlParser::expect_reply`], if this reply answers a
    /// command sent by us (flags bit 0). Server-originated blocks (e.g. the one printed
    /// on attach) have `None`.
    pub token: Option<u64>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ControlEvent {
    Reply(CommandReply),
    Output {
        pane: PaneId,
        data: Vec<u8>,
    },
    ExtendedOutput {
        pane: PaneId,
        age_ms: u64,
        data: Vec<u8>,
    },
    WindowAdd {
        window: WindowId,
    },
    WindowClose {
        window: WindowId,
    },
    UnlinkedWindowAdd {
        window: WindowId,
    },
    UnlinkedWindowClose {
        window: WindowId,
    },
    WindowRenamed {
        window: WindowId,
        name: String,
    },
    UnlinkedWindowRenamed {
        window: WindowId,
        name: String,
    },
    WindowPaneChanged {
        window: WindowId,
        pane: PaneId,
    },
    SessionChanged {
        session: SessionId,
        name: String,
    },
    /// tmux >= 3.? includes the id; older versions only the name.
    SessionRenamed {
        session: Option<SessionId>,
        name: String,
    },
    SessionsChanged,
    SessionWindowChanged {
        session: SessionId,
        window: WindowId,
    },
    LayoutChange {
        window: WindowId,
        /// Raw layout string as sent.
        layout: String,
        visible_layout: Option<String>,
        flags: Option<String>,
        /// `layout` parsed; `None` if it did not parse.
        parsed: Option<Layout>,
    },
    PaneModeChanged {
        pane: PaneId,
    },
    ClientSessionChanged {
        client: String,
        session: SessionId,
        name: String,
    },
    ClientDetached {
        client: String,
    },
    Pause {
        pane: PaneId,
    },
    Continue {
        pane: PaneId,
    },
    SubscriptionChanged {
        name: String,
        session: Option<SessionId>,
        window: Option<WindowId>,
        window_index: Option<u32>,
        pane: Option<PaneId>,
        value: String,
    },
    Exit {
        reason: Option<String>,
    },
    /// Anything we do not recognise (forward compatible), without terminator.
    Unknown(String),
}

#[derive(Debug, Default)]
pub struct ControlParser {}

impl ControlParser {
    pub fn new() -> Self {
        Self::default()
    }
    /// Register that a command was sent; replies with flags bit 0 are matched FIFO.
    pub fn expect_reply(&mut self, _token: u64) {
        todo!()
    }
    /// Feed bytes; returns every event completed by them.
    pub fn push(&mut self, _data: &[u8]) -> Vec<ControlEvent> {
        todo!()
    }
}

/// Decode tmux `%output` payload escapes (`\ooo` -> byte).
pub fn decode_output(_s: &[u8]) -> Vec<u8> {
    todo!()
}
