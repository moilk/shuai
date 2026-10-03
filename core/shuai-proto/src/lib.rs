//! Shared protocol types between the app and shuai-agent.

/// Wire protocol version shared by the app and shuai-agent.
pub const PROTOCOL_VERSION: u32 = 1;

/// Crate version.
pub fn version() -> &'static str {
    env!("CARGO_PKG_VERSION")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn version_matches_cargo_pkg() {
        assert_eq!(version(), env!("CARGO_PKG_VERSION"));
    }

    #[test]
    fn protocol_version_is_one() {
        assert_eq!(PROTOCOL_VERSION, 1);
    }
}
