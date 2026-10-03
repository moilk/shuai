//! Connection configuration and the callback traits the platform layer implements.

use std::sync::Arc;
use std::time::Duration;

use russh::keys::{PrivateKey, PublicKey};

use crate::error::Result;

/// Decides whether a server host key is trusted (TOFU / known_hosts lives behind this).
///
/// Called once per handshake, before authentication. Returning `false` aborts the connection
/// with [`SshError::HostKeyRejected`](crate::SshError::HostKeyRejected).
#[async_trait::async_trait]
pub trait HostKeyVerifier: Send + Sync {
    /// `host`/`port` are the values from [`ConnectConfig`]; `key` is the server's public key.
    async fn verify(&self, host: &str, port: u16, key: &PublicKey) -> bool;
}

/// Signs SSH userauth challenges with a key whose private half this crate never sees
/// (e.g. a Secure Enclave key behind a platform callback).
pub trait SshSigner: Send + Sync {
    /// The public key to offer to the server.
    fn public_key(&self) -> PublicKey;

    /// Signs `data` (the userauth signing payload) and returns the SSH signature blob,
    /// i.e. `string(algorithm-name) || string(signature-bytes)` as in RFC 4253 section 6.6.
    ///
    /// May block (for example while waiting on a biometric prompt); it is invoked on a
    /// blocking-capable thread.
    fn sign(&self, data: &[u8]) -> Result<Vec<u8>>;
}

/// One prompt of a keyboard-interactive round.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct KbdPrompt {
    /// Prompt text.
    pub prompt: String,
    /// Whether the answer may be echoed while typing.
    pub echo: bool,
}

/// Answers keyboard-interactive (e.g. OTP / 2FA) prompts.
#[async_trait::async_trait]
pub trait KbdInteractivePrompter: Send + Sync {
    /// Returns one answer per prompt, or `None` to abandon this method.
    async fn respond(
        &self,
        name: &str,
        instructions: &str,
        prompts: &[KbdPrompt],
    ) -> Option<Vec<String>>;
}

/// One authentication method; [`ConnectConfig::auth`] is tried in order.
#[derive(Clone)]
pub enum AuthMethod {
    /// Plain password.
    Password(String),
    /// In-memory private key.
    PublicKey(Arc<PrivateKey>),
    /// Externally held key (Secure Enclave, hardware token...).
    Signer(Arc<dyn SshSigner>),
    /// Keyboard-interactive challenge/response.
    KeyboardInteractive(Arc<dyn KbdInteractivePrompter>),
}

impl AuthMethod {
    /// Stable name used in [`SshError::AuthFailed`](crate::SshError::AuthFailed).
    pub fn name(&self) -> &'static str {
        match self {
            AuthMethod::Password(_) => "password",
            AuthMethod::PublicKey(_) => "publickey",
            AuthMethod::Signer(_) => "signer",
            AuthMethod::KeyboardInteractive(_) => "keyboard-interactive",
        }
    }
}

impl std::fmt::Debug for AuthMethod {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        // Never print secrets.
        f.write_str(self.name())
    }
}

/// Everything needed to open a [`Session`](crate::Session).
#[derive(Debug, Clone)]
pub struct ConnectConfig {
    /// Server host name or IP.
    pub host: String,
    /// Server port.
    pub port: u16,
    /// Remote user name.
    pub username: String,
    /// Methods to try, in order.
    pub auth: Vec<AuthMethod>,
    /// Interval between `keepalive@openssh.com` probes.
    pub keepalive_interval: Duration,
    /// Number of unanswered probes tolerated before the session is declared dead.
    pub keepalive_max: u32,
    /// Budget for TCP connect plus SSH handshake (not authentication).
    pub connect_timeout: Duration,
}

impl ConnectConfig {
    /// Config with sensible defaults (port 22, 15 s keepalive x 3, 10 s connect timeout).
    pub fn new(host: impl Into<String>, username: impl Into<String>) -> Self {
        Self {
            host: host.into(),
            port: 22,
            username: username.into(),
            auth: Vec::new(),
            keepalive_interval: Duration::from_secs(15),
            keepalive_max: 3,
            connect_timeout: Duration::from_secs(10),
        }
    }
}

/// Parameters of the pseudo-terminal requested for a shell.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PtyRequest {
    /// `$TERM` value.
    pub term: String,
    /// Columns.
    pub cols: u32,
    /// Rows.
    pub rows: u32,
    /// Environment variables to request (servers may ignore them).
    pub env: Vec<(String, String)>,
}

impl PtyRequest {
    /// `xterm-256color` with `COLORTERM=truecolor`.
    pub fn xterm(cols: u32, rows: u32) -> Self {
        Self {
            term: "xterm-256color".into(),
            cols,
            rows,
            env: vec![("COLORTERM".into(), "truecolor".into())],
        }
    }
}
