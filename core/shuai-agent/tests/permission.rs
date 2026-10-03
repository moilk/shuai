mod common;
use common::*;
use serde_json::{Value, json};
use std::time::{Duration, Instant};

const T: Duration = Duration::from_secs(10);

fn resolved(h: &std::path::Path) -> Vec<Value> {
    events(h)
        .into_iter()
        .filter(|e| e["event"]["type"] == "permission_resolved")
        .collect()
}

/// Start a watch (so presence exists), run the PermissionRequest hook in the background and
/// return (watcher, hook output receiver, request_id).
fn start_request(
    h: &std::path::Path,
    extra: &[&str],
) -> (Watcher, std::sync::mpsc::Receiver<std::process::Output>, String) {
    let w = Watcher::spawn(h, &[]);
    w.ready();
    let mut c = agent(h);
    c.args(["hook", "PermissionRequest"]).args(extra);
    let rx = spawn_hook(c, fixture("permission_request"));
    let e = w.next_event(T).expect("request event");
    assert_eq!(e["event"]["type"], "permission_request");
    assert_eq!(e["event"]["tool_name"], "Bash");
    let id = e["event"]["request_id"].as_str().unwrap().to_string();
    assert!(shuai_proto::is_valid_request_id(&id), "id {id:?}");
    (w, rx, id)
}

#[test]
fn allow_flow() {
    let h = home();
    let (w, rx, id) = start_request(h.path(), &[]);
    let out = agent(h.path()).args(["respond", &id, "allow"]).output().unwrap();
    assert!(out.status.success());

    let out = rx.recv_timeout(T).expect("hook should finish");
    assert_eq!(out.status.code(), Some(0));
    let v: Value = serde_json::from_slice(&out.stdout).unwrap();
    assert_eq!(
        v,
        json!({"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}})
    );
    // the app is told the card is settled
    let r = w.next_event(T).unwrap();
    assert_eq!(r["event"]["type"], "permission_resolved");
    assert_eq!(r["event"]["request_id"], id.as_str());
    assert_eq!(r["event"]["outcome"], "allowed");
    // response file is consumed
    assert!(!h.path().join("responses").join(format!("{id}.json")).exists());
}

#[test]
fn deny_flow_with_message() {
    let h = home();
    let (w, rx, id) = start_request(h.path(), &[]);
    let out = agent(h.path())
        .args(["respond", &id, "deny", "--message", "not on prod"])
        .output()
        .unwrap();
    assert!(out.status.success());
    let out = rx.recv_timeout(T).unwrap();
    let v: Value = serde_json::from_slice(&out.stdout).unwrap();
    assert_eq!(v["hookSpecificOutput"]["decision"]["behavior"], "deny");
    assert_eq!(v["hookSpecificOutput"]["decision"]["message"], "not on prod");
    assert_eq!(w.next_event(T).unwrap()["event"]["outcome"], "denied");
}

#[test]
fn timeout_falls_back_silently() {
    let h = home();
    touch_presence(h.path()); // pretend an app is watching
    let t0 = Instant::now();
    let out = hook(h.path(), "PermissionRequest", &fixture("permission_request"), &["--timeout", "1"]);
    assert!(t0.elapsed() >= Duration::from_millis(900));
    assert!(t0.elapsed() < Duration::from_secs(5));
    assert_eq!(out.status.code(), Some(0));
    assert!(out.stdout.is_empty(), "no output => local dialog");
    let r = resolved(h.path());
    assert_eq!(r.len(), 1);
    assert_eq!(r[0]["event"]["outcome"], "timeout");
}

#[test]
fn no_presence_returns_immediately() {
    let h = home();
    let t0 = Instant::now();
    let out = hook(h.path(), "PermissionRequest", &fixture("permission_request"), &["--timeout", "30"]);
    assert!(t0.elapsed() < Duration::from_secs(3), "took {:?}", t0.elapsed());
    assert_eq!(out.status.code(), Some(0));
    assert!(out.stdout.is_empty());
    let evs = events(h.path());
    assert_eq!(evs[0]["event"]["type"], "permission_request");
    assert_eq!(evs[1]["event"]["type"], "permission_resolved");
    assert_eq!(evs[1]["event"]["outcome"], "not_present");
}

#[test]
fn stale_presence_counts_as_absent() {
    let h = home();
    touch_presence(h.path());
    let mut c = agent(h.path());
    c.env("SHUAI_PRESENCE_TTL_SECS", "0"); // anything older than "now" is stale
    c.args(["hook", "PermissionRequest", "--timeout", "30"]);
    std::thread::sleep(Duration::from_millis(50));
    let t0 = Instant::now();
    let out = run_with_stdin(c, &fixture("permission_request"));
    assert!(t0.elapsed() < Duration::from_secs(3));
    assert!(out.stdout.is_empty());
    assert_eq!(resolved(h.path())[0]["event"]["outcome"], "not_present");
}

#[test]
fn app_disappearing_mid_wait_aborts_early() {
    let h = home();
    touch_presence(h.path());
    let mut c = agent(h.path());
    c.env("SHUAI_PRESENCE_TTL_SECS", "1");
    c.args(["hook", "PermissionRequest", "--timeout", "60"]);
    let t0 = Instant::now();
    let out = run_with_stdin(c, &fixture("permission_request"));
    assert!(t0.elapsed() < Duration::from_secs(10), "took {:?}", t0.elapsed());
    assert!(out.stdout.is_empty());
    assert_eq!(resolved(h.path())[0]["event"]["outcome"], "not_present");
}

#[test]
fn garbage_response_file_is_ignored() {
    let h = home();
    let (_w, rx, id) = start_request(h.path(), &["--timeout", "2"]);
    std::fs::create_dir_all(h.path().join("responses")).unwrap();
    std::fs::write(h.path().join("responses").join(format!("{id}.json")), "{{{").unwrap();
    let out = rx.recv_timeout(T).unwrap();
    assert!(out.stdout.is_empty());
}

#[test]
fn respond_writes_atomically_and_validates_id() {
    let h = home();
    let out = agent(h.path()).args(["respond", "abc-1", "deny", "--message", "no"]).output().unwrap();
    assert!(out.status.success());
    let p = h.path().join("responses/abc-1.json");
    let r: shuai_proto::PermissionResponse = serde_json::from_slice(&std::fs::read(&p).unwrap()).unwrap();
    assert_eq!(r.request_id, "abc-1");
    assert_eq!(r.behavior, shuai_proto::Behavior::Deny);
    assert_eq!(r.message.as_deref(), Some("no"));
    let leftovers: Vec<_> = std::fs::read_dir(h.path().join("responses"))
        .unwrap()
        .map(|e| e.unwrap().file_name().into_string().unwrap())
        .collect();
    assert_eq!(leftovers, vec!["abc-1.json"], "no tmp files left behind");

    let bad = agent(h.path()).args(["respond", "../evil", "allow"]).output().unwrap();
    assert!(!bad.status.success());
    let bad = agent(h.path()).args(["respond", "abc", "maybe"]).output().unwrap();
    assert!(!bad.status.success());
}
