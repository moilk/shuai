//! `shuai-agent watch`: replay then follow `events.jsonl` (surviving rotation).

use crate::state::State;
use std::fs::{self, File};
use std::io::{self, Read, Write};
use std::os::unix::fs::MetadataExt;
use std::time::{Duration, Instant};

struct Tail {
    file: File,
    ino: u64,
    buf: Vec<u8>,
}

impl Tail {
    fn open(state: &State) -> Option<Tail> {
        let file = File::open(state.events_path()).ok()?;
        let ino = file.metadata().ok()?.ino();
        Some(Tail {
            file,
            ino,
            buf: Vec::new(),
        })
    }

    /// Read everything currently available and emit complete lines.
    fn drain(&mut self, last: &mut u64, out: &mut impl Write) -> io::Result<()> {
        let mut chunk = [0u8; 64 * 1024];
        loop {
            let n = self.file.read(&mut chunk)?;
            if n == 0 {
                break;
            }
            self.buf.extend_from_slice(&chunk[..n]);
        }
        let Some(end) = self.buf.iter().rposition(|&b| b == b'\n') else {
            return Ok(());
        };
        let complete: Vec<u8> = self.buf.drain(..=end).collect();
        emit_lines(&complete, last, out)
    }
}

fn emit_lines(data: &[u8], last: &mut u64, out: &mut impl Write) -> io::Result<()> {
    for line in data.split(|&b| b == b'\n') {
        if line.is_empty() {
            continue;
        }
        let Ok(v) = serde_json::from_slice::<serde_json::Value>(line) else {
            continue;
        };
        let Some(seq) = v.get("seq").and_then(|s| s.as_u64()) else {
            continue;
        };
        if seq <= *last {
            continue;
        }
        out.write_all(line)?;
        out.write_all(b"\n")?;
        out.flush()?;
        *last = seq;
    }
    Ok(())
}

fn replay_rotated(
    state: &State,
    skip_ino: Option<u64>,
    last: &mut u64,
    out: &mut impl Write,
) -> io::Result<()> {
    let Ok(data) = fs::read(state.rotated_path()) else {
        return Ok(());
    };
    if let (Some(skip), Ok(m)) = (skip_ino, fs::metadata(state.rotated_path()))
        && m.ino() == skip
    {
        return Ok(()); // that is the file we are already following
    }
    // Only complete lines.
    let end = data.iter().rposition(|&b| b == b'\n').map_or(0, |i| i + 1);
    emit_lines(&data[..end], last, out)
}

fn heartbeat(state: &State, out: &mut impl Write) -> io::Result<()> {
    let _ = state.touch_presence();
    out.write_all(b"{\"type\":\"heartbeat\"}\n")?;
    out.flush()
}

/// Run until the output closes (EPIPE), which is a normal way to end.
pub fn run(
    state: &State,
    since: u64,
    heartbeat_every: Duration,
    out: &mut impl Write,
) -> io::Result<()> {
    match run_inner(state, since, heartbeat_every, out) {
        Err(e) if e.kind() == io::ErrorKind::BrokenPipe => Ok(()),
        r => r,
    }
}

fn run_inner(
    state: &State,
    since: u64,
    heartbeat_every: Duration,
    out: &mut impl Write,
) -> io::Result<()> {
    state.ensure()?;
    heartbeat(state, out)?;
    let mut last = since;

    // Open the current file first so a rotation during replay cannot hide events.
    let mut cur = Tail::open(state);
    replay_rotated(state, cur.as_ref().map(|t| t.ino), &mut last, out)?;
    if let Some(t) = cur.as_mut() {
        t.drain(&mut last, out)?;
    }

    let mut next_beat = Instant::now() + heartbeat_every;
    loop {
        std::thread::sleep(state.poll_interval());
        match cur.as_mut() {
            Some(t) => {
                t.drain(&mut last, out)?;
                let rotated = fs::metadata(state.events_path())
                    .map(|m| m.ino() != t.ino)
                    .unwrap_or(false);
                if rotated {
                    t.drain(&mut last, out)?; // writers finished before the rename; get the rest
                    replay_rotated(state, Some(t.ino), &mut last, out)?; // intermediate files
                    cur = Tail::open(state);
                    if let Some(t) = cur.as_mut() {
                        t.drain(&mut last, out)?;
                    }
                }
            }
            None => {
                cur = Tail::open(state);
                if let Some(t) = cur.as_mut() {
                    replay_rotated(state, Some(t.ino), &mut last, out)?;
                    t.drain(&mut last, out)?;
                }
            }
        }
        if Instant::now() >= next_beat {
            heartbeat(state, out)?;
            next_beat = Instant::now() + heartbeat_every;
        }
    }
}
