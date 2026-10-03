//! shuai-ssh: async SSH client built on russh, with a pure reconnect policy.
//!
//! Public key types are those of `russh::keys` (re-exported as [`keys`]) so that other crates
//! can hand over `PrivateKey` / `PublicKey` values directly.

pub mod config;
pub mod error;
pub mod reconnect;
pub mod session;

pub use config::{
    AuthMethod, ConnectConfig, HostKeyVerifier, KbdInteractivePrompter, KbdPrompt, PtyRequest,
    SshSigner,
};
pub use error::{Result, SshError};
pub use russh::keys;
pub use session::{ExecChannel, ExecEvent, ExecOutput, Session, ShellChannel};
