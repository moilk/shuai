//! Append-only `events.jsonl` with a lock-protected sequence counter and size rotation.

use crate::state::{State, private_open};
use std::fs::{self, File};
use std::io::{self, Write};

/// Highest `seq` found in the (rotated and current) logs; used if the counter file is lost.
fn recover_seq(state: &State) -> u64 {
    for p in [state.events_path(), state.rotated_path()] {
        if let Ok(s) = fs::read_to_string(&p) {
            for l in s.lines().rev() {
                if let Ok(v) = serde_json::from_str::<serde_json::Value>(l)
                    && let Some(n) = v.get("seq").and_then(|n| n.as_u64())
                {
                    return n;
                }
            }
        }
    }
    0
}

fn next_seq(state: &State) -> u64 {
    let last = fs::read_to_string(state.seq_path())
        .ok()
        .and_then(|s| s.trim().parse::<u64>().ok())
        .unwrap_or_else(|| recover_seq(state));
    last + 1
}

/// Append one line. `build` receives the freshly allocated `seq` and returns the line
/// (without trailing newline). Everything happens under an exclusive `flock`, so concurrent
/// writers never interleave and `seq` is strictly increasing in file order.
pub fn append_with(state: &State, build: impl FnOnce(u64) -> String) -> io::Result<u64> {
    state.ensure()?;
    let lock = private_open()
        .create(true)
        .truncate(false)
        .write(true)
        .open(state.lock_path())?;
    // Never hang a hook on a wedged lock holder: give up after a bounded wait.
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
    loop {
        match lock.try_lock() {
            Ok(()) => break,
            Err(std::fs::TryLockError::WouldBlock) if std::time::Instant::now() < deadline => {
                std::thread::sleep(std::time::Duration::from_millis(5));
            }
            Err(std::fs::TryLockError::WouldBlock) => {
                return Err(io::Error::new(io::ErrorKind::TimedOut, "events lock busy"));
            }
            Err(std::fs::TryLockError::Error(e)) => return Err(e),
        }
    }
    let result = (|| {
        let seq = next_seq(state);
        let mut line = build(seq);
        line.push('\n');

        let size = fs::metadata(state.events_path())
            .map(|m| m.len())
            .unwrap_or(0);
        if size > 0 && size + line.len() as u64 > state.max_log_bytes() {
            fs::rename(state.events_path(), state.rotated_path())?;
        }
        // Persist the counter first: a crash in between leaves a gap, never a duplicate seq.
        let mut sf = private_open();
        sf.write(true).create(true).truncate(true);
        sf.open(state.seq_path())?
            .write_all(seq.to_string().as_bytes())?;
        let mut f: File = private_open()
            .create(true)
            .append(true)
            .open(state.events_path())?;
        f.write_all(line.as_bytes())?;
        Ok(seq)
    })();
    let _ = lock.unlock();
    result
}
