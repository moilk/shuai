use shuai_tmux::version::suppress_output_commands;
use shuai_tmux::{Capabilities, PaneId, SessionId, TmuxVersion, WindowId};

fn v(s: &str) -> TmuxVersion {
    TmuxVersion::parse(s).unwrap_or_else(|| panic!("parse {s}"))
}

#[test]
fn ids_display_and_parse() {
    assert_eq!(SessionId(0).to_string(), "$0");
    assert_eq!(WindowId(12).to_string(), "@12");
    assert_eq!(PaneId(3).to_string(), "%3");
    assert_eq!("@12".parse::<WindowId>().unwrap(), WindowId(12));
    assert_eq!("%0".parse::<PaneId>().unwrap(), PaneId(0));
    assert!("@x".parse::<WindowId>().is_err());
    assert!("%1".parse::<WindowId>().is_err());
    assert!("".parse::<PaneId>().is_err());
}

#[test]
fn parse_versions() {
    let a = v("tmux 3.6\n");
    assert_eq!(
        (a.major, a.minor, a.patch, a.next, a.master),
        (3, 6, None, false, false)
    );
    assert_eq!(v("tmux 3.3a").patch, Some('a'));
    assert_eq!(v("tmux 3.6a").patch, Some('a'));
    assert_eq!(v("tmux 2.9a").minor, 9);
    let n = v("tmux next-3.7");
    assert_eq!((n.major, n.minor, n.next), (3, 7, true));
    assert!(v("tmux master").master);
    assert_eq!(v("3.2"), v("tmux 3.2"));
    assert_eq!(TmuxVersion::parse("garbage"), None);
    assert_eq!(TmuxVersion::parse(""), None);
    assert_eq!(TmuxVersion::parse("tmux 3"), None);
}

#[test]
fn ordering() {
    assert!(v("tmux 3.3a") > v("tmux 3.3"));
    assert!(v("tmux 3.10") > v("tmux 3.9"));
    assert!(v("tmux master") > v("tmux 3.8"));
    assert!(v("tmux next-3.7") < v("tmux 3.7"));
    assert!(v("tmux next-3.7") > v("tmux 3.6a"));
    assert!(v("tmux next-3.7").at_least(3, 7));
    assert!(v("tmux 3.3a").at_least(3, 3));
    assert!(!v("tmux 3.3a").at_least(3, 4));
}

#[test]
fn capability_table() {
    let c36 = Capabilities::for_version(&v("tmux 3.6"));
    assert!(c36.control_mode && c36.no_output && c36.client_flags_lowercase_f);
    assert!(c36.pause_after && c36.subscriptions && c36.format_quote);
    let c31 = Capabilities::for_version(&v("tmux 3.1c"));
    assert!(c31.no_output && c31.format_quote && c31.extended_notifications);
    assert!(!c31.client_flags_lowercase_f && !c31.pause_after && !c31.subscriptions);
    let c29 = Capabilities::for_version(&v("tmux 2.9a"));
    assert!(c29.control_mode && !c29.no_output && c29.format_quote);
    let c17 = Capabilities::for_version(&v("tmux 1.7"));
    assert!(!c17.control_mode);
    assert!(Capabilities::for_version(&v("tmux master")).pause_after);
}

#[test]
fn suppress_output_sequences() {
    let cmds = suppress_output_commands(&v("tmux 3.6a"));
    assert_eq!(cmds.len(), 1);
    assert_eq!(cmds[0].argv(), ["refresh-client", "-f", "no-output"]);
    let old = suppress_output_commands(&v("tmux 3.1"));
    assert_eq!(old[0].argv(), ["refresh-client", "-F", "no-output"]);
    assert!(suppress_output_commands(&v("tmux 2.9")).is_empty());
}
