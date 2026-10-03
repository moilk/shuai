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

#[test]
fn identical_is_empty() {
    assert!(base().diff(&base()).is_empty());
}

#[test]
fn session_changes() {
    let mut n = base();
    n.sessions[0].name = "renamed".into();
    n.sessions[0].attached = 2;
    n.sessions.push(sess(5, "new", vec![]));
    assert_eq!(
        base().diff(&n),
        vec![
            C::SessionAdded {
                id: SessionId(5),
                name: "new".into()
            },
            C::SessionRenamed {
                id: SessionId(0),
                old: "main".into(),
                new: "renamed".into()
            },
            C::SessionAttachedChanged {
                id: SessionId(0),
                attached: 2
            },
        ]
    );
    // and removal; added/removed parents do not enumerate children
    assert_eq!(n.diff(&base()).len(), 3);
    assert_eq!(
        base().diff(&TmuxTopology::default()),
        vec![C::SessionRemoved { id: SessionId(0) }]
    );
}

#[test]
fn window_changes_ordered_removed_added_modified() {
    let mut n = base();
    n.sessions[0].windows.remove(0); // remove @0
    n.sessions[0]
        .windows
        .push(win(9, 2, "c", false, vec![pane(9, true)]));
    n.sessions[0].windows[0].name = "bee".into(); // @1 renamed
    n.sessions[0].windows[0].index = 0;
    let s = SessionId(0);
    assert_eq!(
        base().diff(&n),
        vec![
            C::WindowRemoved {
                session: s,
                window: WindowId(0)
            },
            C::WindowAdded {
                session: s,
                window: WindowId(9),
                index: 2,
                name: "c".into()
            },
            C::WindowRenamed {
                session: s,
                window: WindowId(1),
                old: "b".into(),
                new: "bee".into()
            },
            C::WindowIndexChanged {
                session: s,
                window: WindowId(1),
                old: 1,
                new: 0
            },
        ]
    );
}

#[test]
fn active_window_and_pane() {
    let mut n = base();
    n.sessions[0].windows[0].active = false;
    n.sessions[0].windows[1].active = true;
    n.sessions[0].windows[1].panes[0].active = false;
    n.sessions[0].windows[1].panes[1].active = true;
    let s = SessionId(0);
    assert_eq!(
        base().diff(&n),
        vec![
            C::ActiveWindowChanged {
                session: s,
                window: WindowId(1)
            },
            C::ActivePaneChanged {
                session: s,
                window: WindowId(1),
                pane: PaneId(2)
            },
        ]
    );
}

#[test]
fn pane_changes() {
    let mut n = base();
    let w = &mut n.sessions[0].windows[1];
    w.panes.remove(0); // %1 removed
    w.panes.push(pane(7, false)); // %7 added
    w.panes[0].current_command = "vim".into();
    w.panes[0].current_path = "/tmp".into();
    w.panes[0].title = "T".into();
    w.panes[0].width = 100;
    let (s, win) = (SessionId(0), WindowId(1));
    assert_eq!(
        base().diff(&n),
        vec![
            C::PaneRemoved {
                session: s,
                window: win,
                pane: PaneId(1)
            },
            C::PaneAdded {
                session: s,
                window: win,
                pane: PaneId(7)
            },
            C::PaneCommandChanged {
                pane: PaneId(2),
                old: "zsh".into(),
                new: "vim".into()
            },
            C::PanePathChanged {
                pane: PaneId(2),
                old: "/".into(),
                new: "/tmp".into()
            },
            C::PaneTitleChanged {
                pane: PaneId(2),
                old: "t".into(),
                new: "T".into()
            },
            C::PaneResized {
                pane: PaneId(2),
                width: 100,
                height: 24
            },
        ]
    );
}

#[test]
fn linked_window_in_two_sessions_is_keyed_by_session() {
    let shared = win(4, 0, "shared", true, vec![pane(4, true)]);
    let old = TmuxTopology {
        sessions: vec![
            sess(0, "a", vec![shared.clone()]),
            sess(1, "b", vec![shared.clone()]),
        ],
    };
    let mut renamed = shared.clone();
    renamed.name = "x".into();
    let new = TmuxTopology {
        sessions: vec![
            sess(0, "a", vec![renamed.clone()]),
            sess(1, "b", vec![renamed]),
        ],
    };
    let d = old.diff(&new);
    assert_eq!(d.len(), 2);
    assert!(matches!(
        d[0],
        C::WindowRenamed {
            session: SessionId(0),
            ..
        }
    ));
    assert!(matches!(
        d[1],
        C::WindowRenamed {
            session: SessionId(1),
            ..
        }
    ));
}
