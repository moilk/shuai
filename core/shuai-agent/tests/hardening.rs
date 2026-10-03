mod common;
use common::*;
use std::os::unix::fs::PermissionsExt;

fn mode(p: &std::path::Path) -> u32 {
    std::fs::metadata(p).unwrap().permissions().mode() & 0o777
}

#[test]
fn state_files_are_private() {
    let h = home();
    let dir = h.path().join("state");
    let mut c = agent(&dir);
    c.args(["hook", "Stop"]);
    run_with_stdin(c, &fixture("stop"));
    let out = agent(&dir)
        .args(["respond", "abc", "allow"])
        .output()
        .unwrap();
    assert!(out.status.success());
    assert_eq!(mode(&dir), 0o700);
    assert_eq!(mode(&dir.join("responses")), 0o700);
    for f in ["events.jsonl", "seq", "events.lock"] {
        assert_eq!(mode(&dir.join(f)), 0o600, "{f}");
    }
    assert_eq!(mode(&dir.join("responses/abc.json")), 0o600);
}

#[test]
fn request_ids_have_128_bits_of_randomness() {
    let h = home();
    for _ in 0..2 {
        let mut c = agent(h.path());
        c.args(["hook", "PermissionRequest"]);
        run_with_stdin(c, &fixture("permission_request"));
    }
    let ids: Vec<String> = events(h.path())
        .iter()
        .filter(|e| e["event"]["type"] == "permission_request")
        .map(|e| e["event"]["request_id"].as_str().unwrap().to_string())
        .collect();
    assert_eq!(ids.len(), 2);
    for id in &ids {
        assert!(
            id.len() >= 32 && id.bytes().all(|b| b.is_ascii_hexdigit()),
            "{id}"
        );
    }
    assert_ne!(ids[0], ids[1]);
}

#[test]
fn huge_stdin_still_exits_zero() {
    let h = home();
    let big = format!(
        "{{\"session_id\":\"s\",\"hook_event_name\":\"Stop\",\"x\":\"{}\"}}",
        "a".repeat(40 * 1024 * 1024)
    );
    let mut c = agent(h.path());
    c.args(["hook", "Stop"]);
    let out = run_with_stdin(c, &big);
    assert_eq!(out.status.code(), Some(0));
}
