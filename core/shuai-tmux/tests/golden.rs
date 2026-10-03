//! Golden tests over transcripts captured from real tmux 3.6 servers (see tests/fixtures).

use shuai_tmux::ControlEvent as E;
use shuai_tmux::*;

fn run(raw: &str) -> Vec<E> {
    // Feed in awkward 7-byte chunks to exercise buffering.
    let mut p = ControlParser::new();
    let mut out = vec![];
    for chunk in raw.as_bytes().chunks(7) {
        out.extend(p.push(chunk));
    }
    out
}

/// Event kinds ignoring %output noise, for compact sequence assertions.
fn kinds(ev: &[E]) -> Vec<String> {
    ev.iter()
        .filter(|e| !matches!(e, E::Output { .. }))
        .map(|e| match e {
            E::Reply(r) => format!(
                "reply:{}:{}",
                if r.ok { "ok" } else { "err" },
                r.lines.len()
            ),
            E::WindowAdd { window } => format!("window-add {window}"),
            E::WindowRenamed { window, name } => format!("window-renamed {window} {name}"),
            E::WindowPaneChanged { window, pane } => format!("pane-changed {window} {pane}"),
            E::LayoutChange { window, .. } => format!("layout {window}"),
            E::SessionChanged { name, .. } => format!("session-changed {name}"),
            E::SessionWindowChanged { session, window } => format!("swc {session} {window}"),
            E::SessionRenamed { session, name } => format!("session-renamed {session:?} {name}"),
            E::UnlinkedWindowClose { window } => format!("unlinked-close {window}"),
            E::UnlinkedWindowAdd { window } => format!("unlinked-add {window}"),
            E::UnlinkedWindowRenamed { window, .. } => format!("unlinked-renamed {window}"),
            E::SessionsChanged => "sessions-changed".into(),
            E::Exit { .. } => "exit".into(),
            other => format!("{other:?}"),
        })
        .collect()
}

fn check_control(raw: &str) {
    let mut p = ControlParser::new();
    // we sent: list-windows, new-window, rename-window, split-window, bogus, select-window,
    // send-keys, rename-session, kill-window, refresh-client, new-session, kill-session
    for t in 0..12 {
        p.expect_reply(t);
    }
    let ev = p.push(raw.as_bytes());
    let k = kinds(&ev);
    let ev2 = run(raw);
    assert_eq!(ev2.len(), ev.len(), "chunked parsing must agree");

    // no unknown events anywhere in a real transcript
    assert!(!ev.iter().any(|e| matches!(e, E::Unknown(_))), "{k:?}");
    // initial server-originated reply, then session-changed
    assert_eq!(k[0], "reply:ok:0");
    assert_eq!(k[1], "session-changed main");
    // the list-windows reply carries exactly one line "@0 <shell>"
    let list = ev
        .iter()
        .find_map(|e| match e {
            E::Reply(r) if r.token == Some(0) => Some(r),
            _ => None,
        })
        .expect("token 0 reply");
    assert_eq!(list.lines.len(), 1);
    assert!(list.lines[0].starts_with("@0 "));
    // the bogus command is the only error and it is correlated to the 5th command
    let errs: Vec<_> = ev
        .iter()
        .filter_map(|e| match e {
            E::Reply(r) if !r.ok => Some(r),
            _ => None,
        })
        .collect();
    assert_eq!(errs.len(), 1);
    assert_eq!(errs[0].token, Some(4));
    assert!(errs[0].lines[0].contains("unknown command"));
    for needle in [
        "window-add @2",
        "window-renamed @2 renamed",
        "pane-changed @2 %3",
        "layout @2",
        "swc $0 @0",
        "session-renamed Some(SessionId(1)) renamed-sess",
        "unlinked-close @2",
        "layout @0",
        "unlinked-add @3",
        "unlinked-renamed @3",
        "sessions-changed",
        "unlinked-close @3",
    ] {
        assert!(k.iter().any(|x| x == needle), "missing {needle}: {k:?}");
    }
    assert_eq!(k.last().unwrap(), "exit");
    // layout parsed with valid checksum
    for e in &ev {
        if let E::LayoutChange { parsed, .. } = e {
            assert!(parsed.as_ref().unwrap().checksum_ok());
        }
    }
    // reassembled pane %0 output contains the echoed command result
    let mut out0 = vec![];
    for e in &ev {
        if let E::Output {
            pane: PaneId(0),
            data,
        } = e
        {
            out0.extend_from_slice(data);
        }
    }
    assert!(String::from_utf8_lossy(&out0).contains("out-3\r\n"));
}

#[test]
fn local_tmux_36_control_transcript() {
    check_control(include_str!("fixtures/local36-control.txt"));
}

#[test]
fn remote_tmux_36_control_transcript() {
    check_control(include_str!("fixtures/remote36-control.txt"));
}

#[test]
fn no_output_transcript_has_no_output_after_flag() {
    for raw in [
        include_str!("fixtures/local36-nooutput.txt"),
        include_str!("fixtures/remote36-nooutput.txt"),
    ] {
        let ev = run(raw);
        let k = kinds(&ev);
        // everything before the refresh-client reply may contain one initial %output;
        // afterwards there must be none
        let first_cmd = ev
            .iter()
            .position(|e| matches!(e, E::Reply(r) if r.flags == 1))
            .unwrap();
        assert!(
            !ev[first_cmd..]
                .iter()
                .any(|e| matches!(e, E::Output { .. })),
            "{k:?}"
        );
        assert!(k.iter().any(|x| x == "window-add @1"));
        assert_eq!(k.last().unwrap(), "exit");
    }
}

#[test]
fn cc_wrapper_synthetic() {
    // `tmux -CC` needs a tty so it cannot be captured through a pipe; this mirrors what
    // tmux 3.6 writes on a pty (DCS introducer, same body, ST terminator).
    let body = include_str!("fixtures/local36-nooutput.txt");
    let wrapped = format!("\x1bP1000p{body}\x1b\\");
    assert_eq!(kinds(&run(&wrapped)), kinds(&run(body)));
}
