//! UniFFI export layer (thin).

uniffi::setup_scaffolding!();

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
