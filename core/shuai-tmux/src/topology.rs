//! Session -> window -> pane tree and diffing.

use crate::ids::{PaneId, SessionId, WindowId};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TmuxPane {
    pub id: PaneId,
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

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TmuxWindow {
    pub id: WindowId,
    pub index: u32,
    pub name: String,
    pub active: bool,
    pub flags: String,
    pub panes: Vec<TmuxPane>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TmuxSession {
    pub id: SessionId,
    pub name: String,
    pub attached: u32,
    pub windows: Vec<TmuxWindow>,
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct TmuxTopology {
    pub sessions: Vec<TmuxSession>,
}

/// One difference between two topologies. Windows/panes are keyed by
/// `(session, window[, pane])` because a window can be linked into several sessions.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TopologyChange {
    SessionAdded {
        id: SessionId,
        name: String,
    },
    SessionRemoved {
        id: SessionId,
    },
    SessionRenamed {
        id: SessionId,
        old: String,
        new: String,
    },
    SessionAttachedChanged {
        id: SessionId,
        attached: u32,
    },
    WindowAdded {
        session: SessionId,
        window: WindowId,
        index: u32,
        name: String,
    },
    WindowRemoved {
        session: SessionId,
        window: WindowId,
    },
    WindowRenamed {
        session: SessionId,
        window: WindowId,
        old: String,
        new: String,
    },
    WindowIndexChanged {
        session: SessionId,
        window: WindowId,
        old: u32,
        new: u32,
    },
    /// The active window of a session changed (reports the newly active window).
    ActiveWindowChanged {
        session: SessionId,
        window: WindowId,
    },
    PaneAdded {
        session: SessionId,
        window: WindowId,
        pane: PaneId,
    },
    PaneRemoved {
        session: SessionId,
        window: WindowId,
        pane: PaneId,
    },
    /// The active pane of a window changed (reports the newly active pane).
    ActivePaneChanged {
        session: SessionId,
        window: WindowId,
        pane: PaneId,
    },
    PaneCommandChanged {
        pane: PaneId,
        old: String,
        new: String,
    },
    PanePathChanged {
        pane: PaneId,
        old: String,
        new: String,
    },
    PaneTitleChanged {
        pane: PaneId,
        old: String,
        new: String,
    },
    PaneResized {
        pane: PaneId,
        width: u32,
        height: u32,
    },
}

impl TmuxTopology {
    /// Changes needed to go from `self` to `new`: removals first, then additions, then
    /// modifications, each in tree order.
    pub fn diff(&self, _new: &TmuxTopology) -> Vec<TopologyChange> {
        todo!()
    }
}
