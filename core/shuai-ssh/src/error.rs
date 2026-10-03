//! Error type for the SSH client.

use crate::reconnect::FailureKind;

/// Errors surfaced by this crate. All variants are cheap to clone and `Send + Sync`.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum SshError {
    /// TCP connect or transport failure.
    #[error("connect failed: {0}")]
    Connect(String),
    /// Connect or handshake exceeded `connect_timeout`.
    #[error("timed out")]
    Timeout,
    /// Every configured authentication method was rejected (or none were configured).
    #[error("authentication failed (tried: {tried_methods:?})")]
    AuthFailed {
        /// Names of the methods attempted, in order (`password`, `publickey`, `signer`,
        /// `keyboard-interactive`).
        tried_methods: Vec<String>,
    },
    /// The [`HostKeyVerifier`](crate::HostKeyVerifier) rejected the server key.
    #[error("host key rejected")]
    HostKeyRejected,
    /// The channel was closed (by either side) before the operation completed.
    #[error("channel closed")]
    ChannelClosed,
    /// The session is gone (remote disconnect, keepalive timeout, local disconnect).
    #[error("disconnected")]
    Disconnected,
    /// Protocol violation or any other SSH-level error.
    #[error("protocol error: {0}")]
    Protocol(String),
    /// The requested feature is not available.
    #[error("unsupported: {0}")]
    Unsupported(String),
}

impl From<&SshError> for FailureKind {
    fn from(e: &SshError) -> Self {
        match e {
            SshError::Connect(_) => FailureKind::Network,
            SshError::Timeout => FailureKind::Timeout,
            SshError::AuthFailed { .. } => FailureKind::AuthFailed,
            SshError::HostKeyRejected => FailureKind::HostKeyRejected,
            _ => FailureKind::Other,
        }
    }
}

impl From<russh::Error> for SshError {
    fn from(e: russh::Error) -> Self {
        match e {
            russh::Error::IO(e) => SshError::Connect(e.to_string()),
            russh::Error::SendError
            | russh::Error::RecvError
            | russh::Error::Disconnect
            | russh::Error::HUP
            | russh::Error::KeepaliveTimeout
            | russh::Error::InactivityTimeout => SshError::Disconnected,
            other => SshError::Protocol(other.to_string()),
        }
    }
}

/// Convenience alias.
pub type Result<T, E = SshError> = std::result::Result<T, E>;
