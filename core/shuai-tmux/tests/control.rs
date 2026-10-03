use shuai_tmux::ControlEvent as E;
use shuai_tmux::control::decode_output;
use shuai_tmux::*;

fn parse(s: &str) -> Vec<E> {
    ControlParser::new().push(s.as_bytes())
}

#[test]
fn decode_octal() {
    assert_eq!(decode_output(br"abc"), b"abc");
    assert_eq!(decode_output(br"\033[1m\015\012"), b"\x1b[1m\r\n");
    assert_eq!(decode_output(br"a\134b"), b"a\\b");
    assert_eq!(decode_output("é中".as_bytes()), "é中".as_bytes());
    // malformed / truncated escapes are kept literally
    assert_eq!(decode_output(br"\03"), br"\03");
    assert_eq!(decode_output(br"x\"), br"x\");
    assert_eq!(decode_output(br"\8"), br"\8");
    // 0o377 is the max byte
    assert_eq!(decode_output(br"\377"), [0xff]);
}

#[test]
fn output_events() {
    assert_eq!(
        parse("%output %2 hi\\015\\012 there\n"),
        vec![E::Output {
            pane: PaneId(2),
            data: b"hi\r\n there".to_vec()
        }]
    );
    // payload may start with spaces / be empty
    assert_eq!(
        parse("%output %2  x\n%output %3 \n"),
        vec![
            E::Output {
                pane: PaneId(2),
                data: b" x".to_vec()
            },
            E::Output {
                pane: PaneId(3),
                data: vec![]
            },
        ]
    );
    assert_eq!(
        parse("%extended-output %1 250 : \\033[0m\n"),
        vec![E::ExtendedOutput {
            pane: PaneId(1),
            age_ms: 250,
            data: b"\x1b[0m".to_vec()
        }]
    );
}

#[test]
fn raw_8bit_in_output_is_preserved() {
    let mut p = ControlParser::new();
    let ev = p.push(b"%output %0 \xe4\xb8\xad\xff\n");
    assert_eq!(
        ev,
        vec![E::Output {
            pane: PaneId(0),
            data: vec![0xe4, 0xb8, 0xad, 0xff]
        }]
    );
}

#[test]
fn partial_lines_across_chunks() {
    let mut p = ControlParser::new();
    assert!(p.push(b"%window-ad").is_empty());
    assert!(p.push(b"d @").is_empty());
    assert_eq!(
        p.push(b"4\n%sessions-ch"),
        vec![E::WindowAdd {
            window: WindowId(4)
        }]
    );
    assert_eq!(p.push(b"anged\n"), vec![E::SessionsChanged]);
    // byte-at-a-time
    let mut p = ControlParser::new();
    let mut all = vec![];
    for b in "%output %1 a\\015\n%exit\n".bytes() {
        all.extend(p.push(&[b]));
    }
    assert_eq!(
        all,
        vec![
            E::Output {
                pane: PaneId(1),
                data: b"a\r".to_vec()
            },
            E::Exit { reason: None }
        ]
    );
}

#[test]
fn crlf_is_tolerated() {
    assert_eq!(parse("%sessions-changed\r\n"), vec![E::SessionsChanged]);
}

#[test]
fn reply_blocks_correlate_fifo() {
    let mut p = ControlParser::new();
    p.expect_reply(100);
    p.expect_reply(101);
    let ev = p.push(
        b"%begin 1700 10 0\n%end 1700 10 0\n\
          %begin 1701 11 1\n@0 zsh\n@1 vim\n%end 1701 11 1\n\
          %begin 1702 12 1\nparse error: nope\n%error 1702 12 1\n",
    );
    assert_eq!(
        ev,
        vec![
            E::Reply(CommandReply {
                time: 1700,
                number: 10,
                flags: 0,
                ok: true,
                lines: vec![],
                token: None
            }),
            E::Reply(CommandReply {
                time: 1701,
                number: 11,
                flags: 1,
                ok: true,
                lines: vec!["@0 zsh".into(), "@1 vim".into()],
                token: Some(100)
            }),
            E::Reply(CommandReply {
                time: 1702,
                number: 12,
                flags: 1,
                ok: false,
                lines: vec!["parse error: nope".into()],
                token: Some(101)
            }),
        ]
    );
}

#[test]
fn reply_body_may_look_like_notifications_and_span_chunks() {
    let mut p = ControlParser::new();
    p.expect_reply(1);
    assert!(
        p.push(b"%begin 5 7 1\n%output %1 not an event\n%end 5 8 1\n%en")
            .is_empty()
    );
    let ev = p.push(b"d 5 7 1\n%window-add @1\n");
    assert_eq!(ev.len(), 2);
    let E::Reply(r) = &ev[0] else { panic!() };
    assert_eq!(r.lines, vec!["%output %1 not an event", "%end 5 8 1"]);
    assert_eq!(r.token, Some(1));
    assert_eq!(
        ev[1],
        E::WindowAdd {
            window: WindowId(1)
        }
    );
}

#[test]
fn reply_without_registered_token_has_none() {
    let ev = parse("%begin 1 2 1\n%end 1 2 1\n");
    let E::Reply(r) = &ev[0] else { panic!() };
    assert_eq!(r.token, None);
}

#[test]
fn window_and_session_notifications() {
    let got = parse(
        "%window-add @2\n%window-close @2\n%unlinked-window-add @3\n%unlinked-window-close @3\n\
         %window-renamed @1 my window  name\n%unlinked-window-renamed @3 tmux\n\
         %window-pane-changed @2 %5\n%session-changed $0 main\n%session-renamed $1 new name\n\
         %session-renamed oldstyle\n%sessions-changed\n%session-window-changed $0 @3\n\
         %pane-mode-changed %4\n%client-session-changed /dev/pts/3 $2 other\n\
         %client-detached /dev/pts/3\n%pause %7\n%continue %7\n",
    );
    assert_eq!(
        got,
        vec![
            E::WindowAdd {
                window: WindowId(2)
            },
            E::WindowClose {
                window: WindowId(2)
            },
            E::UnlinkedWindowAdd {
                window: WindowId(3)
            },
            E::UnlinkedWindowClose {
                window: WindowId(3)
            },
            E::WindowRenamed {
                window: WindowId(1),
                name: "my window  name".into()
            },
            E::UnlinkedWindowRenamed {
                window: WindowId(3),
                name: "tmux".into()
            },
            E::WindowPaneChanged {
                window: WindowId(2),
                pane: PaneId(5)
            },
            E::SessionChanged {
                session: SessionId(0),
                name: "main".into()
            },
            E::SessionRenamed {
                session: Some(SessionId(1)),
                name: "new name".into()
            },
            E::SessionRenamed {
                session: None,
                name: "oldstyle".into()
            },
            E::SessionsChanged,
            E::SessionWindowChanged {
                session: SessionId(0),
                window: WindowId(3)
            },
            E::PaneModeChanged { pane: PaneId(4) },
            E::ClientSessionChanged {
                client: "/dev/pts/3".into(),
                session: SessionId(2),
                name: "other".into()
            },
            E::ClientDetached {
                client: "/dev/pts/3".into()
            },
            E::Pause { pane: PaneId(7) },
            E::Continue { pane: PaneId(7) },
        ]
    );
}

/// tmux prints names in notifications with its output sanitising (`\\`, `\ooo`, `\n`);
/// verified against tmux 3.6 `%window-renamed` after `rename-window 'a\b'`.
#[test]
fn names_in_notifications_are_unescaped() {
    assert_eq!(
        parse("%window-renamed @1 a\\\\b\\037c\\nd\n"),
        vec![E::WindowRenamed {
            window: WindowId(1),
            name: "a\\b\u{1f}c\nd".into()
        }]
    );
    assert_eq!(
        parse("%session-changed $0 x\\\\y\n%session-renamed $1 p\\\\q\n"),
        vec![
            E::SessionChanged {
                session: SessionId(0),
                name: "x\\y".into()
            },
            E::SessionRenamed {
                session: Some(SessionId(1)),
                name: "p\\q".into()
            },
        ]
    );
}

#[test]
fn layout_change_parses_layout() {
    let ev = parse(
        "%layout-change @2 f926,120x40,0,0{60x40,0,0,2,59x40,61,0,3} f926,120x40,0,0{60x40,0,0,2,59x40,61,0,3} *\n",
    );
    let E::LayoutChange {
        window,
        layout,
        visible_layout,
        flags,
        parsed,
    } = &ev[0]
    else {
        panic!()
    };
    assert_eq!(*window, WindowId(2));
    assert_eq!(layout, "f926,120x40,0,0{60x40,0,0,2,59x40,61,0,3}");
    assert_eq!(visible_layout.as_deref(), Some(layout.as_str()));
    assert_eq!(flags.as_deref(), Some("*"));
    assert_eq!(parsed.as_ref().unwrap().pane_ids(), [PaneId(2), PaneId(3)]);
    // old style: only the layout
    let ev = parse("%layout-change @1 a87d,100x30,0,0,0\n");
    let E::LayoutChange {
        visible_layout,
        flags,
        parsed,
        ..
    } = &ev[0]
    else {
        panic!()
    };
    assert!(visible_layout.is_none() && flags.is_none() && parsed.is_some());
    // unparsable layout keeps the raw string
    let ev = parse("%layout-change @1 {json:true} {json:true} *\n");
    let E::LayoutChange { layout, parsed, .. } = &ev[0] else {
        panic!()
    };
    assert_eq!(layout, "{json:true}");
    assert!(parsed.is_none());
}

#[test]
fn subscription_changed() {
    assert_eq!(
        parse("%subscription-changed mysub $1 @2 3 %4 : hello : world\n"),
        vec![E::SubscriptionChanged {
            name: "mysub".into(),
            session: Some(SessionId(1)),
            window: Some(WindowId(2)),
            window_index: Some(3),
            pane: Some(PaneId(4)),
            value: "hello : world".into(),
        }]
    );
    assert_eq!(
        parse("%subscription-changed s $1 - - - : v\n"),
        vec![E::SubscriptionChanged {
            name: "s".into(),
            session: Some(SessionId(1)),
            window: None,
            window_index: None,
            pane: None,
            value: "v".into(),
        }]
    );
}

#[test]
fn exit_with_and_without_reason() {
    assert_eq!(parse("%exit\n"), vec![E::Exit { reason: None }]);
    assert_eq!(
        parse("%exit server exited unexpectedly\n"),
        vec![E::Exit {
            reason: Some("server exited unexpectedly".into())
        }]
    );
}

#[test]
fn unknown_lines_are_forwarded() {
    assert_eq!(
        parse("%future-thing 1 2\nrandom text\n%window-add bogus\n"),
        vec![
            E::Unknown("%future-thing 1 2".into()),
            E::Unknown("random text".into()),
            E::Unknown("%window-add bogus".into()),
        ]
    );
    // empty lines are ignored
    assert!(parse("\n\n").is_empty());
}

#[test]
fn dcs_wrapper_for_cc_mode() {
    let mut p = ControlParser::new();
    let ev = p.push(b"\x1bP1000p%begin 1 2 0\n%end 1 2 0\n%sessions-changed\n%exit\n\x1b\\");
    assert_eq!(ev.len(), 3);
    assert!(matches!(ev[0], E::Reply(_)));
    assert_eq!(ev[1], E::SessionsChanged);
    assert_eq!(ev[2], E::Exit { reason: None });
    // DCS split over chunks, and the terminator arriving alone
    let mut p = ControlParser::new();
    assert!(p.push(b"\x1bP10").is_empty());
    assert_eq!(p.push(b"00p%sessions-changed\n"), vec![E::SessionsChanged]);
    assert!(p.push(b"\x1b\\").is_empty());
    assert_eq!(p.push(b"%sessions-changed\n"), vec![E::SessionsChanged]);
}
