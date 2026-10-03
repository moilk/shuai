//! Client session, PTY shell and exec channels.

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

use russh::client::{self, Msg};
use russh::keys::{PrivateKeyWithHashAlg, PublicKey, PublicKeyOrCertificate};
use russh::{ChannelMsg, ChannelReadHalf, ChannelWriteHalf, Disconnect};
use tokio::sync::{Mutex, watch};

use crate::config::{
    AuthMethod, ConnectConfig, HostKeyVerifier, KbdInteractivePrompter, KbdPrompt, PtyRequest,
    SshSigner,
};
use crate::error::{Result, SshError};

/// Collected result of [`Session::exec`].
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct ExecOutput {
    /// Standard output bytes.
    pub stdout: Vec<u8>,
    /// Standard error bytes.
    pub stderr: Vec<u8>,
    /// Exit status, if the server reported one.
    pub exit_status: Option<u32>,
}

/// One event from an [`ExecChannel`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ExecEvent {
    /// Bytes on stdout.
    Stdout(Vec<u8>),
    /// Bytes on stderr.
    Stderr(Vec<u8>),
    /// The remote command exited with this status.
    ExitStatus(u32),
}

/// Maximum keyboard-interactive rounds before the method is considered failed.
const MAX_KBD_ROUNDS: usize = 8;

struct ClientHandler {
    verifier: Arc<dyn HostKeyVerifier>,
    host: String,
    port: u16,
    rejected: Arc<AtomicBool>,
    closed_tx: watch::Sender<Option<SshError>>,
}

impl client::Handler for ClientHandler {
    type Error = russh::Error;

    async fn check_server_key(
        &mut self,
        key: &PublicKeyOrCertificate,
    ) -> std::result::Result<bool, Self::Error> {
        let pk: PublicKey = match key {
            PublicKeyOrCertificate::PublicKey { key, .. } => key.clone(),
            PublicKeyOrCertificate::Certificate(c) => PublicKey::from(c.public_key().clone()),
        };
        let ok = self.verifier.verify(&self.host, self.port, &pk).await;
        if !ok {
            self.rejected.store(true, Ordering::SeqCst);
        }
        Ok(ok)
    }

    async fn disconnected(
        &mut self,
        reason: client::DisconnectReason<Self::Error>,
    ) -> std::result::Result<(), Self::Error> {
        let _ = self.closed_tx.send(Some(SshError::Disconnected));
        match reason {
            client::DisconnectReason::ReceivedDisconnect(_) => Ok(()),
            client::DisconnectReason::Error(e) => Err(e),
        }
    }
}

/// Adapts an [`SshSigner`] to russh's agent-style signer trait.
struct SignerAdapter(Arc<dyn SshSigner>);

enum SignFailure {
    Send,
    Signer,
}

impl From<russh::SendError> for SignFailure {
    fn from(_: russh::SendError) -> Self {
        SignFailure::Send
    }
}

impl russh::Signer for SignerAdapter {
    type Error = SignFailure;

    async fn auth_sign(
        &mut self,
        _key: &russh::keys::agent::AgentIdentity,
        _hash_alg: Option<russh::keys::HashAlg>,
        mut to_sign: Vec<u8>,
    ) -> std::result::Result<Vec<u8>, Self::Error> {
        let signer = self.0.clone();
        let payload = to_sign.clone();
        let blob = tokio::task::spawn_blocking(move || signer.sign(&payload))
            .await
            .map_err(|_| SignFailure::Signer)?
            .map_err(|_| SignFailure::Signer)?;
        // russh expects the payload followed by `string(signature-blob)`.
        to_sign.extend((blob.len() as u32).to_be_bytes());
        to_sign.extend(blob);
        Ok(to_sign)
    }
}

enum AuthStep {
    Authenticated,
    Rejected,
    /// The method broke the auth conversation; no further methods can be tried.
    Abort,
}

/// An established, authenticated SSH connection.
///
/// `Session` is `Send + Sync`; channels opened from it are independent and may be used from
/// different tasks.
pub struct Session {
    handle: client::Handle<ClientHandler>,
    closed_rx: watch::Receiver<Option<SshError>>,
}

impl Session {
    /// Connects, verifies the host key via `verifier`, and authenticates using the methods in
    /// `config.auth` in order.
    ///
    /// `config.connect_timeout` bounds TCP connect plus the SSH handshake. Keepalives
    /// (`keepalive@openssh.com`) start once authenticated: the session is torn down after
    /// `keepalive_max` consecutive unanswered intervals (a `keepalive_max` of 0 disables the
    /// check).
    ///
    /// # Errors
    /// [`SshError::Connect`], [`SshError::Timeout`], [`SshError::HostKeyRejected`],
    /// [`SshError::AuthFailed`].
    pub async fn connect(
        config: ConnectConfig,
        verifier: Arc<dyn HostKeyVerifier>,
    ) -> Result<Session> {
        let rejected = Arc::new(AtomicBool::new(false));
        let (closed_tx, closed_rx) = watch::channel(None);
        let handler = ClientHandler {
            verifier,
            host: config.host.clone(),
            port: config.port,
            rejected: rejected.clone(),
            closed_tx,
        };
        let rcfg = Arc::new(client::Config {
            keepalive_interval: Some(config.keepalive_interval),
            keepalive_max: config.keepalive_max as usize,
            inactivity_timeout: None,
            ..Default::default()
        });

        let addr = (config.host.as_str(), config.port);
        let mut handle = match tokio::time::timeout(
            config.connect_timeout,
            client::connect(rcfg, addr, handler),
        )
        .await
        {
            Err(_) => return Err(SshError::Timeout),
            Ok(Err(_)) if rejected.load(Ordering::SeqCst) => {
                return Err(SshError::HostKeyRejected);
            }
            Ok(Err(e)) => return Err(e.into()),
            Ok(Ok(h)) => h,
        };

        authenticate(&mut handle, &config).await?;
        Ok(Session { handle, closed_rx })
    }

    /// Opens a PTY-backed interactive shell.
    pub async fn open_shell(&self, pty: PtyRequest) -> Result<ShellChannel> {
        let mut ch = self.handle.channel_open_session().await?;
        ch.request_pty(true, &pty.term, pty.cols, pty.rows, 0, 0, &[])
            .await?;
        await_reply(&mut ch).await?;
        for (k, v) in &pty.env {
            // Servers commonly refuse unlisted variables; never fail the shell over it.
            ch.set_env(false, k.as_str(), v.as_str()).await?;
        }
        ch.request_shell(true).await?;
        await_reply(&mut ch).await?;
        let (read, write) = ch.split();
        Ok(ShellChannel {
            read: Mutex::new(read),
            write,
            closed: CloseFlag::new(),
        })
    }

    /// Runs `cmd` to completion and collects its output and exit status.
    pub async fn exec(&self, cmd: &str) -> Result<ExecOutput> {
        let ch = self.exec_stream(cmd).await?;
        let mut out = ExecOutput::default();
        while let Some(ev) = ch.next().await {
            match ev {
                ExecEvent::Stdout(d) => out.stdout.extend(d),
                ExecEvent::Stderr(d) => out.stderr.extend(d),
                ExecEvent::ExitStatus(c) => out.exit_status = Some(c),
            }
        }
        Ok(out)
    }

    /// Starts `cmd` and returns a channel streaming its output as it is produced.
    pub async fn exec_stream(&self, cmd: &str) -> Result<ExecChannel> {
        let mut ch = self.handle.channel_open_session().await?;
        ch.exec(true, cmd.as_bytes().to_vec()).await?;
        await_reply(&mut ch).await?;
        let (read, write) = ch.split();
        Ok(ExecChannel {
            read: Mutex::new(read),
            write,
            closed: CloseFlag::new(),
        })
    }

    /// Whether the session has ended (remote disconnect, keepalive timeout, local disconnect).
    pub fn is_closed(&self) -> bool {
        self.handle.is_closed() || self.closed_rx.borrow().is_some()
    }

    /// Resolves when the session ends and says why. Currently always
    /// [`SshError::Disconnected`].
    pub async fn closed(&self) -> SshError {
        let mut rx = self.closed_rx.clone();
        loop {
            if let Some(e) = rx.borrow_and_update().clone() {
                return e;
            }
            // The sender lives in the connection task's handler; dropping it means it ended.
            if rx.changed().await.is_err() {
                return SshError::Disconnected;
            }
        }
    }

    /// Politely closes the connection.
    pub async fn disconnect(&self) -> Result<()> {
        self.handle
            .disconnect(Disconnect::ByApplication, "", "en")
            .await?;
        Ok(())
    }
}

async fn authenticate(
    handle: &mut client::Handle<ClientHandler>,
    config: &ConnectConfig,
) -> Result<()> {
    let user = config.username.as_str();
    let mut tried = Vec::new();
    for method in &config.auth {
        tried.push(method.name().to_string());
        let step = match method {
            AuthMethod::Password(pw) => {
                let r = handle.authenticate_password(user, pw.as_str()).await?;
                step_of(r.success())
            }
            AuthMethod::PublicKey(key) => {
                let hash = handle.best_supported_rsa_hash().await?.flatten();
                let r = handle
                    .authenticate_publickey(user, PrivateKeyWithHashAlg::new(key.clone(), hash))
                    .await?;
                step_of(r.success())
            }
            AuthMethod::Signer(signer) => {
                let hash = handle.best_supported_rsa_hash().await?.flatten();
                let mut adapter = SignerAdapter(signer.clone());
                match handle
                    .authenticate_publickey_with(user, signer.public_key(), hash, &mut adapter)
                    .await
                {
                    Ok(r) => step_of(r.success()),
                    Err(SignFailure::Send) => return Err(SshError::Disconnected),
                    // The auth conversation is stuck waiting for a signature; give up.
                    Err(SignFailure::Signer) => AuthStep::Abort,
                }
            }
            AuthMethod::KeyboardInteractive(p) => step_of(kbd_interactive(handle, user, p).await?),
        };
        match step {
            AuthStep::Authenticated => return Ok(()),
            AuthStep::Rejected => {}
            AuthStep::Abort => break,
        }
    }
    Err(SshError::AuthFailed {
        tried_methods: tried,
    })
}

fn step_of(ok: bool) -> AuthStep {
    if ok {
        AuthStep::Authenticated
    } else {
        AuthStep::Rejected
    }
}

async fn kbd_interactive(
    handle: &mut client::Handle<ClientHandler>,
    user: &str,
    prompter: &Arc<dyn KbdInteractivePrompter>,
) -> Result<bool> {
    use client::KeyboardInteractiveAuthResponse as R;
    let mut resp = handle
        .authenticate_keyboard_interactive_start(user, None)
        .await?;
    for _ in 0..MAX_KBD_ROUNDS {
        match resp {
            R::Success => return Ok(true),
            R::Failure { .. } => return Ok(false),
            R::InfoRequest {
                name,
                instructions,
                prompts,
            } => {
                let prompts: Vec<KbdPrompt> = prompts
                    .into_iter()
                    .map(|p| KbdPrompt {
                        prompt: p.prompt,
                        echo: p.echo,
                    })
                    .collect();
                let answers = if prompts.is_empty() {
                    Some(Vec::new())
                } else {
                    prompter.respond(&name, &instructions, &prompts).await
                };
                let Some(answers) = answers else {
                    return Ok(false);
                };
                resp = handle
                    .authenticate_keyboard_interactive_respond(answers)
                    .await?;
            }
        }
    }
    Ok(false)
}

/// Waits for the server's reply to a channel request made with `want_reply = true`.
async fn await_reply(ch: &mut russh::Channel<Msg>) -> Result<()> {
    loop {
        match ch.wait().await {
            Some(ChannelMsg::Success) => return Ok(()),
            Some(ChannelMsg::Failure) => {
                return Err(SshError::Protocol(
                    "channel request refused by server".into(),
                ));
            }
            Some(ChannelMsg::Close) | None => return Err(SshError::ChannelClosed),
            Some(_) => {}
        }
    }
}

/// Local "closed" flag that can also interrupt a pending read.
struct CloseFlag(watch::Sender<bool>);

impl CloseFlag {
    fn new() -> Self {
        Self(watch::channel(false).0)
    }

    fn is_set(&self) -> bool {
        *self.0.borrow()
    }

    fn set(&self) {
        self.0.send_replace(true);
    }

    /// Runs `fut`, giving up with `None` as soon as the flag is set.
    async fn guard<T>(&self, fut: impl std::future::Future<Output = T>) -> Option<T> {
        let mut rx = self.0.subscribe();
        tokio::select! {
            v = fut => Some(v),
            _ = rx.wait_for(|c| *c) => None,
        }
    }
}

/// Interactive PTY shell channel. All methods take `&self`.
pub struct ShellChannel {
    read: Mutex<ChannelReadHalf>,
    write: ChannelWriteHalf<Msg>,
    closed: CloseFlag,
}

impl ShellChannel {
    fn check_open(&self) -> Result<()> {
        if self.closed.is_set() {
            Err(SshError::ChannelClosed)
        } else {
            Ok(())
        }
    }

    /// Sends raw input bytes (keystrokes, paste data) to the remote PTY.
    pub async fn write(&self, data: &[u8]) -> Result<()> {
        self.check_open()?;
        self.write
            .data_bytes(data.to_vec())
            .await
            .map_err(|_| SshError::ChannelClosed)
    }

    /// Tells the server the terminal is now `cols` x `rows`.
    pub async fn resize(&self, cols: u32, rows: u32) -> Result<()> {
        self.check_open()?;
        self.write
            .window_change(cols, rows, 0, 0)
            .await
            .map_err(|_| SshError::ChannelClosed)
    }

    /// Next chunk of terminal output (stdout and stderr are merged by the PTY). Returns
    /// `None` once the remote side closes the channel or the session ends.
    pub async fn read(&self) -> Option<Vec<u8>> {
        let mut read = self.read.lock().await;
        loop {
            match self.closed.guard(read.wait()).await?? {
                ChannelMsg::Data { data } | ChannelMsg::ExtendedData { data, .. } => {
                    return Some(data.to_vec());
                }
                ChannelMsg::Eof | ChannelMsg::Close => return None,
                _ => {}
            }
        }
    }

    /// Closes the channel. Pending [`read`](Self::read) calls end with `None`.
    pub async fn close(&self) -> Result<()> {
        self.closed.set();
        self.write
            .close()
            .await
            .map_err(|_| SshError::ChannelClosed)
    }
}

/// Streaming exec channel (long-running commands such as `tmux -C`).
pub struct ExecChannel {
    read: Mutex<ChannelReadHalf>,
    write: ChannelWriteHalf<Msg>,
    closed: CloseFlag,
}

impl ExecChannel {
    /// Next event; `None` once the channel is closed (after the exit status, if any).
    pub async fn next(&self) -> Option<ExecEvent> {
        let mut read = self.read.lock().await;
        loop {
            match self.closed.guard(read.wait()).await?? {
                ChannelMsg::Data { data } => return Some(ExecEvent::Stdout(data.to_vec())),
                ChannelMsg::ExtendedData { data, .. } => {
                    return Some(ExecEvent::Stderr(data.to_vec()));
                }
                ChannelMsg::ExitStatus { exit_status } => {
                    return Some(ExecEvent::ExitStatus(exit_status));
                }
                ChannelMsg::Close => return None,
                // Keep reading past EOF: the exit status may still follow.
                _ => {}
            }
        }
    }

    /// Writes to the command's stdin.
    pub async fn write_stdin(&self, data: &[u8]) -> Result<()> {
        if self.closed.is_set() {
            return Err(SshError::ChannelClosed);
        }
        self.write
            .data_bytes(data.to_vec())
            .await
            .map_err(|_| SshError::ChannelClosed)
    }

    /// Closes the channel.
    pub async fn close(&self) -> Result<()> {
        self.closed.set();
        self.write
            .close()
            .await
            .map_err(|_| SshError::ChannelClosed)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn public_types_are_send_sync() {
        fn check<T: Send + Sync>() {}
        check::<Session>();
        check::<ShellChannel>();
        check::<ExecChannel>();
        check::<SshError>();
        check::<ConnectConfig>();
    }
}
