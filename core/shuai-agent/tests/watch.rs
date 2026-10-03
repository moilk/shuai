mod common;
use common::*;
use std::time::Duration;

const T: Duration = Duration::from_secs(5);

#[test]
fn watch_replays_after_cursor_then_follows() {
    let h = home();
    for _ in 0..3 {
        hook(h.path(), "Stop", &fixture("stop"), &[]);
    }
    let w = Watcher::spawn(h.path(), &["--since", "1"]);
    assert_eq!(w.next_event(T).unwrap()["seq"], 2);
    assert_eq!(w.next_event(T).unwrap()["seq"], 3);
    hook(h.path(), "SessionEnd", &fixture("session_end"), &[]);
    let e = w.next_event(T).unwrap();
    assert_eq!(e["seq"], 4);
    assert_eq!(e["event"]["type"], "session_end");
}

#[test]
fn watch_without_since_replays_everything() {
    let h = home();
    for _ in 0..2 {
        hook(h.path(), "Stop", &fixture("stop"), &[]);
    }
    let w = Watcher::spawn(h.path(), &[]);
    assert_eq!(w.next_event(T).unwrap()["seq"], 1);
    assert_eq!(w.next_event(T).unwrap()["seq"], 2);
}

#[test]
fn watch_works_when_nothing_exists_yet() {
    let h = home();
    let w = Watcher::spawn(h.path(), &[]);
    w.ready();
    hook(h.path(), "Stop", &fixture("stop"), &[]);
    assert_eq!(w.next_event(T).unwrap()["seq"], 1);
}

#[test]
fn watch_emits_heartbeats_and_touches_presence() {
    let h = home();
    let w = Watcher::spawn(h.path(), &[]);
    let first = w.next_line(T).unwrap();
    assert_eq!(first, serde_json::json!({"type": "heartbeat"}));
    assert!(w.next_line(T).unwrap()["type"] == "heartbeat");
    let m1 = std::fs::metadata(h.path().join("presence"))
        .unwrap()
        .modified()
        .unwrap();
    std::thread::sleep(Duration::from_millis(600));
    let m2 = std::fs::metadata(h.path().join("presence"))
        .unwrap()
        .modified()
        .unwrap();
    assert!(m2 > m1, "presence must be refreshed by heartbeats");
}

#[test]
fn watch_follows_across_rotation_without_loss() {
    let h = home();
    let w = Watcher::spawn(h.path(), &[]);
    w.ready();
    let n = 40u64;
    for _ in 0..n {
        let mut c = agent(h.path());
        c.args(["hook", "Stop"]).env("SHUAI_MAX_LOG_BYTES", "2500");
        run_with_stdin(c, &fixture("stop"));
        // The log keeps only one rotated file, so a follower must see each file before it is
        // rotated away a second time; pace the writers like a (very busy) real session.
        std::thread::sleep(Duration::from_millis(25));
    }
    assert!(
        h.path().join("events.jsonl.1").exists(),
        "rotation should have happened"
    );
    let mut got = Vec::new();
    while got.len() < n as usize {
        match w.next_event(T) {
            Some(e) => got.push(e["seq"].as_u64().unwrap()),
            None => break,
        }
    }
    assert_eq!(got, (1..=n).collect::<Vec<_>>());
}

#[test]
fn watch_replay_reads_rotated_file_first() {
    let h = home();
    for _ in 0..30 {
        let mut c = agent(h.path());
        c.args(["hook", "Stop"]).env("SHUAI_MAX_LOG_BYTES", "3000");
        run_with_stdin(c, &fixture("stop"));
    }
    let old: Vec<u64> = seqs(&events(h.path()));
    let w = Watcher::spawn(h.path(), &[]);
    let mut got = Vec::new();
    while got.len() < old.len() {
        got.push(w.next_event(T).unwrap()["seq"].as_u64().unwrap());
    }
    assert_eq!(got, old);
}

#[test]
fn watch_exits_when_stdout_closes() {
    use std::io::{BufRead, BufReader};
    use std::process::Stdio;
    let h = home();
    let mut c = agent(h.path());
    c.args(["watch", "--heartbeat-secs", "0.2"])
        .stdin(Stdio::null())
        .stdout(Stdio::piped());
    let mut child = c.spawn().unwrap();
    let mut r = BufReader::new(child.stdout.take().unwrap());
    let mut l = String::new();
    r.read_line(&mut l).unwrap();
    drop(r); // close the read end -> EPIPE on the next write
    let t0 = std::time::Instant::now();
    let status = loop {
        if let Some(s) = child.try_wait().unwrap() {
            break s;
        }
        if t0.elapsed() > Duration::from_secs(5) {
            let _ = child.kill();
            panic!("watch did not exit after EPIPE");
        }
        std::thread::sleep(Duration::from_millis(50));
    };
    assert!(status.success());
}
