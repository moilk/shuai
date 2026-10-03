use shuai_ffi::*;

const US: char = '\u{1f}';

fn pane_line(s: &str, w: &str, p: &str) -> String {
    [
        "$0",
        s,
        "1",
        w,
        "0",
        "zsh",
        "1",
        "*",
        p,
        "0",
        "1",
        "claude",
        "/home/u",
        "123",
        "/dev/pts/1",
        "title",
        "80",
        "24",
    ]
    .join(&US.to_string())
}

#[test]
fn parse_topology_flattens_to_records_with_string_ids() {
    let text = format!(
        "{}\n{}\n",
        pane_line("main", "@1", "%1"),
        pane_line("main", "@1", "%2")
    );
    let t = parse_topology(text).unwrap();
    assert_eq!(t.sessions.len(), 1);
    let s = &t.sessions[0];
    assert_eq!(
        (s.id.as_str(), s.name.as_str(), s.attached),
        ("$0", "main", 1)
    );
    assert_eq!(s.windows.len(), 1);
    let w = &s.windows[0];
    assert_eq!(
        (w.id.as_str(), w.name.as_str(), w.active),
        ("@1", "zsh", true)
    );
    assert_eq!(
        w.panes.iter().map(|p| p.id.as_str()).collect::<Vec<_>>(),
        ["%1", "%2"]
    );
    assert_eq!(w.panes[0].current_command, "claude");
    assert_eq!((w.panes[0].width, w.panes[0].height), (80, 24));
}

#[test]
fn parse_topology_error_is_reported() {
    assert!(matches!(
        parse_topology("a\u{1f}b\n".into()).unwrap_err(),
        FfiTmuxError::Parse { .. }
    ));
}

#[test]
fn builders_produce_all_three_forms() {
    let c = tmux_select_window("@3".into()).unwrap();
    assert_eq!(c.argv, vec!["select-window", "-t", "@3"]);
    assert_eq!(c.shell, "tmux select-window -t @3");
    assert_eq!(c.control_line, "select-window -t @3");
    let c = tmux_rename_window("@3".into(), "my win".into()).unwrap();
    assert!(c.shell.contains("'my win'"));
    assert!(c.control_line.contains("\"my win\""));
    let c = tmux_send_keys_literal("%2".into(), "a b".into()).unwrap();
    assert_eq!(&c.argv[..4], ["send-keys", "-t", "%2", "-l"]);
    assert_eq!(tmux_list_panes_all().argv[0], "list-panes");
    assert_eq!(
        tmux_kill_window("@1".into()).unwrap().argv[0],
        "kill-window"
    );
    assert_eq!(
        tmux_new_window("main".into(), None, Some("x".into())).argv[0],
        "new-window"
    );
    let c = tmux_split_window("%1".into(), true, None).unwrap();
    assert!(c.argv.contains(&"-h".to_string()));
    let c = tmux_new_session_attach(
        "dev".into(),
        Some(FfiSize {
            cols: 100,
            rows: 30,
        }),
        None,
    );
    assert_eq!(&c.argv[..4], ["new-session", "-A", "-s", "dev"]);
}

#[test]
fn builders_reject_malformed_ids() {
    assert!(matches!(
        tmux_select_window("3".into()),
        Err(FfiTmuxError::InvalidId { .. })
    ));
    assert!(matches!(
        tmux_kill_window("%3".into()),
        Err(FfiTmuxError::InvalidId { .. })
    ));
    assert!(matches!(
        tmux_send_keys_literal("@3".into(), "x".into()),
        Err(FfiTmuxError::InvalidId { .. })
    ));
}

#[test]
fn controller_attach_send_push() {
    let c = TmuxController::new("main".into(), "tmux 3.4".into()).unwrap();
    let a = c.attach_command();
    assert_eq!(a.argv[0], "-C");
    assert!(a.shell.starts_with("tmux -C attach-session"));
    let setup = c.on_connected();
    assert!(!setup.is_empty()); // 3.4 supports no-output
    let sent = c.send(tmux_list_panes_all());
    assert!(sent.line.starts_with("list-panes"));
    // Replies to the internal setup commands are swallowed; ours comes back.
    let mut input = String::new();
    for i in 0..setup.len() {
        input.push_str(&format!("%begin 1 {i} 1\n%end 1 {i} 1\n"));
    }
    input.push_str("%begin 2 9 1\nx\n%end 2 9 1\n");
    let evs = c.push(input.into_bytes());
    assert!(
        evs.iter()
            .any(|e| matches!(e, FfiControllerEvent::Reply { ok: true, .. })),
        "{evs:?}"
    );
    let evs = c.push(b"%window-add @5\n".to_vec());
    assert_eq!(evs, vec![FfiControllerEvent::NeedsRefresh]);
    let evs = c.push(b"%window-renamed @5 hi\n".to_vec());
    assert_eq!(
        evs,
        vec![FfiControllerEvent::WindowRenamed {
            window_id: "@5".into(),
            name: "hi".into()
        }]
    );
    let evs = c.push(b"%exit\n".to_vec());
    assert_eq!(evs, vec![FfiControllerEvent::Exited { reason: None }]);
}

#[test]
fn controller_rejects_unparseable_version() {
    assert!(TmuxController::new("m".into(), "wat".into()).is_err());
}
