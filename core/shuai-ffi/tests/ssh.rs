use std::sync::{Arc, Mutex};
use std::time::Duration;

use shuai_ffi::*;
use shuai_keys::ssh_key::PublicKey;
use shuai_testkit::{PASSWORD, ServerOpts, TestServer, USER, start};
use tokio::time::timeout;

const T: Duration = Duration::from_secs(5);

#[derive(Default)]
struct Verifier {
    accept: bool,
    seen: Mutex<Vec<(String, u16, String)>>,
}

#[async_trait::async_trait]
impl HostKeyVerifierCallback for Verifier {
    async fn verify(&self, host: String, port: u16, public_key_line: String) -> bool {
        self.seen
            .lock()
            .unwrap()
            .push((host, port, public_key_line));
        self.accept
    }
}

fn accepting() -> Arc<Verifier> {
    Arc::new(Verifier {
        accept: true,
        ..Default::default()
    })
}

fn config(server: &TestServer, user: &str, auth: Vec<FfiAuth>) -> FfiConnectConfig {
    FfiConnectConfig {
        host: "127.0.0.1".into(),
        port: server.port,
        username: user.into(),
        auth,
        keepalive_secs: 15,
        connect_timeout_secs: 5,
        auth_timeout_secs: 10,
    }
}

fn pw() -> Vec<FfiAuth> {
    vec![FfiAuth::Password {
        password: PASSWORD.into(),
    }]
}

async fn connect(server: &TestServer) -> Arc<SshConnection> {
    SshConnection::connect(config(server, USER, pw()), accepting())
        .await
        .unwrap()
}

async fn read_until(shell: &ShellStream, needle: &str) -> String {
    let mut acc = Vec::new();
    while !String::from_utf8_lossy(&acc).contains(needle) {
        match timeout(T, shell.next_event()).await.expect("timed out") {
            ShellEvent::Data { bytes } => acc.extend(bytes),
            other => panic!("unexpected {other:?}"),
        }
    }
    String::from_utf8_lossy(&acc).into_owned()
}

#[tokio::test]
async fn password_connect_shell_round_trip_with_cjk() {
    let server = start(ServerOpts::default()).await;
    let verifier = accepting();
    let conn = SshConnection::connect(config(&server, USER, pw()), verifier.clone())
        .await
        .unwrap();
    {
        let seen = verifier.seen.lock().unwrap();
        assert_eq!(seen.len(), 1);
        assert_eq!(seen[0].0, "127.0.0.1");
        assert_eq!(seen[0].1, server.port);
        let expected = shuai_keys::authorized_keys_line(&server.host_key);
        assert_eq!(seen[0].2, expected);
    }
    let shell = conn
        .open_shell(80, 24, "xterm-256color".into(), vec![])
        .await
        .unwrap();
    shell
        .write("echo 中文\n".as_bytes().to_vec())
        .await
        .unwrap();
    let out = read_until(&shell, "中文").await;
    assert!(out.contains("echo 中文"));
}

#[tokio::test]
async fn resize_reaches_server() {
    let server = start(ServerOpts::default()).await;
    let conn = connect(&server).await;
    let shell = conn
        .open_shell(
            80,
            24,
            "xterm".into(),
            vec![FfiEnvVar {
                name: "LANG".into(),
                value: "en_US.UTF-8".into(),
            }],
        )
        .await
        .unwrap();
    shell.resize(100, 30).await.unwrap();
    read_until(&shell, "RESIZE 100 30").await;
    assert_eq!(server.log.ptys.lock().unwrap()[0], ("xterm".into(), 80, 24));
}

#[tokio::test]
async fn shell_exit_then_closed() {
    let server = start(ServerOpts::default()).await;
    let conn = connect(&server).await;
    let shell = conn
        .open_shell(80, 24, "xterm".into(), vec![])
        .await
        .unwrap();
    shell.write(b"EXIT3".to_vec()).await.unwrap();
    let mut saw_exit = false;
    loop {
        match timeout(T, shell.next_event()).await.unwrap() {
            ShellEvent::Exit { status, .. } => {
                assert_eq!(status, Some(3));
                saw_exit = true;
            }
            ShellEvent::Closed { reason } => {
                assert_eq!(reason, CloseReason::Remote);
                break;
            }
            ShellEvent::Data { .. } => {}
        }
    }
    assert!(saw_exit);
}

#[tokio::test]
async fn host_key_rejection_maps_to_error() {
    let server = start(ServerOpts::default()).await;
    let v = Arc::new(Verifier::default());
    let err = SshConnection::connect(config(&server, USER, pw()), v)
        .await
        .err()
        .unwrap();
    assert_eq!(err, FfiSshError::HostKeyRejected);
}

#[tokio::test]
async fn wrong_password_maps_to_auth_failed() {
    let server = start(ServerOpts::default()).await;
    let err = SshConnection::connect(
        config(
            &server,
            USER,
            vec![FfiAuth::Password {
                password: "bad".into(),
            }],
        ),
        accepting(),
    )
    .await
    .err()
    .unwrap();
    assert_eq!(
        err,
        FfiSshError::AuthFailed {
            tried_methods: vec!["password".into()]
        }
    );
}

#[tokio::test]
async fn connection_refused_maps_to_connect_error() {
    let server = start(ServerOpts::default()).await;
    let mut cfg = config(&server, USER, pw());
    cfg.port = 1; // nothing listens there
    let err = SshConnection::connect(cfg, accepting())
        .await
        .err()
        .unwrap();
    assert!(matches!(err, FfiSshError::Connect { .. }), "{err:?}");
}

#[tokio::test]
async fn private_key_pem_auth() {
    let key = generate_key(KeyAlg::Ed25519, "t".into()).unwrap();
    let server = start(ServerOpts {
        authorized_keys: vec![PublicKey::from_openssh(&key.public_line).unwrap()],
    })
    .await;
    let conn = SshConnection::connect(
        config(
            &server,
            "bob",
            vec![FfiAuth::PrivateKeyPem {
                pem: key.private_pem,
            }],
        ),
        accepting(),
    )
    .await
    .unwrap();
    assert_eq!(conn.exec("ok".into()).await.unwrap().exit_status, Some(0));
}

#[tokio::test]
async fn malformed_private_key_pem_is_reported() {
    let server = start(ServerOpts::default()).await;
    let err = SshConnection::connect(
        config(
            &server,
            "bob",
            vec![FfiAuth::PrivateKeyPem { pem: "junk".into() }],
        ),
        accepting(),
    )
    .await
    .err()
    .unwrap();
    assert!(matches!(err, FfiSshError::InvalidKey { .. }), "{err:?}");
}

struct Signer(shuai_keys::PrivateKey);

impl SignerCallback for Signer {
    fn public_key_line(&self) -> String {
        shuai_keys::authorized_keys_line(self.0.public_key())
    }
    fn sign(&self, data: Vec<u8>) -> Option<Vec<u8>> {
        use shuai_ssh::keys::signature::Signer as _;
        use shuai_ssh::keys::ssh_key::Signature;
        let sig: Signature = self.0.try_sign(&data).ok()?;
        let alg = sig.algorithm();
        let (alg, bytes) = (alg.as_str().as_bytes(), sig.as_bytes());
        let mut blob = Vec::new();
        blob.extend((alg.len() as u32).to_be_bytes());
        blob.extend(alg);
        blob.extend((bytes.len() as u32).to_be_bytes());
        blob.extend(bytes);
        Some(blob)
    }
}

#[tokio::test]
async fn external_signer_auth() {
    let key = shuai_keys::generate(shuai_keys::KeyAlgorithm::Ed25519, "s").unwrap();
    let server = start(ServerOpts {
        authorized_keys: vec![key.public_key().clone()],
    })
    .await;
    let conn = SshConnection::connect(
        config(
            &server,
            "bob",
            vec![FfiAuth::Signer {
                signer: Arc::new(Signer(key)),
            }],
        ),
        accepting(),
    )
    .await
    .unwrap();
    assert_eq!(conn.exec("ok".into()).await.unwrap().exit_status, Some(0));
}

struct Prompter;

#[async_trait::async_trait]
impl KbdPrompterCallback for Prompter {
    async fn respond(
        &self,
        _name: String,
        _instructions: String,
        prompts: Vec<FfiKbdPrompt>,
    ) -> Option<Vec<String>> {
        assert_eq!(prompts[0].prompt, "Code: ");
        Some(vec!["123456".into()])
    }
}

#[tokio::test]
async fn keyboard_interactive_auth() {
    let server = start(ServerOpts::default()).await;
    let conn = SshConnection::connect(
        config(
            &server,
            "kbd",
            vec![FfiAuth::KeyboardInteractive {
                prompter: Arc::new(Prompter),
            }],
        ),
        accepting(),
    )
    .await
    .unwrap();
    assert_eq!(conn.exec("ok".into()).await.unwrap().exit_status, Some(0));
}

#[tokio::test]
async fn exec_collects_output_and_status() {
    let server = start(ServerOpts::default()).await;
    let conn = connect(&server).await;
    let r = conn.exec("ok".into()).await.unwrap();
    assert_eq!(r.stdout, b"fine\n");
    assert_eq!(r.exit_status, Some(0));
    let r = conn.exec("fail".into()).await.unwrap();
    assert_eq!(r.stderr, b"some err\n");
    assert_eq!(r.exit_status, Some(3));
    let r = conn.exec("sig".into()).await.unwrap();
    assert_eq!(r.exit_signal.as_deref(), Some("KILL"));
}

#[tokio::test]
async fn exec_stream_events_end_with_closed() {
    let server = start(ServerOpts::default()).await;
    let conn = connect(&server).await;
    let s = conn.exec_stream("stream".into()).await.unwrap();
    let (mut out, mut status) = (String::new(), None);
    loop {
        match timeout(T, s.next_event()).await.unwrap() {
            ExecEvent::Stdout { bytes } => out.push_str(&String::from_utf8_lossy(&bytes)),
            ExecEvent::ExitStatus { status: st } => status = Some(st),
            ExecEvent::Closed { .. } => break,
            _ => {}
        }
    }
    assert_eq!(out, "line 0\nline 1\nline 2\n");
    assert_eq!(status, Some(0));
}

#[tokio::test]
async fn exec_stream_stdin_and_eof() {
    let server = start(ServerOpts::default()).await;
    let conn = connect(&server).await;
    let s = conn.exec_stream("cat".into()).await.unwrap();
    s.write_stdin(b"hello".to_vec()).await.unwrap();
    match timeout(T, s.next_event()).await.unwrap() {
        ExecEvent::Stdout { bytes } => assert_eq!(bytes, b"hello"),
        other => panic!("{other:?}"),
    }
    s.eof().await.unwrap();
    loop {
        if let ExecEvent::Closed { .. } = timeout(T, s.next_event()).await.unwrap() {
            break;
        }
    }
}

#[tokio::test]
async fn disconnect_resolves_closed_with_local() {
    let server = start(ServerOpts::default()).await;
    let conn = connect(&server).await;
    conn.disconnect().await.unwrap();
    let reason = timeout(T, conn.closed()).await.unwrap();
    assert_eq!(reason, CloseReason::Local);
}

#[tokio::test]
async fn server_drop_resolves_closed_as_not_local() {
    let server = start(ServerOpts::default()).await;
    let conn = connect(&server).await;
    let _ = conn.exec("drop".into()).await;
    let reason = timeout(T, conn.closed()).await.unwrap();
    assert_ne!(reason, CloseReason::Local);
}

#[test]
fn upload_command_quotes_path_and_sets_mode() {
    assert_eq!(
        upload_command("/tmp/shuai-agent".into(), 0o755),
        "cat > /tmp/shuai-agent && chmod -- 755 /tmp/shuai-agent"
    );
    assert_eq!(
        upload_command("/tmp/a b'c".into(), 0o600),
        "cat > '/tmp/a b'\\''c' && chmod -- 600 '/tmp/a b'\\''c'"
    );
}

#[tokio::test]
async fn upload_streams_bytes_via_exec() {
    let server = start(ServerOpts::default()).await;
    let conn = connect(&server).await;
    let data: Vec<u8> = (0..200_000u32).map(|i| (i % 251) as u8).collect();
    conn.upload(data.clone(), "/tmp/x y".into(), 0o755)
        .await
        .unwrap();
    let uploads = server.log.uploads.lock().unwrap();
    assert_eq!(uploads.len(), 1);
    assert_eq!(uploads[0].0, upload_command("/tmp/x y".into(), 0o755));
    assert_eq!(uploads[0].1, data);
}

#[tokio::test]
async fn upload_failure_is_reported() {
    let server = start(ServerOpts::default()).await;
    let conn = connect(&server).await;
    // The test server fails every `cat > /readonly/...` upload with status 1.
    let err = conn
        .upload(b"x".to_vec(), "/readonly/x".into(), 0o644)
        .await
        .unwrap_err();
    assert!(matches!(err, FfiSshError::Protocol { .. }), "{err:?}");
}

#[test]
fn upload_command_places_double_dash_before_path_and_masks_mode() {
    assert_eq!(
        upload_command("-x".into(), 0o100755),
        "cat > -x && chmod -- 755 -x"
    );
}

/// Runs the generated command in a real `sh` with hostile paths: no injection, exact content.
#[test]
fn upload_command_is_injection_safe_in_a_real_shell() {
    use std::io::Write;
    use std::os::unix::fs::PermissionsExt;
    use std::process::{Command, Stdio};

    let dir = tempfile::tempdir().unwrap();
    let names = [
        "plain",
        "with space",
        "it's",
        "semi;touch pwned",
        "dollar$HOME",
        "sub$(touch pwned)",
        "tick`touch pwned`",
        "amp&&touch pwned",
        "-dash",
        "star*",
        "new\nline",
        "quote\"d",
        "back\\slash",
    ];
    for name in names {
        let cmd = upload_command(name.into(), 0o640);
        let mut child = Command::new("sh")
            .arg("-c")
            .arg(&cmd)
            .current_dir(dir.path())
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        child
            .stdin
            .take()
            .unwrap()
            .write_all(name.as_bytes())
            .unwrap();
        let out = child.wait_with_output().unwrap();
        assert!(out.status.success(), "{name:?}: {out:?}");
        let p = dir.path().join(name);
        assert_eq!(std::fs::read(&p).unwrap(), name.as_bytes(), "{name:?}");
        assert_eq!(
            std::fs::metadata(&p).unwrap().permissions().mode() & 0o7777,
            0o640,
            "{name:?}"
        );
    }
    assert!(!dir.path().join("pwned").exists(), "command injection");
    assert_eq!(std::fs::read_dir(dir.path()).unwrap().count(), names.len());
}

#[tokio::test]
async fn upload_4mb_is_chunked_and_terminated_with_eof() {
    let server = start(ServerOpts::default()).await;
    let conn = connect(&server).await;
    let data: Vec<u8> = (0..4 * 1024 * 1024u32).map(|i| (i % 253) as u8).collect();
    conn.upload(data.clone(), "/tmp/big".into(), 0o600)
        .await
        .unwrap();
    let uploads = server.log.uploads.lock().unwrap();
    assert_eq!(uploads[0].1.len(), data.len());
    assert!(uploads[0].1 == data);
}

#[tokio::test]
async fn upload_failure_before_stdin_is_consumed_keeps_remote_diagnostics() {
    let server = start(ServerOpts::default()).await;
    let conn = connect(&server).await;
    let data = vec![7u8; 4 * 1024 * 1024];
    let err = conn
        .upload(data, "/readonly/x".into(), 0o644)
        .await
        .unwrap_err();
    match err {
        FfiSshError::Protocol { message } => {
            assert!(message.contains("permission denied"), "{message}");
            assert!(message.contains("Some(1)"), "{message}");
        }
        other => panic!("{other:?}"),
    }
}
