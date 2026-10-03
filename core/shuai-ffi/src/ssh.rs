//! SSH session/stream API.
//!
//! Every open [`ShellStream`] / [`ExecStream`] must be drained continuously with
//! `next_event()` (one task per stream) until it reports `Closed`, otherwise the whole
//! session stalls (see the `shuai-ssh` crate docs). The Swift facade does this.

use std::sync::Arc;
use std::time::Duration;

use shuai_ssh::keys::PublicKey;
use shuai_ssh::{
    AuthMethod, ConnectConfig, HostKeyVerifier, KbdInteractivePrompter, KbdPrompt, PtyRequest,
    Session, SshError, SshSigner,
};

use crate::keys::parse_public;

// ---------- errors ----------

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error, uniffi::Error)]
pub enum FfiSshError {
    #[error("connect failed: {message}")]
    Connect { message: String },
    #[error("timed out")]
    Timeout,
    #[error("authentication failed (tried: {tried_methods:?})")]
    AuthFailed { tried_methods: Vec<String> },
    #[error("host key rejected")]
    HostKeyRejected,
    #[error("channel closed")]
    ChannelClosed,
    #[error("disconnected")]
    Disconnected,
    #[error("protocol error: {message}")]
    Protocol { message: String },
    #[error("unsupported: {message}")]
    Unsupported { message: String },
    /// A configured private key / signer public key could not be parsed.
    #[error("invalid key: {message}")]
    InvalidKey { message: String },
}

impl From<SshError> for FfiSshError {
    fn from(e: SshError) -> Self {
        match e {
            SshError::Connect(message) => Self::Connect { message },
            SshError::Timeout => Self::Timeout,
            SshError::AuthFailed { tried_methods } => Self::AuthFailed { tried_methods },
            SshError::HostKeyRejected => Self::HostKeyRejected,
            SshError::ChannelClosed => Self::ChannelClosed,
            SshError::Disconnected => Self::Disconnected,
            SshError::Protocol(message) => Self::Protocol { message },
            SshError::Unsupported(message) => Self::Unsupported { message },
        }
    }
}

// ---------- foreign (Swift) callbacks ----------

/// Decides whether to trust a server host key. Async so the platform can ask the user.
#[uniffi::export(with_foreign)]
#[async_trait::async_trait]
pub trait HostKeyVerifierCallback: Send + Sync {
    /// `public_key_line` is the server key as an `authorized_keys`-style line.
    async fn verify(&self, host: String, port: u16, public_key_line: String) -> bool;
}

/// Signs userauth challenges with a key that never leaves the platform (Secure Enclave...).
#[uniffi::export(with_foreign)]
pub trait SignerCallback: Send + Sync {
    fn public_key_line(&self) -> String;
    /// Returns the SSH signature blob (`string(alg) || string(sig)`), or `None` on
    /// failure/cancellation. May block (biometric prompt).
    fn sign(&self, data: Vec<u8>) -> Option<Vec<u8>>;
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FfiKbdPrompt {
    pub prompt: String,
    pub echo: bool,
}

/// Answers keyboard-interactive (OTP/2FA) prompts.
#[uniffi::export(with_foreign)]
#[async_trait::async_trait]
pub trait KbdPrompterCallback: Send + Sync {
    /// One answer per prompt, or `None` to abandon the method.
    async fn respond(
        &self,
        name: String,
        instructions: String,
        prompts: Vec<FfiKbdPrompt>,
    ) -> Option<Vec<String>>;
}

struct VerifierAdapter(Arc<dyn HostKeyVerifierCallback>);

#[async_trait::async_trait]
impl HostKeyVerifier for VerifierAdapter {
    async fn verify(&self, host: &str, port: u16, key: &PublicKey) -> bool {
        self.0
            .verify(
                host.to_string(),
                port,
                shuai_keys::authorized_keys_line(key),
            )
            .await
    }
}

struct SignerAdapter {
    cb: Arc<dyn SignerCallback>,
    key: PublicKey,
}

impl SshSigner for SignerAdapter {
    fn public_key(&self) -> PublicKey {
        self.key.clone()
    }
    fn sign(&self, data: &[u8]) -> shuai_ssh::Result<Vec<u8>> {
        self.cb
            .sign(data.to_vec())
            .ok_or_else(|| SshError::Protocol("signer failed or was cancelled".into()))
    }
}

struct PrompterAdapter(Arc<dyn KbdPrompterCallback>);

#[async_trait::async_trait]
impl KbdInteractivePrompter for PrompterAdapter {
    async fn respond(
        &self,
        name: &str,
        instructions: &str,
        prompts: &[KbdPrompt],
    ) -> Option<Vec<String>> {
        self.0
            .respond(
                name.to_string(),
                instructions.to_string(),
                prompts
                    .iter()
                    .map(|p| FfiKbdPrompt {
                        prompt: p.prompt.clone(),
                        echo: p.echo,
                    })
                    .collect(),
            )
            .await
    }
}

// ---------- config ----------

#[derive(Clone, uniffi::Enum)]
pub enum FfiAuth {
    Password {
        password: String,
    },
    /// Unencrypted OpenSSH PEM (as produced by `generate_key` / `import_key`).
    PrivateKeyPem {
        pem: String,
    },
    Signer {
        signer: Arc<dyn SignerCallback>,
    },
    KeyboardInteractive {
        prompter: Arc<dyn KbdPrompterCallback>,
    },
}

#[derive(Clone, uniffi::Record)]
pub struct FfiConnectConfig {
    pub host: String,
    pub port: u16,
    pub username: String,
    /// Tried in order.
    pub auth: Vec<FfiAuth>,
    /// Keepalive interval; 0 disables keepalives.
    pub keepalive_secs: u32,
    pub connect_timeout_secs: u32,
    /// Budget for the whole auth phase (includes time spent in prompt/signer callbacks).
    pub auth_timeout_secs: u32,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FfiEnvVar {
    pub name: String,
    pub value: String,
}

fn to_config(c: FfiConnectConfig) -> Result<ConnectConfig, FfiSshError> {
    let mut out = ConnectConfig::new(c.host, c.username);
    out.port = c.port;
    for a in c.auth {
        out.auth.push(match a {
            FfiAuth::Password { password } => AuthMethod::Password(password),
            FfiAuth::PrivateKeyPem { pem } => {
                let key = shuai_keys::import_private_key(&pem, None).map_err(|e| {
                    FfiSshError::InvalidKey {
                        message: e.to_string(),
                    }
                })?;
                AuthMethod::PublicKey(Arc::new(key))
            }
            FfiAuth::Signer { signer } => {
                let key = parse_public(&signer.public_key_line()).map_err(|e| {
                    FfiSshError::InvalidKey {
                        message: e.to_string(),
                    }
                })?;
                AuthMethod::Signer(Arc::new(SignerAdapter { cb: signer, key }))
            }
            FfiAuth::KeyboardInteractive { prompter } => {
                AuthMethod::KeyboardInteractive(Arc::new(PrompterAdapter(prompter)))
            }
        });
    }
    out.keepalive_interval = Duration::from_secs(c.keepalive_secs.max(1) as u64);
    if c.keepalive_secs == 0 {
        out.keepalive_max = 0;
    }
    out.connect_timeout = Duration::from_secs(c.connect_timeout_secs as u64);
    out.auth_timeout = Duration::from_secs(c.auth_timeout_secs as u64);
    Ok(out)
}

// ---------- events ----------

/// Why a channel or the session ended.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum CloseReason {
    /// The server closed it / sent a disconnect.
    Remote,
    /// This side closed it.
    Local,
    KeepaliveTimeout,
    RemoteDisconnect,
    Io,
    Protocol,
}

impl From<shuai_ssh::CloseReason> for CloseReason {
    fn from(r: shuai_ssh::CloseReason) -> Self {
        use shuai_ssh::{CloseReason as C, SessionLostKind as K};
        match r {
            C::Remote => Self::Remote,
            C::Local => Self::Local,
            C::SessionLost(K::KeepaliveTimeout) => Self::KeepaliveTimeout,
            C::SessionLost(K::RemoteDisconnect) => Self::RemoteDisconnect,
            C::SessionLost(K::Io) => Self::Io,
            C::SessionLost(K::Protocol) => Self::Protocol,
            // Future variants: treat as an I/O loss so callers reconnect.
            _ => Self::Io,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum ShellEvent {
    /// Terminal output; chunk boundaries are arbitrary (may split UTF-8 sequences).
    Data { bytes: Vec<u8> },
    Exit {
        status: Option<u32>,
        signal: Option<String>,
    },
    /// Terminal event, repeated by every later call.
    Closed { reason: CloseReason },
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum ExecEvent {
    Stdout {
        bytes: Vec<u8>,
    },
    Stderr {
        bytes: Vec<u8>,
    },
    ExitStatus {
        status: u32,
    },
    ExitSignal {
        signal: String,
    },
    /// Terminal event, repeated by every later call.
    Closed {
        reason: CloseReason,
    },
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ExecResult {
    pub stdout: Vec<u8>,
    pub stderr: Vec<u8>,
    pub exit_status: Option<u32>,
    pub exit_signal: Option<String>,
}

// ---------- objects ----------

#[derive(uniffi::Object)]
pub struct ShellStream {
    inner: shuai_ssh::ShellChannel,
}

#[uniffi::export(async_runtime = "tokio")]
impl ShellStream {
    pub async fn next_event(&self) -> ShellEvent {
        use shuai_ssh::ShellEvent as E;
        match self.inner.read().await {
            E::Data(bytes) => ShellEvent::Data { bytes },
            E::Exit { status, signal } => ShellEvent::Exit { status, signal },
            E::Closed(r) => ShellEvent::Closed { reason: r.into() },
            _ => ShellEvent::Closed {
                reason: CloseReason::Protocol,
            },
        }
    }

    pub async fn write(&self, data: Vec<u8>) -> Result<(), FfiSshError> {
        Ok(self.inner.write(&data).await?)
    }

    pub async fn resize(&self, cols: u32, rows: u32) -> Result<(), FfiSshError> {
        Ok(self.inner.resize(cols, rows).await?)
    }

    pub async fn close(&self) -> Result<(), FfiSshError> {
        Ok(self.inner.close().await?)
    }
}

#[derive(uniffi::Object)]
pub struct ExecStream {
    inner: shuai_ssh::ExecChannel,
}

fn map_exec_event(e: shuai_ssh::ExecEvent) -> ExecEvent {
    use shuai_ssh::ExecEvent as E;
    match e {
        E::Stdout(bytes) => ExecEvent::Stdout { bytes },
        E::Stderr(bytes) => ExecEvent::Stderr { bytes },
        E::ExitStatus(status) => ExecEvent::ExitStatus { status },
        E::ExitSignal(signal) => ExecEvent::ExitSignal { signal },
        E::Closed(r) => ExecEvent::Closed { reason: r.into() },
        _ => ExecEvent::Closed {
            reason: CloseReason::Protocol,
        },
    }
}

#[uniffi::export(async_runtime = "tokio")]
impl ExecStream {
    pub async fn next_event(&self) -> ExecEvent {
        map_exec_event(self.inner.next().await)
    }

    pub async fn write_stdin(&self, data: Vec<u8>) -> Result<(), FfiSshError> {
        Ok(self.inner.write_stdin(&data).await?)
    }

    pub async fn eof(&self) -> Result<(), FfiSshError> {
        Ok(self.inner.eof().await?)
    }

    pub async fn close(&self) -> Result<(), FfiSshError> {
        Ok(self.inner.close().await?)
    }
}

#[derive(uniffi::Object)]
pub struct SshConnection {
    session: Session,
}

const UPLOAD_CHUNK: usize = 32 * 1024;

/// The shell command used by [`SshConnection::upload`]: `cat > PATH && chmod MODE PATH`
/// (`mode` printed in octal). shuai-ssh has no SFTP yet, so uploads are streamed through an
/// exec channel's stdin.
#[uniffi::export]
pub fn upload_command(remote_path: String, mode: u32) -> String {
    let p = shuai_tmux::quote::shell_quote(&remote_path);
    format!("cat > {p} && chmod {mode:o} {p}")
}

#[uniffi::export(async_runtime = "tokio")]
impl SshConnection {
    /// Connects, verifies the host key through `host_key_verifier`, authenticates.
    #[uniffi::constructor]
    pub async fn connect(
        config: FfiConnectConfig,
        host_key_verifier: Arc<dyn HostKeyVerifierCallback>,
    ) -> Result<Arc<Self>, FfiSshError> {
        let cfg = to_config(config)?;
        let session = Session::connect(cfg, Arc::new(VerifierAdapter(host_key_verifier))).await?;
        Ok(Arc::new(Self { session }))
    }

    pub async fn open_shell(
        &self,
        cols: u32,
        rows: u32,
        term: String,
        env: Vec<FfiEnvVar>,
    ) -> Result<Arc<ShellStream>, FfiSshError> {
        let pty = PtyRequest {
            term,
            cols,
            rows,
            env: env.into_iter().map(|e| (e.name, e.value)).collect(),
        };
        let inner = self.session.open_shell(pty).await?;
        Ok(Arc::new(ShellStream { inner }))
    }

    /// Runs `cmd` to completion and collects its output.
    pub async fn exec(&self, cmd: String) -> Result<ExecResult, FfiSshError> {
        let o = self.session.exec(&cmd).await?;
        Ok(ExecResult {
            stdout: o.stdout,
            stderr: o.stderr,
            exit_status: o.exit_status,
            exit_signal: o.exit_signal,
        })
    }

    pub async fn exec_stream(&self, cmd: String) -> Result<Arc<ExecStream>, FfiSshError> {
        let inner = self.session.exec_stream(&cmd).await?;
        Ok(Arc::new(ExecStream { inner }))
    }

    /// Resolves when the session ends, with the reason.
    pub async fn closed(&self) -> CloseReason {
        self.session.closed().await.into()
    }

    pub async fn disconnect(&self) -> Result<(), FfiSshError> {
        Ok(self.session.disconnect().await?)
    }

    /// Uploads `data` to `remote_path` with permissions `mode` (see [`upload_command`]).
    pub async fn upload(
        &self,
        data: Vec<u8>,
        remote_path: String,
        mode: u32,
    ) -> Result<(), FfiSshError> {
        use shuai_ssh::ExecEvent as E;
        let ch = self
            .session
            .exec_stream(&upload_command(remote_path, mode))
            .await?;
        for chunk in data.chunks(UPLOAD_CHUNK) {
            ch.write_stdin(chunk).await?;
        }
        ch.eof().await?;
        let (mut status, mut signal, mut stderr) = (None, None, Vec::new());
        loop {
            match ch.next().await {
                E::Stderr(b) => stderr.extend(b),
                E::ExitStatus(s) => status = Some(s),
                E::ExitSignal(s) => signal = Some(s),
                E::Closed(_) => break,
                _ => {}
            }
        }
        if status == Some(0) {
            return Ok(());
        }
        let detail = String::from_utf8_lossy(&stderr).trim().to_string();
        Err(FfiSshError::Protocol {
            message: format!("upload failed (status {status:?}, signal {signal:?}): {detail}"),
        })
    }
}
