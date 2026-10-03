use ssh_key::PublicKey;

/// Result of checking a host key against a [`KnownHosts`] list.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum HostKeyStatus {
    /// The presented key matches a recorded key for this host.
    Trusted,
    /// No entry for this host (trust-on-first-use decision needed).
    Unknown,
    /// The host has recorded keys but none equals the presented one.
    Mismatch {
        /// SHA256 fingerprints of the keys recorded for this host.
        expected_fingerprints: Vec<String>,
    },
    /// The presented key is marked `@revoked`.
    Revoked,
}

/// An OpenSSH `known_hosts` file held as text.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct KnownHosts {
    lines: Vec<String>,
}

impl KnownHosts {
    /// Parses `known_hosts` text. Never fails; unparseable lines are skipped when checking
    /// but preserved by [`KnownHosts::to_text`].
    pub fn parse(_text: &str) -> Self {
        unimplemented!()
    }

    /// Serializes back to `known_hosts` text.
    pub fn to_text(&self) -> String {
        unimplemented!()
    }

    /// Checks the key presented by `host:port`.
    pub fn check(&self, _host: &str, _port: u16, _key: &PublicKey) -> HostKeyStatus {
        unimplemented!()
    }

    /// Appends an entry (see [`add_entry`]) and returns the line added.
    pub fn add(&mut self, _host: &str, _port: u16, _key: &PublicKey, _hashed: bool) -> String {
        unimplemented!()
    }
}

/// Builds a `known_hosts` line (no trailing newline) for `host:port`.
pub fn add_entry(_host: &str, _port: u16, _key: &PublicKey, _hashed: bool) -> String {
    unimplemented!()
}
