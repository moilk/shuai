use shuai_tmux::cmd::{self, Target};
use shuai_tmux::controller::{ControllerEvent as E, TmuxController};
use shuai_tmux::{PaneId, TmuxVersion, WindowId};

fn v(s: &str) -> TmuxVersion {
    TmuxVersion::parse(s).unwrap()
}

#[test]
fn display_message_builder() {
    assert_eq!(
        cmd::display_message(None, "#{session_name}").argv(),
        ["display-message", "-p", "--", "#{session_name}"]
    );
    assert_eq!(
        cmd::display_message(Some(&Target::pane(PaneId(3))), "#{pane_id}").argv(),
        ["display-message", "-p", "-t", "%3", "--", "#{pane_id}"]
    );
}

#[test]
fn subscription_and_pause_builders() {
    assert_eq!(
        cmd::refresh_client_subscribe("cwd", "%*", "#{pane_current_path}")
            .unwrap()
            .argv(),
        ["refresh-client", "-B", "cwd:%*:#{pane_current_path}"]
    );
    assert!(cmd::refresh_client_subscribe("a:b", "%*", "x").is_err());
    assert!(cmd::refresh_client_subscribe("", "%*", "x").is_err());
    assert_eq!(
        cmd::refresh_client_unsubscribe("cwd").unwrap().argv(),
        ["refresh-client", "-B", "cwd"]
    );
    assert_eq!(
        cmd::refresh_client_pause_after(5).argv(),
        ["refresh-client", "-f", "pause-after=5"]
    );
    assert_eq!(
        cmd::continue_pane(PaneId(2)).argv(),
        ["refresh-client", "-A", "%2:continue"]
    );
}

#[test]
fn attach_command_and_setup_lines() {
    let mut c = TmuxController::new("my proj", v("tmux 3.6a"));
    assert_eq!(
        c.attach_command().argv(),
        ["-C", "attach-session", "-t", "=my proj:"]
    );
    let lines = c.on_connected();
    assert_eq!(lines, vec!["refresh-client -f no-output".to_string()]);
    let c2 = &mut TmuxController::new("s", v("tmux 2.9"));
    assert!(c2.on_connected().is_empty());
}

#[test]
fn old_tmux_without_no_output_discards_output() {
    let mut c = TmuxController::new("s", v("tmux 2.9"));
    c.on_connected();
    assert!(c.push(b"%output %1 hello\n").is_empty());
}

#[test]
fn notifications_become_one_refresh_per_chunk() {
    let mut c = TmuxController::new("s", v("tmux 3.6"));
    c.on_connected();
    // attach reply (server-originated) + setup reply
    let ev = c.push(b"%begin 1 1 0\n%end 1 1 0\n%begin 2 2 1\n%end 2 2 1\n");
    assert!(ev.is_empty(), "{ev:?}");
    let ev = c.push(
        b"%window-add @4\n%layout-change @4 abcd,1x1,0,0,1 abcd,1x1,0,0,1 *\n%sessions-changed\n\
          %output %1 x\n%window-pane-changed @4 %1\n",
    );
    assert_eq!(ev, vec![E::NeedsRefresh]);
    // split across chunks still works
    assert!(c.push(b"%window-").is_empty());
    assert_eq!(c.push(b"close @4\n"), vec![E::NeedsRefresh]);
}

#[test]
fn renames_are_direct_patches() {
    let mut c = TmuxController::new("s", v("tmux 3.6"));
    let ev = c.push(b"%window-renamed @1 a\\134b\n%session-renamed $2 new\n%session-renamed old\n");
    assert_eq!(
        ev,
        vec![
            E::WindowRenamed {
                window: WindowId(1),
                name: "a\\b".into()
            },
            E::SessionRenamed {
                session: shuai_tmux::SessionId(2),
                name: "new".into()
            },
            E::NeedsRefresh,
        ]
    );
}

#[test]
fn user_replies_carry_token_and_exit_is_reported() {
    let mut c = TmuxController::new("s", v("tmux 3.6"));
    c.on_connected();
    let (tok, line) = c.send(&cmd::list_panes_all());
    assert!(line.starts_with("list-panes -a -F"));
    let ev =
        c.push(b"%begin 1 1 1\n%end 1 1 1\n%begin 3 3 1\nrow\n%end 3 3 1\n%exit server exited\n");
    assert_eq!(ev.len(), 2, "{ev:?}");
    match &ev[0] {
        E::Reply(r) => {
            assert_eq!(r.token, Some(tok));
            assert_eq!(r.lines, vec!["row"]);
        }
        e => panic!("{e:?}"),
    }
    assert_eq!(ev[1], E::Exited(Some("server exited".into())));
}

#[test]
fn rename_patch_applies_to_every_linked_copy() {
    use shuai_tmux::parse::parse_topology;
    let row = |s: u32, w: u32, name: &str| {
        format!(
            "${s}\u{1f}s{s}\u{1f}1\u{1f}@{w}\u{1f}0\u{1f}{name}\u{1f}1\u{1f}*\u{1f}%{w}\u{1f}0\u{1f}1\u{1f}zsh\u{1f}/\u{1f}1\u{1f}/dev/x\u{1f}t\u{1f}80\u{1f}24\n"
        )
    };
    let mut t = parse_topology(&format!("{}{}", row(0, 7, "x"), row(1, 7, "x"))).unwrap();
    assert_eq!(t.rename_window(WindowId(7), "y"), 2);
    assert!(t.sessions.iter().all(|s| s.windows[0].name == "y"));
    assert_eq!(t.rename_session(shuai_tmux::SessionId(1), "z"), 1);
    assert_eq!(t.sessions[1].name, "z");
}
