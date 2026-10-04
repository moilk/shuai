//! UniFFI export layer.
//!
//! Conventions (see core/CLAUDE.md): coarse session/stream-level API only; data crosses as
//! records/enums (`#[derive(uniffi::Record/Enum)]`), stateful things as objects; errors are
//! flat per-domain enums (`FfiKeyError`, `FfiSshError`, `FfiTmuxError`); platform
//! integrations are `with_foreign` callback traits. Logic lives in the pure crates.

uniffi::setup_scaffolding!();

mod agent;
mod keys;
mod reconnect;
mod ssh;
#[cfg(feature = "testkit")]
mod testkit;
mod tmux;

pub use agent::*;
pub use keys::*;
pub use reconnect::*;
pub use ssh::*;
#[cfg(feature = "testkit")]
pub use testkit::*;
pub use tmux::*;

#[uniffi::export]
pub fn ping() -> String {
    "pong".to_string()
}

#[uniffi::export]
pub fn core_version() -> String {
    shuai_proto::version().to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ping_returns_pong() {
        assert_eq!(ping(), "pong");
    }

    #[test]
    fn core_version_delegates_to_proto() {
        assert_eq!(core_version(), shuai_proto::version());
    }
}
