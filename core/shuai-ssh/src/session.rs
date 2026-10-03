//! Client session, PTY shell and exec channels.

use std::ops::Deref;
use std::sync::Arc;
use std::sync::OnceLock;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

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
    /// Name of the signal (without `SIG`, e.g. `KILL`) that terminated the command, if any.
    pub exit_signal: Option<String>,
}

/// Why a channel or session ended.
///
/// Lets callers tell an orderly end (show the exit status, prompt to reopen) from a dead
/// connection (trigger a reconnect).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[non_exhaustive]
pub enum CloseReason {
    /// The server ended it deliberately: the channel was closed by the peer, or (for
    /// [`Session::closed`]) the server sent an SSH disconnect message.
    Remote,
    /// This side closed the channel or disconnected the session.
    Local,
    /// The session died underneath the channel.
    SessionLost(SessionLostKind),
}

/// How a session was lost.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[non_exhaustive]
pub enum SessionLostKind {
    /// More than `keepalive_max` consecutive keepalive probes went unanswered.
    KeepaliveTimeout,
    /// The server sent an SSH disconnect message (seen from a channel's point of view;
    /// [`Session::closed`] itself reports this as [`CloseReason::Remote`]).
    RemoteDisconnect,
    /// The transport broke (reset, EOF, send/receive failure).
    Io,
    /// A protocol error ended the session.
    Protocol,
}

/// One event from an [`ExecChannel`]. The stream always ends with exactly one
/// [`ExecEvent::Closed`], which is then returned by every later call.
#[derive(Debug, Clone, PartialEq, Eq)]
#[non_exhaustive]
pub enum ExecEvent {
    /// Bytes on stdout.
    Stdout(Vec<u8>),
    /// Bytes on stderr.
    Stderr(Vec<u8>),
    /// The remote command exited with this status.
    ExitStatus(u32),
    /// The remote command was terminated by this signal (name without `SIG`, e.g. `KILL`).
    ExitSignal(String),
    /// Terminal event: the channel ended for this reason.
    Closed(CloseReason),
}

/// One event from a [`ShellChannel`]. The stream always ends with exactly one
/// [`ShellEvent::Closed`], which is then returned by every later call.
#[derive(Debug, Clone, PartialEq, Eq)]
#[non_exhaustive]
pub enum ShellEvent {
    /// Terminal output bytes (stdout and stderr are merged by the PTY). Chunk boundaries are
    /// arbitrary: a multi-byte UTF-8 sequence may be split across chunks.
    Data(Vec<u8>),
    /// The remote shell exited. Either field (or neither) may be set: `status` for a normal
    /// exit, `signal` (name without `SIG`, e.g. `KILL`) if it was killed.
    Exit {
        /// Exit status, if reported.
        status: Option<u32>,
        /// Terminating signal, if any.
        signal: Option<String>,
    },
    /// Terminal event: the channel ended for this reason.
    Closed(CloseReason),
}

/// Maximum keyboard-interactive rounds before the method is considered failed.
const MAX_KBD_ROUNDS: usize = 8;

struct ClientHandler {
    verifier: Arc<dyn HostKeyVerifier>,
    host: String,
    port: u16,
    rejected: Arc<AtomicBool>,
    closed_tx: watch::Sender<Option<CloseReason>>,
    local_disconnect: Arc<AtomicBool>,
}

/// Records the first close reason; later ones are ignored.
fn set_once(tx: &watch::Sender<Option<CloseReason>>, reason: CloseReason) {
    tx.send_if_modified(|cur| {
        if cur.is_none() {
            *cur = Some(reason);
            true
        } else {
            false
        }
    });
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
        let local = self.local_disconnect.load(Ordering::SeqCst);
        let why = match &reason {
            _ if local => CloseReason::Local,
            client::DisconnectReason::ReceivedDisconnect(_) => CloseReason::Remote,
            client::DisconnectReason::Error(russh::Error::KeepaliveTimeout) => {
                CloseReason::SessionLost(SessionLostKind::KeepaliveTimeout)
            }
            client::DisconnectReason::Error(
                russh::Error::IO(_)
                | russh::Error::HUP
                | russh::Error::SendError
                | russh::Error::RecvError
                | russh::Error::Disconnect,
            ) => CloseReason::SessionLost(SessionLostKind::Io),
            client::DisconnectReason::Error(_) => {
                CloseReason::SessionLost(SessionLostKind::Protocol)
            }
        };
        set_once(&self.closed_tx, why);
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
    closed_tx: watch::Sender<Option<CloseReason>>,
    closed_rx: watch::Receiver<Option<CloseReason>>,
    local_disconnect: Arc<AtomicBool>,
}

impl Session {
    /// Connects, verifies the host key via `verifier`, and authenticates using the methods in
    /// `config.auth` in order.
    ///
    /// `config.connect_timeout` bounds TCP connect plus the SSH handshake and
    /// `config.auth_timeout` the whole authentication phase. Keepalives
    /// (`keepalive@openssh.com`) start once authenticated: the session is torn down once more
    /// than `keepalive_max` consecutive probes went unanswered (a `keepalive_max` of 0
    /// disables the check); [`Session::closed`] then reports
    /// `SessionLost(KeepaliveTimeout)`.
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
        let local_disconnect = Arc::new(AtomicBool::new(false));
        let handler = ClientHandler {
            verifier,
            host: config.host.clone(),
            port: config.port,
            rejected: rejected.clone(),
            closed_tx: closed_tx.clone(),
            local_disconnect: local_disconnect.clone(),
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

        match tokio::time::timeout(config.auth_timeout, authenticate(&mut handle, &config)).await {
            Err(_) => return Err(SshError::Timeout),
            Ok(r) => r?,
        }
        Ok(Session {
            handle,
            closed_tx,
            closed_rx,
            local_disconnect,
        })
    }

    /// Opens a PTY-backed interactive shell.
    pub async fn open_shell(&self, pty: PtyRequest) -> Result<ShellChannel> {
        let mut ch = self.handle.channel_open_session().await?;
        let setup: Result<()> = async {
            ch.request_pty(true, &pty.term, pty.cols, pty.rows, 0, 0, &[])
                .await?;
            await_reply(&mut ch).await?;
            for (k, v) in &pty.env {
                // Servers commonly refuse unlisted variables; never fail the shell over it.
                ch.set_env(false, k.as_str(), v.as_str()).await?;
            }
            ch.request_shell(true).await?;
            await_reply(&mut ch).await
        }
        .await;
        if let Err(e) = setup {
            let _ = ch.close().await;
            return Err(e);
        }
        let (read, write) = ch.split();
        Ok(ShellChannel {
            read: Mutex::new(read),
            write: Writer::new(write),
            closed: CloseFlag::new(),
            ending: Ending::new(self.closed_rx.clone()),
        })
    }

    /// Runs `cmd` to completion and collects its output and exit status.
    pub async fn exec(&self, cmd: &str) -> Result<ExecOutput> {
        let ch = self.exec_stream(cmd).await?;
        let mut out = ExecOutput::default();
        loop {
            match ch.next().await {
                ExecEvent::Stdout(d) => out.stdout.extend(d),
                ExecEvent::Stderr(d) => out.stderr.extend(d),
                ExecEvent::ExitStatus(c) => out.exit_status = Some(c),
                ExecEvent::ExitSignal(n) => out.exit_signal = Some(n),
                // Only an orderly close by the peer counts as completion; output that merely
                // stopped (session died) must not look like a command that finished.
                ExecEvent::Closed(CloseReason::Remote) => return Ok(out),
                ExecEvent::Closed(_) => return Err(SshError::Disconnected),
            }
        }
    }

    /// Starts `cmd` and returns a channel streaming its output as it is produced.
    pub async fn exec_stream(&self, cmd: &str) -> Result<ExecChannel> {
        let mut ch = self.handle.channel_open_session().await?;
        let setup: Result<()> = async {
            ch.exec(true, cmd.as_bytes().to_vec()).await?;
            await_reply(&mut ch).await
        }
        .await;
        if let Err(e) = setup {
            let _ = ch.close().await;
            return Err(e);
        }
        let (read, write) = ch.split();
        Ok(ExecChannel {
            read: Mutex::new(read),
            write: Writer::new(write),
            closed: CloseFlag::new(),
            ending: Ending::new(self.closed_rx.clone()),
        })
    }

    /// Whether the session has ended (remote disconnect, keepalive timeout, local disconnect).
    pub fn is_closed(&self) -> bool {
        self.handle.is_closed() || self.closed_rx.borrow().is_some()
    }

    /// Resolves when the session ends and says why: [`CloseReason::Local`] after
    /// [`disconnect`](Self::disconnect), [`CloseReason::Remote`] when the server sent a
    /// disconnect message, [`CloseReason::SessionLost`] for keepalive timeouts and transport
    /// or protocol failures.
    pub async fn closed(&self) -> CloseReason {
        wait_session_closed(self.closed_rx.clone()).await
    }

    /// Politely closes the connection.
    pub async fn disconnect(&self) -> Result<()> {
        self.local_disconnect.store(true, Ordering::SeqCst);
        set_once(&self.closed_tx, CloseReason::Local);
        self.handle
            .disconnect(Disconnect::ByApplication, "", "en")
            .await?;
        Ok(())
    }
}

async fn wait_session_closed(mut rx: watch::Receiver<Option<CloseReason>>) -> CloseReason {
    loop {
        if let Some(r) = *rx.borrow_and_update() {
            return r;
        }
        // The sender lives in the connection task's handler; dropping it means it ended.
        if rx.changed().await.is_err() {
            return rx
                .borrow()
                .unwrap_or(CloseReason::SessionLost(SessionLostKind::Io));
        }
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

/// The first reason a channel ended; sticky.
struct Ending {
    reason: OnceLock<CloseReason>,
    session: watch::Receiver<Option<CloseReason>>,
}

impl Ending {
    fn new(session: watch::Receiver<Option<CloseReason>>) -> Self {
        Self {
            reason: OnceLock::new(),
            session,
        }
    }

    fn get(&self) -> Option<CloseReason> {
        self.reason.get().copied()
    }

    /// Records `r` unless an earlier reason exists; returns the effective reason.
    fn finish(&self, r: CloseReason) -> CloseReason {
        *self.reason.get_or_init(|| r)
    }

    /// The channel's message stream ended without a `Close`: the session is gone.
    async fn finish_session_lost(&self) -> CloseReason {
        // The connection task records the reason before dropping channel senders, but do not
        // depend on it: bound the wait.
        let why = tokio::time::timeout(
            Duration::from_secs(1),
            wait_session_closed(self.session.clone()),
        )
        .await
        .unwrap_or(CloseReason::SessionLost(SessionLostKind::Io));
        self.finish(match why {
            CloseReason::Remote => CloseReason::SessionLost(SessionLostKind::RemoteDisconnect),
            other => other,
        })
    }
}

/// Write half of a channel that closes the remote channel when dropped without an explicit
/// [`Writer::close`]; otherwise a dropped channel would leave the remote process running.
struct Writer {
    half: Option<ChannelWriteHalf<Msg>>,
    close_sent: AtomicBool,
}

impl Writer {
    fn new(half: ChannelWriteHalf<Msg>) -> Self {
        Self {
            half: Some(half),
            close_sent: AtomicBool::new(false),
        }
    }

    async fn close(&self) -> Result<()> {
        self.close_sent.store(true, Ordering::SeqCst);
        self.half
            .as_ref()
            .expect("present until drop")
            .close()
            .await
            .map_err(|_| SshError::ChannelClosed)
    }
}

impl Deref for Writer {
    type Target = ChannelWriteHalf<Msg>;
    fn deref(&self) -> &Self::Target {
        self.half.as_ref().expect("present until drop")
    }
}

impl Drop for Writer {
    fn drop(&mut self) {
        if self.close_sent.load(Ordering::SeqCst) {
            return;
        }
        if let (Some(half), Ok(rt)) = (self.half.take(), tokio::runtime::Handle::try_current()) {
            rt.spawn(async move {
                let _ = half.close().await;
            });
        }
    }
}

/// Interactive PTY shell channel. All methods take `&self`.
pub struct ShellChannel {
    read: Mutex<ChannelReadHalf>,
    write: Writer,
    closed: CloseFlag,
    ending: Ending,
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

    /// Next event: terminal output, the shell's exit status/signal, and finally
    /// [`ShellEvent::Closed`] with the reason (returned again by every later call).
    ///
    /// Must be called continuously, see the crate-level docs on draining channels.
    pub async fn read(&self) -> ShellEvent {
        if let Some(r) = self.ending.get() {
            return ShellEvent::Closed(r);
        }
        let mut read = self.read.lock().await;
        loop {
            let Some(msg) = self.closed.guard(read.wait()).await else {
                return ShellEvent::Closed(self.ending.finish(CloseReason::Local));
            };
            match msg {
                Some(ChannelMsg::Data { data } | ChannelMsg::ExtendedData { data, .. }) => {
                    return ShellEvent::Data(data.to_vec());
                }
                Some(ChannelMsg::ExitStatus { exit_status }) => {
                    return ShellEvent::Exit {
                        status: Some(exit_status),
                        signal: None,
                    };
                }
                Some(ChannelMsg::ExitSignal { signal_name, .. }) => {
                    return ShellEvent::Exit {
                        status: None,
                        signal: Some(sig_name(signal_name)),
                    };
                }
                Some(ChannelMsg::Close) => {
                    return ShellEvent::Closed(self.ending.finish(CloseReason::Remote));
                }
                // Keep reading past EOF: the exit status may still follow.
                Some(_) => {}
                None => return ShellEvent::Closed(self.ending.finish_session_lost().await),
            }
        }
    }

    /// Closes the channel. Pending [`read`](Self::read) calls end with
    /// `Closed(CloseReason::Local)`.
    pub async fn close(&self) -> Result<()> {
        self.ending.finish(CloseReason::Local);
        self.closed.set();
        self.write.close().await
    }
}

fn sig_name(sig: russh::Sig) -> String {
    match sig {
        russh::Sig::Custom(c) => c,
        other => format!("{other:?}"),
    }
}

/// Streaming exec channel (long-running commands such as `tmux -C`).
pub struct ExecChannel {
    read: Mutex<ChannelReadHalf>,
    write: Writer,
    closed: CloseFlag,
    ending: Ending,
}

impl ExecChannel {
    /// Next event; the stream ends with [`ExecEvent::Closed`] (returned again by every later
    /// call), after the exit status if any.
    ///
    /// Must be called continuously, see the crate-level docs on draining channels.
    pub async fn next(&self) -> ExecEvent {
        if let Some(r) = self.ending.get() {
            return ExecEvent::Closed(r);
        }
        let mut read = self.read.lock().await;
        loop {
            let Some(msg) = self.closed.guard(read.wait()).await else {
                return ExecEvent::Closed(self.ending.finish(CloseReason::Local));
            };
            match msg {
                Some(ChannelMsg::Data { data }) => return ExecEvent::Stdout(data.to_vec()),
                Some(ChannelMsg::ExtendedData { data, .. }) => {
                    return ExecEvent::Stderr(data.to_vec());
                }
                Some(ChannelMsg::ExitStatus { exit_status }) => {
                    return ExecEvent::ExitStatus(exit_status);
                }
                Some(ChannelMsg::ExitSignal { signal_name, .. }) => {
                    return ExecEvent::ExitSignal(sig_name(signal_name));
                }
                Some(ChannelMsg::Close) => {
                    return ExecEvent::Closed(self.ending.finish(CloseReason::Remote));
                }
                // Keep reading past EOF: the exit status may still follow.
                Some(_) => {}
                None => return ExecEvent::Closed(self.ending.finish_session_lost().await),
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

    /// Sends EOF on the command's stdin (like closing a pipe) without closing the channel, so
    /// output and the exit status can still be read.
    pub async fn eof(&self) -> Result<()> {
        if self.closed.is_set() {
            return Err(SshError::ChannelClosed);
        }
        self.write.eof().await.map_err(|_| SshError::ChannelClosed)
    }

    /// Closes the channel.
    pub async fn close(&self) -> Result<()> {
        self.ending.finish(CloseReason::Local);
        self.closed.set();
        self.write.close().await
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
