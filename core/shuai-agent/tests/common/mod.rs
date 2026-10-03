#![allow(dead_code)]
//! Shared helpers for shuai-agent integration tests.

use serde_json::Value;
use std::collections::HashMap;
use std::io::{BufRead, BufReader, Read, Write};
use std::net::TcpListener;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Output, Stdio};
use std::sync::mpsc::{self, Receiver};
use std::time::Duration;

pub const BIN: &str = env!("CARGO_BIN_EXE_shuai-agent");

pub fn fixture(name: &str) -> String {
    let p = format!(
        "{}/../shuai-proto/tests/fixtures/{name}.json",
        env!("CARGO_MANIFEST_DIR")
    );
    std::fs::read_to_string(p).unwrap()
}

pub fn home() -> tempfile::TempDir {
    tempfile::tempdir().unwrap()
}

/// A command with a hermetic environment.
pub fn agent(home: &Path) -> Command {
    let mut c = Command::new(BIN);
    c.env("SHUAI_HOME", home)
        .env("SHUAI_HOSTNAME", "test-host")
        .env("SHUAI_POLL_MS", "20")
        .env_remove("TMUX")
        .env_remove("TMUX_PANE")
        .env_remove("SHUAI_PRESENCE_TTL_SECS")
        .env_remove("SHUAI_MAX_LOG_BYTES");
    c
}

pub fn run_with_stdin(mut cmd: Command, stdin: &str) -> Output {
    cmd.stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    let mut child = cmd.spawn().unwrap();
    // The child may exit before reading stdin (e.g. the plugin's guard when the
    // binary is missing), so a broken pipe here is expected, not a failure.
    if let Err(e) = child.stdin.take().unwrap().write_all(stdin.as_bytes()) {
        assert_eq!(
            e.kind(),
            std::io::ErrorKind::BrokenPipe,
            "stdin write failed: {e}"
        );
    }
    child.wait_with_output().unwrap()
}

/// Run `shuai-agent hook <event> [args]` feeding `stdin`.
pub fn hook(home: &Path, event: &str, stdin: &str, args: &[&str]) -> Output {
    let mut c = agent(home);
    c.arg("hook").arg(event).args(args);
    run_with_stdin(c, stdin)
}

/// Spawn a hook without waiting; returns a receiver for its finished output.
pub fn spawn_hook(cmd: Command, stdin: String) -> Receiver<Output> {
    let (tx, rx) = mpsc::channel();
    std::thread::spawn(move || {
        let _ = tx.send(run_with_stdin(cmd, &stdin));
    });
    rx
}

pub fn events(home: &Path) -> Vec<Value> {
    let mut out = Vec::new();
    for name in ["events.jsonl.1", "events.jsonl"] {
        if let Ok(s) = std::fs::read_to_string(home.join(name)) {
            for l in s.lines() {
                out.push(serde_json::from_str(l).unwrap_or_else(|e| panic!("bad line {l:?}: {e}")));
            }
        }
    }
    out
}

pub fn write_config(home: &Path, body: &str) {
    std::fs::create_dir_all(home).unwrap();
    std::fs::write(home.join("config.toml"), body).unwrap();
}

/// Mark an app as present (as `watch` would).
pub fn touch_presence(home: &Path) {
    std::fs::create_dir_all(home).unwrap();
    std::fs::write(home.join("presence"), b"x").unwrap();
}

pub struct Watcher {
    pub child: Child,
    rx: Receiver<String>,
}

impl Watcher {
    pub fn spawn(home: &Path, args: &[&str]) -> Watcher {
        let mut c = agent(home);
        c.arg("watch")
            .args(["--heartbeat-secs", "0.2"])
            .args(args)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::null());
        let mut child = c.spawn().unwrap();
        let out = child.stdout.take().unwrap();
        let (tx, rx) = mpsc::channel();
        std::thread::spawn(move || {
            for l in BufReader::new(out).lines() {
                match l {
                    Ok(l) => {
                        if tx.send(l).is_err() {
                            break;
                        }
                    }
                    Err(_) => break,
                }
            }
        });
        Watcher { child, rx }
    }

    /// Next raw line (heartbeats included).
    pub fn next_line(&self, timeout: Duration) -> Option<Value> {
        self.rx
            .recv_timeout(timeout)
            .ok()
            .map(|l| serde_json::from_str(&l).unwrap_or_else(|e| panic!("bad line {l:?}: {e}")))
    }

    /// Next non-heartbeat envelope.
    pub fn next_event(&self, timeout: Duration) -> Option<Value> {
        let deadline = std::time::Instant::now() + timeout;
        loop {
            let left = deadline.checked_duration_since(std::time::Instant::now())?;
            let v = self.next_line(left)?;
            if v["type"] != "heartbeat" && v["type"] != "caught_up" {
                return Some(v);
            }
        }
    }

    /// Wait for the first line so we know presence has been announced.
    pub fn ready(&self) {
        assert!(
            self.next_line(Duration::from_secs(5)).is_some(),
            "watch produced nothing"
        );
    }
}

impl Drop for Watcher {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

#[derive(Debug)]
pub struct Req {
    pub request_line: String,
    pub headers: HashMap<String, String>,
    pub body: String,
}

/// Minimal HTTP server that records requests and answers 200.
pub struct Mock {
    pub url: String,
    pub rx: Receiver<Req>,
}

pub fn mock_server() -> Mock {
    let l = TcpListener::bind("127.0.0.1:0").unwrap();
    let url = format!("http://{}", l.local_addr().unwrap());
    let (tx, rx) = mpsc::channel();
    std::thread::spawn(move || {
        for s in l.incoming() {
            let Ok(mut s) = s else { continue };
            let mut r = BufReader::new(s.try_clone().unwrap());
            let mut request_line = String::new();
            if r.read_line(&mut request_line).is_err() {
                continue;
            }
            let mut headers = HashMap::new();
            loop {
                let mut h = String::new();
                if r.read_line(&mut h).unwrap_or(0) == 0 || h == "\r\n" {
                    break;
                }
                if let Some((k, v)) = h.trim_end().split_once(':') {
                    headers.insert(k.to_ascii_lowercase(), v.trim().to_string());
                }
            }
            let n: usize = headers
                .get("content-length")
                .and_then(|v| v.parse().ok())
                .unwrap_or(0);
            let mut body = vec![0u8; n];
            let _ = r.read_exact(&mut body);
            let _ =
                s.write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok");
            let _ = tx.send(Req {
                request_line: request_line.trim_end().to_string(),
                headers,
                body: String::from_utf8_lossy(&body).into_owned(),
            });
        }
    });
    Mock { url, rx }
}

pub fn seqs(evs: &[Value]) -> Vec<u64> {
    evs.iter().map(|e| e["seq"].as_u64().unwrap()).collect()
}

pub fn path_in(home: &Path, rel: &str) -> PathBuf {
    home.join(rel)
}
