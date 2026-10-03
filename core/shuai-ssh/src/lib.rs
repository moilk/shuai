//! shuai-ssh: async SSH client built on russh, with a pure reconnect policy.
//!
//! Public key types are those of `russh::keys` (re-exported as [`keys`]) so that other crates
//! can hand over `PrivateKey` / `PublicKey` values directly.
//!
//! # Every open channel must be drained
//!
//! All channels of a [`Session`] share one connection task. russh buffers incoming channel
//! data in a bounded per-channel queue; once a channel's queue is full the connection task
//! blocks on it, which stalls **every** channel of the session, including keepalive
//! handling (the session then looks dead and is torn down). Therefore every open
//! [`ShellChannel`] and [`ExecChannel`] must be read continuously
//! ([`ShellChannel::read`] / [`ExecChannel::next`], typically one dedicated task per channel)
//! until it reports `Closed`, even if the application does not care about its output, and
//! reading must not wait on slow consumers (buffer or drop data instead). Dropping a channel
//! closes it remotely.
//!
//! # Ending
//!
//! Channel streams end with an explicit `Closed(`[`CloseReason`]`)` event, and
//! [`Session::closed`] reports why the whole session ended, so callers can tell a clean exit
//! from a lost connection.

#![warn(missing_docs)]

pub mod config;
pub mod error;
pub mod reconnect;
pub mod session;

pub use config::{
    AuthMethod, ConnectConfig, HostKeyVerifier, KbdInteractivePrompter, KbdPrompt,
    PasswordPrompter, PtyRequest, SshSigner,
};
pub use error::{Result, SshError};
pub use russh::keys;
pub use session::{
    CloseReason, ExecChannel, ExecEvent, ExecOutput, Session, SessionLostKind, ShellChannel,
    ShellEvent,
};
