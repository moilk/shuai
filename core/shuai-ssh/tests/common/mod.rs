//! In-process russh server used by the integration tests.
//!
//! Behaviour:
//! * auth: password (`alice`/`secret`), public keys from `authorized_keys`, and
//!   keyboard-interactive (user `kbd`, answer `123456`).
//! * pty shell: echoes input, answers window changes with `RESIZE <cols> <rows>`.
//! * exec: `ok`, `fail`, `stream`, `drop` (see `exec_request`); shell input `HANG` freezes
//!   the connection (used for keepalive tests).
#![allow(dead_code)]

use std::sync::{Arc, Mutex};
use std::time::Duration;

use async_trait::async_trait;
use russh::keys::{Algorithm, PrivateKey, PublicKey};
use russh::server::{Auth, Msg, Response, Server as _, Session};
use russh::{Channel, ChannelId, Pty};
use shuai_ssh::HostKeyVerifier;
use tokio::net::TcpListener;

pub const USER: &str = "alice";
pub const PASSWORD: &str = "secret";
pub const KBD_USER: &str = "kbd";
pub const KBD_CODE: &str = "123456";

#[derive(Default)]
pub struct ServerLog {
    pub ptys: Mutex<Vec<(String, u32, u32)>>,
    pub env: Mutex<Vec<(String, String)>>,
    pub users: Mutex<Vec<String>>,
}

#[derive(Clone, Default)]
pub struct ServerOpts {
    pub authorized_keys: Vec<PublicKey>,
}

pub struct TestServer {
    pub port: u16,
    pub host_key: PublicKey,
    pub log: Arc<ServerLog>,
    task: tokio::task::JoinHandle<()>,
}

impl Drop for TestServer {
    fn drop(&mut self) {
        self.task.abort();
    }
}

pub fn random_key() -> PrivateKey {
    PrivateKey::random(&mut rand::rng(), Algorithm::Ed25519).unwrap()
}

pub async fn start(opts: ServerOpts) -> TestServer {
    let host = random_key();
    let host_key = host.public_key().clone();
    let config = Arc::new(russh::server::Config {
        auth_rejection_time: Duration::from_millis(10),
        auth_rejection_time_initial: Some(Duration::ZERO),
        keys: vec![host],
        ..Default::default()
    });
    let socket = TcpListener::bind(("127.0.0.1", 0)).await.unwrap();
    let port = socket.local_addr().unwrap().port();
    let log = Arc::new(ServerLog::default());
    let mut srv = Srv {
        opts,
        log: log.clone(),
    };
    let task = tokio::spawn(async move {
        let _ = srv.run_on_socket(config, &socket).await;
    });
    TestServer {
        port,
        host_key,
        log,
        task,
    }
}

#[derive(Clone)]
struct Srv {
    opts: ServerOpts,
    log: Arc<ServerLog>,
}

impl russh::server::Server for Srv {
    type Handler = Self;
    fn new_client(&mut self, _: Option<std::net::SocketAddr>) -> Self {
        self.clone()
    }
}

impl russh::server::Handler for Srv {
    type Error = russh::Error;

    async fn auth_password(&mut self, user: &str, password: &str) -> Result<Auth, Self::Error> {
        if user == USER && password == PASSWORD {
            self.log.users.lock().unwrap().push(user.into());
            Ok(Auth::Accept)
        } else {
            Ok(Auth::reject())
        }
    }

    async fn auth_publickey_offered(
        &mut self,
        _user: &str,
        key: &PublicKey,
    ) -> Result<Auth, Self::Error> {
        if self
            .opts
            .authorized_keys
            .iter()
            .any(|k| k.key_data() == key.key_data())
        {
            Ok(Auth::Accept)
        } else {
            Ok(Auth::reject())
        }
    }

    async fn auth_publickey(&mut self, user: &str, key: &PublicKey) -> Result<Auth, Self::Error> {
        if self
            .opts
            .authorized_keys
            .iter()
            .any(|k| k.key_data() == key.key_data())
        {
            self.log.users.lock().unwrap().push(user.into());
            Ok(Auth::Accept)
        } else {
            Ok(Auth::reject())
        }
    }

    async fn auth_keyboard_interactive<'a>(
        &'a mut self,
        user: &str,
        _submethods: &str,
        response: Option<Response<'a>>,
    ) -> Result<Auth, Self::Error> {
        if user != KBD_USER {
            return Ok(Auth::reject());
        }
        match response {
            None => Ok(Auth::Partial {
                name: "otp".into(),
                instructions: "enter code".into(),
                prompts: vec![("Code: ".into(), false)].into(),
            }),
            Some(mut r) => {
                let ok = r.next().is_some_and(|b| b.as_ref() == KBD_CODE.as_bytes());
                Ok(if ok { Auth::Accept } else { Auth::reject() })
            }
        }
    }

    async fn channel_open_session(
        &mut self,
        _channel: Channel<Msg>,
        reply: russh::server::ChannelOpenHandle,
        _session: &mut Session,
    ) -> Result<(), Self::Error> {
        reply.accept().await;
        Ok(())
    }

    async fn pty_request(
        &mut self,
        channel: ChannelId,
        term: &str,
        cols: u32,
        rows: u32,
        _pw: u32,
        _ph: u32,
        _modes: &[(Pty, u32)],
        session: &mut Session,
    ) -> Result<(), Self::Error> {
        self.log
            .ptys
            .lock()
            .unwrap()
            .push((term.into(), cols, rows));
        session.channel_success(channel)
    }

    async fn env_request(
        &mut self,
        _channel: ChannelId,
        name: &str,
        value: &str,
        _session: &mut Session,
    ) -> Result<(), Self::Error> {
        self.log
            .env
            .lock()
            .unwrap()
            .push((name.into(), value.into()));
        Ok(())
    }

    async fn shell_request(
        &mut self,
        channel: ChannelId,
        session: &mut Session,
    ) -> Result<(), Self::Error> {
        session.channel_success(channel)
    }

    async fn data(
        &mut self,
        channel: ChannelId,
        data: &[u8],
        session: &mut Session,
    ) -> Result<(), Self::Error> {
        if data == b"HANG" {
            // Never answer anything again: blocks this connection's event loop.
            std::future::pending::<()>().await;
        }
        session.data(channel, data.to_vec())
    }

    async fn window_change_request(
        &mut self,
        channel: ChannelId,
        cols: u32,
        rows: u32,
        _pw: u32,
        _ph: u32,
        session: &mut Session,
    ) -> Result<(), Self::Error> {
        session.data(channel, format!("RESIZE {cols} {rows}").into_bytes())
    }

    async fn exec_request(
        &mut self,
        channel: ChannelId,
        data: &[u8],
        session: &mut Session,
    ) -> Result<(), Self::Error> {
        let cmd = String::from_utf8_lossy(data).to_string();
        session.channel_success(channel)?;
        let handle = session.handle();
        match cmd.as_str() {
            "ok" => {
                let _ = handle.data(channel, b"fine\n".to_vec()).await;
                let _ = handle.exit_status_request(channel, 0).await;
                let _ = handle.eof(channel).await;
                let _ = handle.close(channel).await;
            }
            "fail" => {
                let _ = handle.data(channel, b"partial out\n".to_vec()).await;
                let _ = handle
                    .extended_data(channel, 1, b"some err\n".to_vec())
                    .await;
                let _ = handle.exit_status_request(channel, 3).await;
                let _ = handle.eof(channel).await;
                let _ = handle.close(channel).await;
            }
            "stream" => {
                tokio::spawn(async move {
                    for i in 0..3 {
                        let _ = handle
                            .data(channel, format!("line {i}\n").into_bytes())
                            .await;
                        tokio::time::sleep(Duration::from_millis(60)).await;
                    }
                    let _ = handle.exit_status_request(channel, 0).await;
                    let _ = handle.eof(channel).await;
                    let _ = handle.close(channel).await;
                });
            }
            // Tear the whole connection down from the server side.
            "drop" => return Err(russh::Error::Disconnect),
            _ => {
                let _ = handle.exit_status_request(channel, 127).await;
                let _ = handle.close(channel).await;
            }
        }
        Ok(())
    }
}

/// Accepts everything, remembering what it was asked about.
#[derive(Default)]
pub struct AcceptAll {
    pub seen: Mutex<Vec<(String, u16, PublicKey)>>,
}

#[async_trait]
impl HostKeyVerifier for AcceptAll {
    async fn verify(&self, host: &str, port: u16, key: &PublicKey) -> bool {
        self.seen
            .lock()
            .unwrap()
            .push((host.into(), port, key.clone()));
        true
    }
}

pub struct RejectAll;

#[async_trait]
impl HostKeyVerifier for RejectAll {
    async fn verify(&self, _host: &str, _port: u16, _key: &PublicKey) -> bool {
        false
    }
}

pub fn cfg(server: &TestServer, auth: Vec<shuai_ssh::AuthMethod>) -> shuai_ssh::ConnectConfig {
    let mut c = shuai_ssh::ConnectConfig::new("127.0.0.1", USER);
    c.port = server.port;
    c.auth = auth;
    c.connect_timeout = Duration::from_secs(5);
    c
}
