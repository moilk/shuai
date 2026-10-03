//! Drives the builders, the control-mode controller and PTY client targeting against a real
//! tmux server (`-L shuaim4 -f /dev/null`, killed afterwards). Skipped when tmux is missing.

use std::io::{Read, Write};
use std::process::{Child, Command, Stdio};
use std::sync::mpsc;
use std::thread;
use std::time::{Duration, Instant};

use shuai_tmux::clients::{parse_clients, pick_pty_client};
use shuai_tmux::controller::{ControllerEvent, TmuxController};
use shuai_tmux::parse::parse_topology;
use shuai_tmux::{Direction, Target, TmuxCommand, TmuxTopology, TmuxVersion, WindowId, cmd};

const SOCKET: &str = "shuaim4";

fn tmux_bin() -> Option<String> {
    ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
        .iter()
        .find(|p| std::path::Path::new(p).exists())
        .map(|s| s.to_string())
}

struct Server {
    bin: String,
    children: Vec<Child>,
}

impl Server {
    fn start(bin: String) -> Self {
        let s = Server {
            bin,
            children: vec![],
        };
        s.base()
            .args(["new-session", "-d", "-s", "main", "-x", "120", "-y", "40"])
            .status()
            .unwrap();
        s
    }
    fn base(&self) -> Command {
        let mut c = Command::new(&self.bin);
        c.env_remove("TMUX")
            .args(["-L", SOCKET, "-f", "/dev/null"]);
        c
    }
    fn run(&self, c: &TmuxCommand) -> String {
        let out = self.base().args(c.argv()).output().unwrap();
        assert!(
            out.status.success(),
            "{:?}: {}",
            c.argv(),
            String::from_utf8_lossy(&out.stderr)
        );
        String::from_utf8(out.stdout).unwrap()
    }
    fn topology(&self) -> TmuxTopology {
        parse_topology(&self.run(&cmd::list_panes_all())).unwrap()
    }
}

impl Drop for Server {
    fn drop(&mut self) {
        for c in &mut self.children {
            let _ = c.kill();
            let _ = c.wait();
        }
        let _ = self.base().arg("kill-server").output();
    }
}

fn session<'a>(t: &'a TmuxTopology, name: &str) -> &'a shuai_tmux::TmuxSession {
    t.sessions.iter().find(|s| s.name == name).unwrap()
}

fn serial<T>(f: impl FnOnce() -> T) -> T {
    // one server name is shared by the tests in this file
    static LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());
    let _g = LOCK.lock().unwrap_or_else(|e| e.into_inner());
    f()
}

#[test]
fn builders_drive_a_real_server() {
    let Some(bin) = tmux_bin() else { return };
    serial(|| {
        let srv = Server::start(bin);
        let main = Target::session("main");

        srv.run(&cmd::new_window(&main, Some("/tmp"), Some("second")));
        let t = srv.topology();
        let s = session(&t, "main");
        assert_eq!(s.windows.len(), 2);
        let second = s.windows.iter().find(|w| w.name == "second").unwrap();
        assert!(second.active);
        assert!(second.panes[0].current_path.ends_with("/tmp") || second.panes[0].current_path.contains("tmp"));

        // split in the pane's cwd, both directions
        let pane = second.panes[0].id;
        srv.run(&cmd::split_window(&Target::pane(pane), Direction::Horizontal, Some("/tmp")));
        srv.run(&cmd::split_window(&Target::pane(pane), Direction::Vertical, None));
        let t = srv.topology();
        let second = session(&t, "main")
            .windows
            .iter()
            .find(|w| w.name == "second")
            .unwrap();
        assert_eq!(second.panes.len(), 3);
        let wid = second.id;

        // zoom toggles the window flag
        srv.run(&cmd::zoom_pane(&Target::pane(pane)));
        let z = srv.run(&cmd::display_message(
            Some(&Target::window(wid)),
            "#{window_zoomed_flag}",
        ));
        assert_eq!(z.trim(), "1");
        srv.run(&cmd::zoom_pane(&Target::pane(pane)));

        // rename with odd characters survives the round trip
        srv.run(&cmd::rename_window(&Target::window(wid), "we ird;\"x"));
        assert_eq!(
            session(&srv.topology(), "main")
                .windows
                .iter()
                .find(|w| w.id == wid)
                .unwrap()
                .name,
            "we ird;\"x"
        );

        // navigation
        srv.run(&cmd::previous_window(&main));
        assert!(session(&srv.topology(), "main").windows[0].active);
        srv.run(&cmd::next_window(&main));
        assert!(session(&srv.topology(), "main").windows[1].active);
        srv.run(&cmd::last_window(&main));
        assert!(session(&srv.topology(), "main").windows[0].active);

        // select by id, kill
        srv.run(&cmd::select_window(&Target::window(wid)));
        assert!(
            session(&srv.topology(), "main")
                .windows
                .iter()
                .find(|w| w.id == wid)
                .unwrap()
                .active
        );
        srv.run(&cmd::kill_window(&Target::window(wid)));
        assert_eq!(session(&srv.topology(), "main").windows.len(), 1);
    });
}

/// Control-mode child with its stdout pumped into a channel.
struct Control {
    child: Child,
    rx: mpsc::Receiver<Vec<u8>>,
}

fn spawn_control(srv: &Server, session: &str) -> Control {
    let mut child = srv
        .base()
        .args(cmd::control_attach(session, false).argv())
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    let mut out = child.stdout.take().unwrap();
    let (tx, rx) = mpsc::channel();
    thread::spawn(move || {
        let mut buf = [0u8; 4096];
        while let Ok(n) = out.read(&mut buf) {
            if n == 0 || tx.send(buf[..n].to_vec()).is_err() {
                break;
            }
        }
    });
    Control { child, rx }
}

fn pump_until(
    ctl: &Control,
    c: &mut TmuxController,
    mut done: impl FnMut(&ControllerEvent) -> bool,
) -> Vec<ControllerEvent> {
    let deadline = Instant::now() + Duration::from_secs(5);
    let mut all = vec![];
    while Instant::now() < deadline {
        if let Ok(bytes) = ctl.rx.recv_timeout(Duration::from_millis(100)) {
            for e in c.push(&bytes) {
                let d = done(&e);
                all.push(e);
                if d {
                    return all;
                }
            }
        }
    }
    panic!("timed out; events so far: {all:?}");
}

#[test]
fn control_channel_without_a_pty_gives_events_and_replies() {
    let Some(bin) = tmux_bin() else { return };
    serial(|| {
        let mut srv = Server::start(bin);
        let version = TmuxVersion::parse(&String::from_utf8(
            srv.base().arg("-V").output().unwrap().stdout,
        ).unwrap())
        .unwrap();
        let mut ctl = spawn_control(&srv, "main");
        let mut c = TmuxController::new("main", version);
        {
            let stdin = ctl.child.stdin.as_mut().unwrap();
            for l in c.on_connected() {
                writeln!(stdin, "{l}").unwrap();
            }
        }
        // our own pid via display-message in the control client's context
        let (tok, line) = c.send(&cmd::display_message(None, "#{client_pid}"));
        writeln!(ctl.child.stdin.as_mut().unwrap(), "{line}").unwrap();
        let ev = pump_until(&ctl, &mut c, |e| matches!(e, ControllerEvent::Reply(r) if r.token == Some(tok)));
        let ControllerEvent::Reply(r) = ev.last().unwrap() else { unreachable!() };
        assert!(r.ok);
        assert_eq!(r.lines, vec![ctl.child.id().to_string()]);

        // structural change made elsewhere reaches us as NeedsRefresh
        srv.run(&cmd::new_window(&Target::session("main"), None, None));
        pump_until(&ctl, &mut c, |e| *e == ControllerEvent::NeedsRefresh);

        // commands over the channel work and are replied to
        let (tok, line) = c.send(&cmd::list_panes_all());
        writeln!(ctl.child.stdin.as_mut().unwrap(), "{line}").unwrap();
        let ev = pump_until(&ctl, &mut c, |e| matches!(e, ControllerEvent::Reply(r) if r.token == Some(tok)));
        let ControllerEvent::Reply(r) = ev.last().unwrap() else { unreachable!() };
        let t = parse_topology(&r.lines.join("\n")).unwrap();
        assert_eq!(session(&t, "main").windows.len(), 2);

        // rename over the channel then a direct patch event comes back
        let wid: WindowId = session(&t, "main").windows[1].id;
        let (_, line) = c.send(&cmd::rename_window(&Target::window(wid), "viactl"));
        writeln!(ctl.child.stdin.as_mut().unwrap(), "{line}").unwrap();
        pump_until(&ctl, &mut c, |e| matches!(e, ControllerEvent::WindowRenamed { name, .. } if name == "viactl"));

        let _ = ctl.child.kill();
        let _ = ctl.child.wait();
        srv.children.clear();
    });
}

#[test]
fn switch_client_moves_the_pty_client_not_the_control_client() {
    let Some(bin) = tmux_bin() else { return };
    if !std::path::Path::new("/usr/bin/script").exists() {
        return;
    }
    serial(|| {
        let mut srv = Server::start(bin.clone());
        srv.run(&TmuxCommand::from_argv(
            ["new-session", "-d", "-s", "other"].map(String::from).to_vec(),
        ));
        // a real PTY client (script allocates the pty); stdin stays open
        let pty = Command::new("/usr/bin/script")
            .args(["-q", "/dev/null", &bin, "-L", SOCKET, "-f", "/dev/null", "attach", "-t", "=main:"])
            .env_remove("TMUX")
            .env("TERM", "xterm-256color")
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        srv.children.push(pty);
        thread::sleep(Duration::from_millis(1200));

        let mut ctl = spawn_control(&srv, "main");
        let version = TmuxVersion::parse("tmux 3.6a").unwrap();
        let mut c = TmuxController::new("main", version);
        for l in c.on_connected() {
            writeln!(ctl.child.stdin.as_mut().unwrap(), "{l}").unwrap();
        }
        thread::sleep(Duration::from_millis(500));

        let list = |c: &mut TmuxController, ctl: &mut Control| {
            let (tok, line) = c.send(&cmd::list_clients());
            writeln!(ctl.child.stdin.as_mut().unwrap(), "{line}").unwrap();
            let ev = pump_until(ctl, c, |e| matches!(e, ControllerEvent::Reply(r) if r.token == Some(tok)));
            let ControllerEvent::Reply(r) = ev.last().unwrap() else { unreachable!() };
            parse_clients(&r.lines.join("\n")).unwrap()
        };
        let clients = list(&mut c, &mut ctl);
        assert_eq!(clients.len(), 2, "{clients:?}");
        let tty = pick_pty_client(&clients, "main", Some(ctl.child.id()), None)
            .expect("pty client found");
        assert!(!clients.iter().find(|c| c.tty == tty).unwrap().control_mode);

        // switch through the control channel, targeting the PTY client
        let (tok, line) = c.send(&cmd::switch_client(&tty, &Target::session("other")));
        writeln!(ctl.child.stdin.as_mut().unwrap(), "{line}").unwrap();
        let ev = pump_until(&ctl, &mut c, |e| matches!(e, ControllerEvent::Reply(r) if r.token == Some(tok)));
        let ControllerEvent::Reply(r) = ev.last().unwrap() else { unreachable!() };
        assert!(r.ok, "{r:?}");

        let after = list(&mut c, &mut ctl);
        let pty = after.iter().find(|c| c.tty == tty).unwrap();
        assert_eq!(pty.session_name, "other");
        let control = after.iter().find(|c| c.control_mode).unwrap();
        assert_eq!(control.session_name, "main", "control client must stay put");

        let _ = ctl.child.kill();
        let _ = ctl.child.wait();
    });
}
