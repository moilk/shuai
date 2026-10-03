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

/// One difference between two topologies. `SessionAdded` / `WindowAdded` imply the
/// whole new subtree (their windows/panes are not reported individually; read them from
/// the new topology). Windows/panes are keyed by
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
    /// Rename a window in every session it is linked into; returns how many copies changed.
    pub fn rename_window(&mut self, id: WindowId, name: &str) -> usize {
        let mut n = 0;
        for w in self.sessions.iter_mut().flat_map(|s| &mut s.windows) {
            if w.id == id {
                w.name = name.to_string();
                n += 1;
            }
        }
        n
    }

    /// Rename a session; returns how many sessions matched (0 or 1).
    pub fn rename_session(&mut self, id: SessionId, name: &str) -> usize {
        let mut n = 0;
        for s in self.sessions.iter_mut().filter(|s| s.id == id) {
            s.name = name.to_string();
            n += 1;
        }
        n
    }

    /// Changes needed to go from `self` to `new`: removals first, then additions, then
    /// modifications, each in tree order.
    pub fn diff(&self, new: &TmuxTopology) -> Vec<TopologyChange> {
        let mut d = Diff::default();
        diff_sessions(&self.sessions, &new.sessions, &mut d);
        let mut out = d.removed;
        out.extend(d.added);
        out.extend(d.modified);
        out
    }
}

#[derive(Default)]
struct Diff {
    removed: Vec<TopologyChange>,
    added: Vec<TopologyChange>,
    modified: Vec<TopologyChange>,
}

fn diff_sessions(old: &[TmuxSession], new: &[TmuxSession], d: &mut Diff) {
    for o in old {
        if !new.iter().any(|n| n.id == o.id) {
            d.removed.push(TopologyChange::SessionRemoved { id: o.id });
        }
    }
    for n in new {
        match old.iter().find(|o| o.id == n.id) {
            None => d.added.push(TopologyChange::SessionAdded {
                id: n.id,
                name: n.name.clone(),
            }),
            Some(o) => {
                if o.name != n.name {
                    d.modified.push(TopologyChange::SessionRenamed {
                        id: n.id,
                        old: o.name.clone(),
                        new: n.name.clone(),
                    });
                }
                if o.attached != n.attached {
                    d.modified.push(TopologyChange::SessionAttachedChanged {
                        id: n.id,
                        attached: n.attached,
                    });
                }
                diff_windows(n.id, &o.windows, &n.windows, d);
            }
        }
    }
}

fn diff_windows(session: SessionId, old: &[TmuxWindow], new: &[TmuxWindow], d: &mut Diff) {
    for o in old {
        if !new.iter().any(|n| n.id == o.id) {
            d.removed.push(TopologyChange::WindowRemoved {
                session,
                window: o.id,
            });
        }
    }
    for n in new {
        match old.iter().find(|o| o.id == n.id) {
            None => d.added.push(TopologyChange::WindowAdded {
                session,
                window: n.id,
                index: n.index,
                name: n.name.clone(),
            }),
            Some(o) => {
                if o.name != n.name {
                    d.modified.push(TopologyChange::WindowRenamed {
                        session,
                        window: n.id,
                        old: o.name.clone(),
                        new: n.name.clone(),
                    });
                }
                if o.index != n.index {
                    d.modified.push(TopologyChange::WindowIndexChanged {
                        session,
                        window: n.id,
                        old: o.index,
                        new: n.index,
                    });
                }
                if n.active && !o.active {
                    d.modified.push(TopologyChange::ActiveWindowChanged {
                        session,
                        window: n.id,
                    });
                }
                diff_panes(session, n.id, &o.panes, &n.panes, d);
            }
        }
    }
}

fn diff_panes(
    session: SessionId,
    window: WindowId,
    old: &[TmuxPane],
    new: &[TmuxPane],
    d: &mut Diff,
) {
    for o in old {
        if !new.iter().any(|n| n.id == o.id) {
            d.removed.push(TopologyChange::PaneRemoved {
                session,
                window,
                pane: o.id,
            });
        }
    }
    for n in new {
        let Some(o) = old.iter().find(|o| o.id == n.id) else {
            d.added.push(TopologyChange::PaneAdded {
                session,
                window,
                pane: n.id,
            });
            continue;
        };
        let pane = n.id;
        if n.active && !o.active {
            d.modified.push(TopologyChange::ActivePaneChanged {
                session,
                window,
                pane,
            });
        }
        if o.current_command != n.current_command {
            d.modified.push(TopologyChange::PaneCommandChanged {
                pane,
                old: o.current_command.clone(),
                new: n.current_command.clone(),
            });
        }
        if o.current_path != n.current_path {
            d.modified.push(TopologyChange::PanePathChanged {
                pane,
                old: o.current_path.clone(),
                new: n.current_path.clone(),
            });
        }
        if o.title != n.title {
            d.modified.push(TopologyChange::PaneTitleChanged {
                pane,
                old: o.title.clone(),
                new: n.title.clone(),
            });
        }
        if (o.width, o.height) != (n.width, n.height) {
            d.modified.push(TopologyChange::PaneResized {
                pane,
                width: n.width,
                height: n.height,
            });
        }
    }
}
