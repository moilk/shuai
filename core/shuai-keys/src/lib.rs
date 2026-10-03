//! Key handling for shuai: generation, OpenSSH import/export, fingerprints and
//! `known_hosts` trust logic. Pure Rust, no I/O; callers pass text in and store text out.
//!
//! Types are those of the `ssh-key` crate, pinned to the exact version that
//! `russh` re-exports as `russh::keys::ssh_key`, so keys can be handed to russh directly.

mod error;
mod keys;
mod known_hosts;

pub use error::KeyError;
pub use keys::{
    KeyAlgorithm, authorized_keys_line, export_private_key, fingerprint, generate,
    import_private_key, randomart,
};
pub use known_hosts::{HostKeyStatus, KnownHosts, add_entry};
pub use ssh_key;
pub use ssh_key::{PrivateKey, PublicKey};
