//! Append-only `events.jsonl` with a lock-protected sequence counter and size rotation.

use crate::state::State;
use std::fs::{self, File, OpenOptions};
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
    let lock = OpenOptions::new()
        .create(true)
        .truncate(false)
        .write(true)
        .open(state.lock_path())?;
    lock.lock()?;
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
        let mut f: File = OpenOptions::new()
            .create(true)
            .append(true)
            .open(state.events_path())?;
        f.write_all(line.as_bytes())?;
        fs::write(state.seq_path(), seq.to_string())?;
        Ok(seq)
    })();
    let _ = lock.unlock();
    result
}
