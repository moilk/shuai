//! Diff behaviour for renumbering, linked windows and pane moves.

use shuai_tmux::TopologyChange as C;
use shuai_tmux::*;

fn pane(id: u32, active: bool) -> TmuxPane {
    TmuxPane {
        id: PaneId(id),
        index: id,
        active,
        current_command: "zsh".into(),
        current_path: "/".into(),
        pid: 1,
        tty: "/dev/x".into(),
        title: "t".into(),
        width: 80,
        height: 24,
    }
}
fn win(id: u32, idx: u32, name: &str, active: bool, panes: Vec<TmuxPane>) -> TmuxWindow {
    TmuxWindow {
        id: WindowId(id),
        index: idx,
        name: name.into(),
        active,
        flags: String::new(),
        panes,
    }
}
fn sess(id: u32, name: &str, windows: Vec<TmuxWindow>) -> TmuxSession {
    TmuxSession {
        id: SessionId(id),
        name: name.into(),
        attached: 1,
        windows,
    }
}
fn base() -> TmuxTopology {
    TmuxTopology {
        sessions: vec![sess(
            0,
            "main",
            vec![
                win(0, 0, "a", true, vec![pane(0, true)]),
                win(1, 1, "b", false, vec![pane(1, true), pane(2, false)]),
            ],
        )],
    }
}
const S0: SessionId = SessionId(0);

#[test]
fn renumber_windows_reports_only_index_changes() {
    let old = TmuxTopology {
        sessions: vec![sess(
            0,
            "m",
            vec![
                win(0, 0, "a", false, vec![pane(0, true)]),
                win(1, 1, "b", true, vec![pane(1, true)]),
                win(2, 2, "c", false, vec![pane(2, true)]),
            ],
        )],
    };
    let new = TmuxTopology {
        sessions: vec![sess(
            0,
            "m",
            vec![
                win(1, 0, "b", true, vec![pane(1, true)]),
                win(2, 1, "c", false, vec![pane(2, true)]),
            ],
        )],
    };
    assert_eq!(
        old.diff(&new),
        vec![
            C::WindowRemoved {
                session: S0,
                window: WindowId(0)
            },
            C::WindowIndexChanged {
                session: S0,
                window: WindowId(1),
                old: 1,
                new: 0
            },
            C::WindowIndexChanged {
                session: S0,
                window: WindowId(2),
                old: 2,
                new: 1
            },
        ]
    );
}

#[test]
fn linked_window_is_tracked_per_session() {
    let w = |name: &str| win(7, 0, name, true, vec![pane(9, true)]);
    let old = TmuxTopology {
        sessions: vec![sess(0, "a", vec![w("x")]), sess(1, "b", vec![w("x")])],
    };
    let new = TmuxTopology {
        sessions: vec![sess(0, "a", vec![w("y")]), sess(1, "b", vec![])],
    };
    assert_eq!(
        old.diff(&new),
        vec![
            C::WindowRemoved {
                session: SessionId(1),
                window: WindowId(7)
            },
            C::WindowRenamed {
                session: S0,
                window: WindowId(7),
                old: "x".into(),
                new: "y".into()
            },
        ]
    );
}

#[test]
fn pane_move_between_windows_is_remove_plus_add() {
    let old = base();
    let mut new = base();
    let moved = new.sessions[0].windows[1].panes.remove(1);
    new.sessions[0].windows[0].panes.push(moved);
    assert_eq!(
        old.diff(&new),
        vec![
            C::PaneRemoved {
                session: S0,
                window: WindowId(1),
                pane: PaneId(2)
            },
            C::PaneAdded {
                session: S0,
                window: WindowId(0),
                pane: PaneId(2)
            },
        ]
    );
}

#[test]
fn break_pane_creates_window_and_moves_pane() {
    let old = base();
    let mut new = base();
    let moved = new.sessions[0].windows[1].panes.remove(1);
    new.sessions[0]
        .windows
        .push(win(5, 2, "new", false, vec![moved]));
    let d = old.diff(&new);
    assert!(d.contains(&C::PaneRemoved {
        session: S0,
        window: WindowId(1),
        pane: PaneId(2)
    }));
    assert!(d.contains(&C::WindowAdded {
        session: S0,
        window: WindowId(5),
        index: 2,
        name: "new".into()
    }));
    // By design `WindowAdded` implies the window's whole subtree: no per-pane PaneAdded.
    assert!(!d.iter().any(|c| matches!(c, C::PaneAdded { .. })));
}
