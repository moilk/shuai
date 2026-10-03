//! M4: zoom/next/prev/last/switch-client builders and PTY-client selection.

use shuai_tmux::clients::{ClientParseError, TmuxClient, parse_clients, pick_pty_client};
use shuai_tmux::cmd::{self, FIELD_SEP, Target};
use shuai_tmux::{PaneId, SessionId};

fn us(fields: &[&str]) -> String {
    fields.join(&FIELD_SEP.to_string())
}

#[test]
fn zoom_pane_is_resize_pane_z() {
    let c = cmd::zoom_pane(&Target::pane(PaneId(3)));
    assert_eq!(c.argv(), ["resize-pane", "-Z", "-t", "%3"]);
}

#[test]
fn select_pane_direction_uses_the_flag_letters() {
    use shuai_tmux::cmd::PaneDirection::*;
    let t = Target::window(shuai_tmux::WindowId(1));
    for (d, f) in [(Left, "-L"), (Right, "-R"), (Up, "-U"), (Down, "-D")] {
        assert_eq!(
            cmd::select_pane_direction(&t, d).argv(),
            ["select-pane", f, "-t", "@1"]
        );
    }
}

#[test]
fn window_navigation_targets_the_exact_session() {
    let s = Target::session("my proj");
    assert_eq!(
        cmd::next_window(&s).argv(),
        ["next-window", "-t", "=my proj:"]
    );
    assert_eq!(
        cmd::previous_window(&s).argv(),
        ["previous-window", "-t", "=my proj:"]
    );
    assert_eq!(
        cmd::last_window(&s).argv(),
        ["last-window", "-t", "=my proj:"]
    );
}

#[test]
fn switch_client_targets_the_given_client_tty_not_the_caller() {
    let c = cmd::switch_client("/dev/ttys004", &Target::session_id(SessionId(2)));
    assert_eq!(
        c.argv(),
        ["switch-client", "-c", "/dev/ttys004", "-t", "$2"]
    );
    // a tty containing odd characters stays one argument in every rendering
    let c = cmd::switch_client("/dev/pts/1 x", &Target::session("a"));
    assert_eq!(
        c.to_shell(),
        "tmux switch-client -c '/dev/pts/1 x' -t '=a:'"
    );
}

#[test]
fn list_clients_format_uses_unit_separator() {
    let c = cmd::list_clients();
    assert_eq!(c.argv()[0], "list-clients");
    assert_eq!(c.argv()[1], "-F");
    assert!(c.argv()[2].contains(FIELD_SEP));
    assert!(c.argv()[2].contains("#{client_control_mode}"));
}

fn row(tty: &str, pid: &str, session: &str, ctl: &str, created: &str, w: &str, h: &str) -> String {
    us(&[tty, pid, "$0", session, ctl, created, w, h])
}

#[test]
fn parse_clients_reads_rows() {
    let text = format!(
        "{}\n{}\n",
        row("/dev/ttys002", "100", "main", "0", "1000", "120", "40"),
        row("/dev/ttys003", "101", "main", "1", "1002", "80", "24"),
    );
    let cs = parse_clients(&text).unwrap();
    assert_eq!(cs.len(), 2);
    assert_eq!(
        cs[0],
        TmuxClient {
            tty: "/dev/ttys002".into(),
            pid: 100,
            session_id: SessionId(0),
            session_name: "main".into(),
            control_mode: false,
            created: 1000,
            width: 120,
            height: 40
        }
    );
    assert!(cs[1].control_mode);
}

#[test]
fn parse_clients_rejects_bad_rows_and_ignores_blank_lines() {
    assert!(matches!(
        parse_clients("a\u{1f}b\n"),
        Err(ClientParseError::FieldCount { line: 1, .. })
    ));
    let bad = row("/dev/x", "nope", "m", "0", "1", "1", "1");
    assert!(matches!(
        parse_clients(&bad),
        Err(ClientParseError::BadField { line: 1, .. })
    ));
    assert_eq!(parse_clients("\n\n").unwrap(), vec![]);
}

fn client(
    tty: &str,
    pid: u32,
    session: &str,
    ctl: bool,
    created: u64,
    w: u32,
    h: u32,
) -> TmuxClient {
    TmuxClient {
        tty: tty.into(),
        pid,
        session_id: SessionId(0),
        session_name: session.into(),
        control_mode: ctl,
        created,
        width: w,
        height: h,
    }
}

#[test]
fn pty_client_is_the_only_non_control_client_of_our_session() {
    let cs = vec![
        client("/dev/ttys002", 100, "main", false, 1000, 120, 40),
        client("/dev/ttys003", 101, "main", true, 1001, 80, 24),
    ];
    assert_eq!(
        pick_pty_client(&cs, "main", Some(101), None).as_deref(),
        Some("/dev/ttys002")
    );
}

#[test]
fn control_clients_and_other_sessions_are_never_picked() {
    let cs = vec![
        client("/dev/ttys003", 101, "main", true, 1001, 80, 24),
        client("/dev/ttys009", 200, "other", false, 900, 80, 24),
    ];
    assert_eq!(pick_pty_client(&cs, "main", Some(101), None), None);
}

#[test]
fn several_candidates_prefer_the_one_created_just_before_our_control_client() {
    let cs = vec![
        client("/dev/ttys010", 90, "main", false, 500, 120, 40),
        client("/dev/ttys002", 100, "main", false, 1000, 120, 40),
        client("/dev/ttys011", 110, "main", false, 1500, 120, 40),
        client("/dev/ttys003", 101, "main", true, 1001, 80, 24),
    ];
    assert_eq!(
        pick_pty_client(&cs, "main", Some(101), None).as_deref(),
        Some("/dev/ttys002")
    );
}

#[test]
fn matching_terminal_size_beats_recency() {
    let cs = vec![
        client("/dev/ttys010", 90, "main", false, 999, 100, 30),
        client("/dev/ttys002", 100, "main", false, 995, 120, 40),
        client("/dev/ttys003", 101, "main", true, 1001, 80, 24),
    ];
    assert_eq!(
        pick_pty_client(&cs, "main", Some(101), Some((120, 40))).as_deref(),
        Some("/dev/ttys002")
    );
    assert_eq!(
        pick_pty_client(&cs, "main", Some(101), None).as_deref(),
        Some("/dev/ttys010")
    );
}

#[test]
fn without_a_known_control_client_the_latest_candidate_wins() {
    let cs = vec![
        client("/dev/ttys010", 90, "main", false, 500, 120, 40),
        client("/dev/ttys002", 100, "main", false, 1000, 120, 40),
    ];
    assert_eq!(
        pick_pty_client(&cs, "main", None, None).as_deref(),
        Some("/dev/ttys002")
    );
}

#[test]
fn parse_clients_treats_empty_size_fields_as_zero() {
    // seen on tmux 3.6: a control client may report empty sizes
    let cs = parse_clients(&row("", "7", "main", "1", "5", "80", "")).unwrap();
    assert_eq!((cs[0].width, cs[0].height), (80, 0));
    let cs = parse_clients(&row("", "7", "main", "1", "5", "", "")).unwrap();
    assert_eq!((cs[0].width, cs[0].height), (0, 0));
}

#[test]
fn a_client_that_already_switched_away_is_found_by_the_any_session_variant() {
    let cs = vec![
        client("/dev/ttys002", 100, "other", false, 1000, 120, 40),
        client("/dev/ttys003", 101, "main", true, 1001, 80, 24),
    ];
    assert_eq!(pick_pty_client(&cs, "main", Some(101), None), None);
    assert_eq!(
        shuai_tmux::clients::pick_pty_client_any_session(&cs, Some(101), Some((120, 40)))
            .as_deref(),
        Some("/dev/ttys002")
    );
}
