//! Smoke test against a real OpenSSH server. Ignored by default; run with
//!
//! ```text
//! SHUAI_TEST_SSH_HOST=... SHUAI_TEST_SSH_USER=... SHUAI_TEST_SSH_KEY=~/.ssh/id_ed25519 \
//!   [SHUAI_TEST_SSH_PORT=22] cargo test -p shuai-ssh -- --ignored real_sshd_smoke
//! ```
//!
//! The key must be an unencrypted private key file. The host key is NOT verified.

use std::sync::Arc;
use std::time::Duration;

use async_trait::async_trait;
use russh::keys::PublicKey;
use shuai_ssh::{AuthMethod, ConnectConfig, HostKeyVerifier, PtyRequest, Session};
use tokio::time::timeout;

struct AcceptAny;

#[async_trait]
impl HostKeyVerifier for AcceptAny {
    async fn verify(&self, _host: &str, _port: u16, _key: &PublicKey) -> bool {
        true
    }
}

fn env(name: &str) -> String {
    std::env::var(name).unwrap_or_else(|_| panic!("{name} must be set"))
}

fn count(haystack: &[u8], needle: &[u8]) -> usize {
    haystack
        .windows(needle.len())
        .filter(|w| *w == needle)
        .count()
}

#[tokio::test]
#[ignore = "needs a real sshd; see module docs"]
async fn real_sshd_smoke() {
    let host = env("SHUAI_TEST_SSH_HOST");
    let user = env("SHUAI_TEST_SSH_USER");
    let key_path = env("SHUAI_TEST_SSH_KEY");
    let port = std::env::var("SHUAI_TEST_SSH_PORT")
        .ok()
        .map(|p| p.parse().expect("SHUAI_TEST_SSH_PORT must be a number"))
        .unwrap_or(22);

    let key = russh::keys::load_secret_key(&key_path, None)
        .unwrap_or_else(|e| panic!("cannot load {key_path} (must be unencrypted): {e}"));
    let mut cfg = ConnectConfig::new(host, user);
    cfg.port = port;
    cfg.connect_timeout = Duration::from_secs(20);
    cfg.auth = vec![AuthMethod::PublicKey(Arc::new(key))];

    let session = Session::connect(cfg, Arc::new(AcceptAny)).await.unwrap();

    // exec
    let out = session.exec("echo hi; uname -s").await.unwrap();
    let stdout = String::from_utf8(out.stdout).unwrap();
    let mut lines = stdout.lines();
    assert_eq!(lines.next(), Some("hi"), "stdout: {stdout:?}");
    assert!(lines.next().is_some_and(|s| !s.is_empty()), "{stdout:?}");
    assert_eq!(out.exit_status, Some(0));

    // Shell with a UTF-8 round trip: the pty echoes the typed line and `echo` prints the
    // text again, so the needle must show up at least twice.
    let shell = session
        .open_shell(PtyRequest::xterm(100, 30))
        .await
        .unwrap();
    shell.write("echo 中文\n".as_bytes()).await.unwrap();
    let needle = "中文".as_bytes();
    let mut acc = Vec::new();
    while count(&acc, needle) < 2 {
        let chunk = timeout(Duration::from_secs(15), shell.read())
            .await
            .expect("timed out waiting for shell output")
            .expect("shell closed early");
        acc.extend(chunk);
    }

    shell.close().await.unwrap();
    session.disconnect().await.unwrap();
}
