mod common;

use std::sync::Arc;
use std::time::Duration;

use async_trait::async_trait;
use common::*;
use russh::keys::signature::Signer as _;
use russh::keys::{PrivateKey, PublicKey};
use shuai_ssh::{
    AuthMethod, ExecEvent, KbdInteractivePrompter, KbdPrompt, PtyRequest, Session, SshError,
    SshSigner,
};
use tokio::time::timeout;

const T: Duration = Duration::from_secs(5);

async fn connect(server: &TestServer, auth: Vec<AuthMethod>) -> Result<Session, SshError> {
    Session::connect(cfg(server, auth), Arc::new(AcceptAll::default())).await
}

fn authed(key: &PrivateKey) -> ServerOpts {
    ServerOpts {
        authorized_keys: vec![key.public_key().clone()],
    }
}

fn auth_failed(methods: &[&str]) -> SshError {
    SshError::AuthFailed {
        tried_methods: methods.iter().map(|s| s.to_string()).collect(),
    }
}

async fn read_until(shell: &shuai_ssh::ShellChannel, needle: &[u8]) -> Vec<u8> {
    let mut acc = Vec::new();
    while !acc.windows(needle.len()).any(|w| w == needle) {
        let chunk = timeout(T, shell.read())
            .await
            .expect("read timed out")
            .expect("channel ended");
        acc.extend(chunk);
    }
    acc
}

// ---------- authentication ----------

#[tokio::test]
async fn password_auth_succeeds_and_verifier_sees_host_key() {
    let server = start(ServerOpts::default()).await;
    let verifier = Arc::new(AcceptAll::default());
    let s = Session::connect(
        cfg(&server, vec![AuthMethod::Password(PASSWORD.into())]),
        verifier.clone(),
    )
    .await
    .unwrap();
    assert!(!s.is_closed());
    let seen = verifier.seen.lock().unwrap();
    assert_eq!(seen.len(), 1);
    assert_eq!(seen[0].0, "127.0.0.1");
    assert_eq!(seen[0].1, server.port);
    assert_eq!(seen[0].2.key_data(), server.host_key.key_data());
}

#[tokio::test]
async fn wrong_password_fails_with_tried_methods() {
    let server = start(ServerOpts::default()).await;
    let err = connect(&server, vec![AuthMethod::Password("nope".into())])
        .await
        .err()
        .unwrap();
    assert_eq!(err, auth_failed(&["password"]));
}

#[tokio::test]
async fn no_auth_methods_fails() {
    let server = start(ServerOpts::default()).await;
    let err = connect(&server, vec![]).await.err().unwrap();
    assert_eq!(err, auth_failed(&[]));
}

#[tokio::test]
async fn publickey_auth_succeeds() {
    let key = random_key();
    let server = start(authed(&key)).await;
    let s = connect(&server, vec![AuthMethod::PublicKey(Arc::new(key))])
        .await
        .unwrap();
    assert!(!s.is_closed());
}

#[tokio::test]
async fn unauthorized_publickey_fails() {
    let server = start(authed(&random_key())).await;
    let err = connect(&server, vec![AuthMethod::PublicKey(Arc::new(random_key()))])
        .await
        .err()
        .unwrap();
    assert_eq!(err, auth_failed(&["publickey"]));
}

#[tokio::test]
async fn falls_through_to_next_method_in_order() {
    let key = random_key();
    let server = start(authed(&key)).await;
    let s = connect(
        &server,
        vec![
            AuthMethod::Password("bad".into()),
            AuthMethod::PublicKey(Arc::new(key)),
        ],
    )
    .await
    .unwrap();
    assert!(!s.is_closed());
}

#[tokio::test]
async fn all_methods_failing_reports_each_in_order() {
    let server = start(authed(&random_key())).await;
    let err = connect(
        &server,
        vec![
            AuthMethod::Password("bad".into()),
            AuthMethod::PublicKey(Arc::new(random_key())),
        ],
    )
    .await
    .err()
    .unwrap();
    assert_eq!(err, auth_failed(&["password", "publickey"]));
}

struct KeySigner(PrivateKey);

impl SshSigner for KeySigner {
    fn public_key(&self) -> PublicKey {
        self.0.public_key().clone()
    }
    fn sign(&self, data: &[u8]) -> shuai_ssh::Result<Vec<u8>> {
        let sig: russh::keys::ssh_key::Signature = self
            .0
            .try_sign(data)
            .map_err(|e| SshError::Protocol(e.to_string()))?;
        let alg = sig.algorithm();
        let (alg, bytes) = (alg.as_str().as_bytes(), sig.as_bytes());
        let mut blob = Vec::new();
        blob.extend((alg.len() as u32).to_be_bytes());
        blob.extend(alg);
        blob.extend((bytes.len() as u32).to_be_bytes());
        blob.extend(bytes);
        Ok(blob)
    }
}

#[tokio::test]
async fn external_signer_auth_succeeds() {
    let key = random_key();
    let server = start(authed(&key)).await;
    let s = connect(&server, vec![AuthMethod::Signer(Arc::new(KeySigner(key)))])
        .await
        .unwrap();
    assert!(!s.is_closed());
}

#[tokio::test]
async fn external_signer_with_unauthorized_key_fails() {
    let server = start(authed(&random_key())).await;
    let err = connect(
        &server,
        vec![AuthMethod::Signer(Arc::new(KeySigner(random_key())))],
    )
    .await
    .err()
    .unwrap();
    assert_eq!(err, auth_failed(&["signer"]));
}

struct FailingSigner(PublicKey);
impl SshSigner for FailingSigner {
    fn public_key(&self) -> PublicKey {
        self.0.clone()
    }
    fn sign(&self, _data: &[u8]) -> shuai_ssh::Result<Vec<u8>> {
        Err(SshError::Protocol("user cancelled".into()))
    }
}

#[tokio::test]
async fn signer_error_is_treated_as_failed_method() {
    let key = random_key();
    let server = start(authed(&key)).await;
    let signer = FailingSigner(key.public_key().clone());
    let err = connect(&server, vec![AuthMethod::Signer(Arc::new(signer))])
        .await
        .err()
        .unwrap();
    assert_eq!(err, auth_failed(&["signer"]));
}

struct Otp(&'static str);

#[async_trait]
impl KbdInteractivePrompter for Otp {
    async fn respond(
        &self,
        name: &str,
        _instructions: &str,
        prompts: &[KbdPrompt],
    ) -> Option<Vec<String>> {
        assert_eq!(name, "otp");
        assert_eq!(
            prompts,
            &[KbdPrompt {
                prompt: "Code: ".into(),
                echo: false
            }]
        );
        Some(vec![self.0.to_string()])
    }
}

struct Cancel;

#[async_trait]
impl KbdInteractivePrompter for Cancel {
    async fn respond(&self, _: &str, _: &str, _: &[KbdPrompt]) -> Option<Vec<String>> {
        None
    }
}

fn kbd_cfg(server: &TestServer, p: Arc<dyn KbdInteractivePrompter>) -> shuai_ssh::ConnectConfig {
    let mut c = cfg(server, vec![AuthMethod::KeyboardInteractive(p)]);
    c.username = KBD_USER.into();
    c
}

#[tokio::test]
async fn keyboard_interactive_succeeds() {
    let server = start(ServerOpts::default()).await;
    let s = Session::connect(
        kbd_cfg(&server, Arc::new(Otp(KBD_CODE))),
        Arc::new(AcceptAll::default()),
    )
    .await
    .unwrap();
    assert!(!s.is_closed());
}

#[tokio::test]
async fn keyboard_interactive_wrong_code_or_cancel_fails() {
    let server = start(ServerOpts::default()).await;
    for p in [
        Arc::new(Otp("000000")) as Arc<dyn KbdInteractivePrompter>,
        Arc::new(Cancel),
    ] {
        let err = Session::connect(kbd_cfg(&server, p), Arc::new(AcceptAll::default()))
            .await
            .err();
        assert_eq!(err, Some(auth_failed(&["keyboard-interactive"])));
    }
}

// ---------- host key / connect errors ----------

#[tokio::test]
async fn rejected_host_key_yields_host_key_rejected() {
    let server = start(ServerOpts::default()).await;
    let err = Session::connect(
        cfg(&server, vec![AuthMethod::Password(PASSWORD.into())]),
        Arc::new(RejectAll),
    )
    .await
    .err()
    .unwrap();
    assert_eq!(err, SshError::HostKeyRejected);
}

#[tokio::test]
async fn connection_refused_is_connect_error() {
    let port = {
        let l = tokio::net::TcpListener::bind(("127.0.0.1", 0))
            .await
            .unwrap();
        l.local_addr().unwrap().port()
    };
    let mut c = shuai_ssh::ConnectConfig::new("127.0.0.1", USER);
    c.port = port;
    c.auth = vec![AuthMethod::Password(PASSWORD.into())];
    let err = Session::connect(c, Arc::new(AcceptAll::default()))
        .await
        .err()
        .unwrap();
    assert!(matches!(err, SshError::Connect(_)), "{err:?}");
}

#[tokio::test]
async fn silent_server_hits_connect_timeout() {
    // Accepts TCP (kernel backlog) but never speaks SSH.
    let l = tokio::net::TcpListener::bind(("127.0.0.1", 0))
        .await
        .unwrap();
    let mut c = shuai_ssh::ConnectConfig::new("127.0.0.1", USER);
    c.port = l.local_addr().unwrap().port();
    c.auth = vec![AuthMethod::Password(PASSWORD.into())];
    c.connect_timeout = Duration::from_millis(300);
    let err = Session::connect(c, Arc::new(AcceptAll::default()))
        .await
        .err()
        .unwrap();
    assert_eq!(err, SshError::Timeout);
}

// ---------- shell ----------

#[tokio::test]
async fn shell_echoes_ascii_and_cjk_utf8() {
    let server = start(ServerOpts::default()).await;
    let s = connect(&server, vec![AuthMethod::Password(PASSWORD.into())])
        .await
        .unwrap();
    let shell = s.open_shell(PtyRequest::xterm(100, 30)).await.unwrap();

    shell.write(b"hello\r").await.unwrap();
    assert_eq!(read_until(&shell, b"hello\r").await, b"hello\r");

    let text = "你好，世界 ✓ 🚀";
    shell.write(text.as_bytes()).await.unwrap();
    let got = read_until(&shell, text.as_bytes()).await;
    assert_eq!(String::from_utf8(got).unwrap(), text);
}

#[tokio::test]
async fn shell_requests_pty_and_env() {
    let server = start(ServerOpts::default()).await;
    let s = connect(&server, vec![AuthMethod::Password(PASSWORD.into())])
        .await
        .unwrap();
    let shell = s.open_shell(PtyRequest::xterm(132, 43)).await.unwrap();
    shell.write(b"x").await.unwrap();
    read_until(&shell, b"x").await;
    assert_eq!(
        server.log.ptys.lock().unwrap().as_slice(),
        &[("xterm-256color".into(), 132, 43)]
    );
    assert!(
        server
            .log
            .env
            .lock()
            .unwrap()
            .contains(&("COLORTERM".to_string(), "truecolor".to_string()))
    );
}

#[tokio::test]
async fn shell_resize_reaches_server() {
    let server = start(ServerOpts::default()).await;
    let s = connect(&server, vec![AuthMethod::Password(PASSWORD.into())])
        .await
        .unwrap();
    let shell = s.open_shell(PtyRequest::xterm(80, 24)).await.unwrap();
    shell.resize(120, 40).await.unwrap();
    let got = read_until(&shell, b"RESIZE 120 40").await;
    assert_eq!(got, b"RESIZE 120 40");
}

#[tokio::test]
async fn shell_read_returns_none_after_close() {
    let server = start(ServerOpts::default()).await;
    let s = connect(&server, vec![AuthMethod::Password(PASSWORD.into())])
        .await
        .unwrap();
    let shell = s.open_shell(PtyRequest::xterm(80, 24)).await.unwrap();
    shell.close().await.unwrap();
    assert_eq!(timeout(T, shell.read()).await.unwrap(), None);
    assert!(shell.write(b"x").await.is_err());
}

// ---------- exec ----------

#[tokio::test]
async fn exec_collects_stdout_and_exit_zero() {
    let server = start(ServerOpts::default()).await;
    let s = connect(&server, vec![AuthMethod::Password(PASSWORD.into())])
        .await
        .unwrap();
    let out = s.exec("ok").await.unwrap();
    assert_eq!(out.stdout, b"fine\n");
    assert!(out.stderr.is_empty());
    assert_eq!(out.exit_status, Some(0));
}

#[tokio::test]
async fn exec_collects_stderr_and_nonzero_exit() {
    let server = start(ServerOpts::default()).await;
    let s = connect(&server, vec![AuthMethod::Password(PASSWORD.into())])
        .await
        .unwrap();
    let out = s.exec("fail").await.unwrap();
    assert_eq!(out.stdout, b"partial out\n");
    assert_eq!(out.stderr, b"some err\n");
    assert_eq!(out.exit_status, Some(3));
}

#[tokio::test]
async fn exec_sessions_can_run_concurrently_and_repeatedly() {
    let server = start(ServerOpts::default()).await;
    let s = connect(&server, vec![AuthMethod::Password(PASSWORD.into())])
        .await
        .unwrap();
    let (a, b) = tokio::join!(s.exec("ok"), s.exec("fail"));
    assert_eq!(a.unwrap().exit_status, Some(0));
    assert_eq!(b.unwrap().exit_status, Some(3));
    assert_eq!(s.exec("ok").await.unwrap().exit_status, Some(0));
}

#[tokio::test]
async fn exec_stream_yields_events_over_time() {
    let server = start(ServerOpts::default()).await;
    let s = connect(&server, vec![AuthMethod::Password(PASSWORD.into())])
        .await
        .unwrap();
    let ch = s.exec_stream("stream").await.unwrap();
    let mut stdout = Vec::new();
    let mut exit = None;
    let started = std::time::Instant::now();
    while let Some(ev) = timeout(T, ch.next()).await.unwrap() {
        match ev {
            ExecEvent::Stdout(d) => stdout.extend(d),
            ExecEvent::ExitStatus(c) => exit = Some(c),
            ExecEvent::Stderr(_) => panic!("unexpected stderr"),
        }
    }
    assert_eq!(
        String::from_utf8(stdout).unwrap(),
        "line 0\nline 1\nline 2\n"
    );
    assert_eq!(exit, Some(0));
    assert!(
        started.elapsed() >= Duration::from_millis(100),
        "output should be spread over time"
    );
}

// ---------- lifecycle ----------

#[tokio::test]
async fn local_disconnect_closes_session() {
    let server = start(ServerOpts::default()).await;
    let s = connect(&server, vec![AuthMethod::Password(PASSWORD.into())])
        .await
        .unwrap();
    s.disconnect().await.unwrap();
    timeout(T, s.closed()).await.unwrap();
    assert!(s.is_closed());
    assert!(s.exec("ok").await.is_err());
}

#[tokio::test]
async fn server_side_disconnect_is_detected() {
    let server = start(ServerOpts::default()).await;
    let s = connect(&server, vec![AuthMethod::Password(PASSWORD.into())])
        .await
        .unwrap();
    let shell = s.open_shell(PtyRequest::xterm(80, 24)).await.unwrap();
    // Exec "drop" makes the server tear down the connection.
    let _ = s.exec_stream("drop").await;
    let why = timeout(T, s.closed())
        .await
        .expect("disconnect not detected");
    assert_eq!(why, SshError::Disconnected);
    assert!(s.is_closed());
    assert_eq!(timeout(T, shell.read()).await.unwrap(), None);
}

#[tokio::test]
async fn keepalive_timeout_reports_disconnect() {
    let server = start(ServerOpts::default()).await;
    let mut c = cfg(&server, vec![AuthMethod::Password(PASSWORD.into())]);
    c.keepalive_interval = Duration::from_millis(100);
    c.keepalive_max = 2;
    let s = Session::connect(c, Arc::new(AcceptAll::default()))
        .await
        .unwrap();
    // The server stops processing anything after receiving this.
    let shell = s.open_shell(PtyRequest::xterm(80, 24)).await.unwrap();
    shell.write(b"HANG").await.unwrap();
    assert!(!s.is_closed());
    let why = timeout(Duration::from_secs(3), s.closed())
        .await
        .expect("keepalive never fired");
    assert_eq!(why, SshError::Disconnected);
    assert!(s.is_closed());
}

// ---------- resource hygiene / failure reporting ----------

async fn wait_closes(server: &TestServer, n: usize) -> bool {
    for _ in 0..50 {
        if server.log.closes.load(std::sync::atomic::Ordering::SeqCst) >= n {
            return true;
        }
        tokio::time::sleep(Duration::from_millis(40)).await;
    }
    false
}

#[tokio::test]
async fn dropping_exec_channel_closes_remote_channel() {
    let server = start(ServerOpts::default()).await;
    let s = connect(&server, vec![AuthMethod::Password(PASSWORD.into())])
        .await
        .unwrap();
    let ch = s.exec_stream("hold").await.unwrap();
    drop(ch);
    assert!(wait_closes(&server, 1).await, "remote channel leaked");
}

#[tokio::test]
async fn dropping_shell_channel_closes_remote_channel() {
    let server = start(ServerOpts::default()).await;
    let s = connect(&server, vec![AuthMethod::Password(PASSWORD.into())])
        .await
        .unwrap();
    let shell = s.open_shell(PtyRequest::xterm(80, 24)).await.unwrap();
    drop(shell);
    assert!(wait_closes(&server, 1).await, "remote channel leaked");
}

#[tokio::test]
async fn exec_interrupted_by_disconnect_is_an_error_not_a_success() {
    let server = start(ServerOpts::default()).await;
    let s = connect(&server, vec![AuthMethod::Password(PASSWORD.into())])
        .await
        .unwrap();
    let r = timeout(T, s.exec("cut")).await.unwrap();
    assert_eq!(r, Err(SshError::Disconnected));
}
