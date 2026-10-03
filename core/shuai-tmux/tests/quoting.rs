//! Adversarial quoting tests: shell round-trip and (ignored) real-tmux round-trip.

use proptest::prelude::*;
use proptest::strategy::ValueTree;
use shuai_tmux::cmd::{self, Target};
use shuai_tmux::parse::unescape_output;
use shuai_tmux::{SessionId, TmuxCommand};
use std::io::Write;
use std::process::{Command, Stdio};

fn nasty() -> impl Strategy<Value = String> {
    let atoms = prop::sample::select(vec![
        "'",
        "\"",
        ";",
        "#",
        "$",
        "\\",
        "\n",
        "\t",
        "-",
        "--",
        "%",
        "~",
        "{",
        "}",
        " ",
        "`",
        "$(x)",
        "#{x}",
        "##",
        "=",
        ":",
        ".",
        "日本語",
        "é",
        "😀",
        "\u{7f}",
        "\u{1}",
        "\r",
        "a",
        "-n",
    ]);
    prop::collection::vec(prop_oneof![atoms.prop_map(String::from), "\\PC{0,3}"], 0..8)
        .prop_map(|v| v.concat().replace('\0', ""))
}

fn shell_argv(c: &TmuxCommand) -> Vec<String> {
    let line = c.to_shell();
    let rest = line.strip_prefix("tmux").unwrap();
    let out = Command::new("sh")
        .arg("-c")
        .arg(format!("printf '%s\\0' {rest}"))
        .output()
        .unwrap();
    assert!(out.status.success(), "sh failed for {line:?}");
    let mut parts: Vec<&[u8]> = out.stdout.split(|&b| b == 0).collect();
    assert_eq!(parts.pop(), Some(&b""[..]));
    parts
        .into_iter()
        .map(|p| String::from_utf8(p.to_vec()).unwrap())
        .collect()
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(300))]
    #[test]
    fn shell_roundtrip(name in nasty(), cwd in nasty()) {
        let cmds = [
            cmd::new_window(&Target::session("s"), Some(&cwd), Some(&name)),
            cmd::rename_window(&Target::session_id(SessionId(1)), &name),
            cmd::send_keys_literal(&Target::session("s"), &name),
        ];
        for c in &cmds {
            prop_assert_eq!(shell_argv(c), c.argv().to_vec());
        }
    }
}

#[test]
fn leading_tilde_and_dash_are_neutralised() {
    use shuai_tmux::quote::tmux_quote;
    assert_eq!(tmux_quote("~"), "\"\\~\"");
    assert_eq!(tmux_quote("a~"), "\"a~\"");
    let c = cmd::rename_window(&Target::session("s"), "-x");
    assert_eq!(c.argv(), ["rename-window", "-t", "=s:", "--", "-x"]);
}

const SOCK: &str = "shuairev";

fn tmux(args: &[&str]) -> std::process::Output {
    Command::new("tmux")
        .args(["-L", SOCK, "-f", "/dev/null"])
        .args(args)
        .output()
        .unwrap()
}

struct Kill;
impl Drop for Kill {
    fn drop(&mut self) {
        let _ = tmux(&["kill-server"]);
    }
}

fn fresh_server() {
    let _ = tmux(&["kill-server"]);
    assert!(tmux(&["new-session", "-d", "-s", "base"]).status.success());
    tmux(&["set", "-g", "automatic-rename", "off"]);
}

/// Feed lines to a `tmux -C` client's stdin and wait for it to exit.
fn run_control(lines: &[String]) {
    let mut child = Command::new("tmux")
        .args([
            "-L",
            SOCK,
            "-f",
            "/dev/null",
            "-C",
            "attach-session",
            "-t",
            "base",
        ])
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    {
        let mut i = child.stdin.take().unwrap();
        for l in lines {
            assert!(!l.contains('\n'), "control line has raw newline: {l:?}");
            writeln!(i, "{l}").unwrap();
        }
    }
    child.wait().unwrap();
}

fn window_names() -> Vec<String> {
    let o = tmux(&["list-windows", "-t", "base", "-F", "#{window_name}\u{1f}"]);
    String::from_utf8(o.stdout)
        .unwrap()
        .split("\u{1f}\n")
        .map(unescape_output)
        .collect()
}

#[test]
#[ignore = "needs a local tmux"]
fn control_line_names_roundtrip_real_tmux() {
    let _k = Kill;
    let mut names: Vec<String> = [
        "日本語窓",
        "it's",
        "a\"b",
        "semi;colon",
        "hash#tag",
        "#{pane_id}",
        "##",
        "$HOME",
        "$(id)",
        "back\\slash",
        "tab\there",
        "-leading",
        "--",
        "-n",
        "multi\nline",
        "cr\rx",
        "\u{1}ctl",
        "😀",
        "%1",
        "~",
        "a b  c",
        "{x}",
        "ends\\",
        "x;kill-server",
        "a\\nb",
    ]
    .iter()
    .map(|s| s.to_string())
    .collect();
    let mut runner = proptest::test_runner::TestRunner::deterministic();
    for _ in 0..40 {
        names.push(nasty().new_tree(&mut runner).unwrap().current());
    }
    for name in names {
        if name.is_empty() {
            continue;
        }
        let builders: [(&str, TmuxCommand); 2] = [
            (
                "new-window -n",
                cmd::new_window(&Target::session("base"), None, Some(&name)),
            ),
            (
                "rename-window",
                cmd::rename_window(&Target::session("base"), &name),
            ),
        ];
        for (label, c) in builders {
            // tmux quirk (3.6): `new-window -n` stores the name unsanitised, so listing a
            // name with a backslash is ambiguous (`a\nb` lists as `a\nb`, but rename-window
            // lists `a\\nb`). Not a quoting bug; skip that combination.
            if label == "new-window -n" && name.contains('\\') {
                continue;
            }
            fresh_server();
            run_control(&[c.to_control_line()]);
            let got = window_names();
            assert!(
                got.iter().any(|g| g == &name),
                "{label}: name {name:?} line {:?} -> {got:?}",
                c.to_control_line()
            );
        }
    }
}
