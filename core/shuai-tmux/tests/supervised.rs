//! The supervised control-client command line must not leave a `tmux -C` process behind when its
//! SSH channel goes away. Background: a no-PTY exec channel gets no SIGHUP, and a tmux control
//! client whose stdout reader is gone (EPIPE on its first write) ignores both stdin EOF and the
//! destruction of its session, so it lives forever (reproduced on tmux 3.6). The supervised line
//! keeps draining stdout so that stdin EOF always ends the client.
//!
//! The real-tmux tests use private sockets and are skipped when tmux is missing.

use std::io::{Read, Write};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

use shuai_tmux::{TmuxCommand, cmd};

#[test]
fn supervised_line_is_posix_sh_with_quoted_argv() {
    let line = cmd::control_attach("my 'proj'", false).to_supervised_shell();
    assert!(line.starts_with("sh -c '"), "{line}");
    // The tmux arguments travel as positional parameters, each quoted for the login shell.
    assert!(
        line.ends_with(" sh -C attach-session -t '=my '\\''proj'\\'':'"),
        "{line}"
    );
    // Valid in every login shell: no unquoted shell metacharacters outside the single quotes.
    let script_end = line.rfind("' sh -C").expect("script terminator");
    assert!(!line[..script_end].contains("\\'"), "{line}");
}

#[test]
fn supervised_script_has_no_single_quotes() {
    // The script is wrapped in single quotes verbatim; a stray one would break out of them.
    let line = cmd::control_attach("s", false).to_supervised_shell();
    let body = line
        .strip_prefix("sh -c '")
        .and_then(|r| r.split_once("' sh "))
        .map(|(b, _)| b)
        .unwrap();
    assert!(!body.contains('\''), "{body}");
}

fn tmux_bin() -> Option<String> {
    if let Ok(p) = std::env::var("SHUAI_TMUX_BIN") {
        return Some(p);
    }
    [
        "/opt/homebrew/bin/tmux",
        "/usr/local/bin/tmux",
        "/usr/bin/tmux",
    ]
    .iter()
    .find(|p| std::path::Path::new(p).exists())
    .map(|s| s.to_string())
}

struct Env {
    bin: String,
    socket: String,
}

impl Env {
    fn new(bin: String, tag: &str) -> Self {
        let e = Env {
            bin,
            socket: format!("shuaisup-{tag}-{}", std::process::id()),
        };
        for s in ["x", "y"] {
            let out = e
                .tmux()
                .args(["new-session", "-d", "-s", s, "-x", "80", "-y", "24", "sleep 600"])
                .output()
                .unwrap();
            assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
        }
        e
    }
    fn tmux(&self) -> Command {
        let mut c = Command::new(&self.bin);
        c.env_remove("TMUX")
            .env("TERM", "xterm-256color")
            .args(["-L", &self.socket, "-f", "/dev/null"]);
        c
    }
    /// The supervised attach line, run through `sh -c` like sshd does, with piped stdio.
    fn spawn_attach(&self, session: &str) -> Child {
        let argv: Vec<String> = ["-L", &self.socket, "-f", "/dev/null"]
            .iter()
            .map(|s| s.to_string())
            .chain(cmd::control_attach(session, false).argv().iter().cloned())
            .collect();
        let line = TmuxCommand::from_argv(argv).to_supervised_shell();
        let dir = std::path::Path::new(&self.bin).parent().unwrap();
        let path = format!(
            "{}:{}",
            dir.display(),
            std::env::var("PATH").unwrap_or_default()
        );
        Command::new("sh")
            .args(["-c", &line])
            .env("PATH", path)
            .env("TERM", "xterm-256color")
            .env_remove("TMUX")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap()
    }
}

impl Drop for Env {
    fn drop(&mut self) {
        let _ = self.tmux().arg("kill-server").output();
    }
}

fn wait_exit(child: &mut Child, within: Duration) -> Option<std::process::ExitStatus> {
    let deadline = Instant::now() + within;
    while Instant::now() < deadline {
        if let Some(s) = child.try_wait().unwrap() {
            return Some(s);
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    None
}

fn attached(env: &Env) -> bool {
    let out = env.tmux().args(["list-clients"]).output().unwrap();
    !out.stdout.is_empty()
}

fn wait_attached(env: &Env) {
    let deadline = Instant::now() + Duration::from_secs(5);
    while !attached(env) {
        assert!(Instant::now() < deadline, "control client never attached");
        std::thread::sleep(Duration::from_millis(50));
    }
}

fn cleanup(mut child: Child) {
    let _ = child.kill();
    let _ = child.wait();
}

#[test]
fn passes_notifications_through_and_ends_on_stdin_eof() {
    let Some(bin) = tmux_bin() else { return };
    let env = Env::new(bin, "pass");
    let mut child = env.spawn_attach("x");
    let mut stdin = child.stdin.take().unwrap();
    let mut stdout = child.stdout.take().unwrap();
    wait_attached(&env);
    writeln!(stdin, "list-sessions").unwrap();
    stdin.flush().unwrap();
    let mut seen = String::new();
    let mut buf = [0u8; 4096];
    let deadline = Instant::now() + Duration::from_secs(5);
    while !seen.contains("%end") {
        assert!(Instant::now() < deadline, "no reply: {seen:?}");
        let n = stdout.read(&mut buf).unwrap();
        assert!(n > 0, "stdout closed early: {seen:?}");
        seen.push_str(&String::from_utf8_lossy(&buf[..n]));
    }
    assert!(seen.contains("%begin"), "{seen:?}");
    drop(stdin);
    let status = wait_exit(&mut child, Duration::from_secs(5));
    assert!(status.is_some(), "client survived stdin EOF");
    cleanup(child);
}

#[test]
fn exits_on_stdin_eof_after_stdout_reader_is_gone_and_output_was_written() {
    // The leak: sshd closes the stdout pipe, tmux then writes a notification (EPIPE), and from
    // then on a bare `tmux -C` ignores stdin EOF.
    let Some(bin) = tmux_bin() else { return };
    let env = Env::new(bin, "eof");
    let mut child = env.spawn_attach("x");
    let stdin = child.stdin.take().unwrap();
    let stdout = child.stdout.take().unwrap();
    wait_attached(&env);
    drop(stdout);
    std::thread::sleep(Duration::from_millis(300));
    env.tmux().args(["rename-window", "-t", "x:0", "zz"]).output().unwrap();
    std::thread::sleep(Duration::from_millis(500));
    drop(stdin);
    let status = wait_exit(&mut child, Duration::from_secs(5));
    assert!(status.is_some(), "client survived stdin EOF after EPIPE");
    cleanup(child);
}

#[test]
fn exits_when_session_is_killed_after_stdout_reader_is_gone() {
    let Some(bin) = tmux_bin() else { return };
    let env = Env::new(bin, "kill");
    let mut child = env.spawn_attach("x");
    let _stdin = child.stdin.take().unwrap();
    let stdout = child.stdout.take().unwrap();
    wait_attached(&env);
    drop(stdout);
    std::thread::sleep(Duration::from_millis(300));
    env.tmux().args(["kill-session", "-t", "x"]).output().unwrap();
    let status = wait_exit(&mut child, Duration::from_secs(5));
    assert!(status.is_some(), "client survived the destruction of its session");
    cleanup(child);
}

#[test]
fn propagates_the_exit_status_of_tmux() {
    let Some(bin) = tmux_bin() else { return };
    let env = Env::new(bin, "status");
    let mut child = env.spawn_attach("does-not-exist");
    let _stdin = child.stdin.take().unwrap();
    let status = wait_exit(&mut child, Duration::from_secs(5)).expect("exits");
    assert!(!status.success());
    let mut err = String::new();
    child.stderr.take().unwrap().read_to_string(&mut err).unwrap();
    assert!(err.contains("session") || err.contains("find"), "{err:?}");
    cleanup(child);
}
