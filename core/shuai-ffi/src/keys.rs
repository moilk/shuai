//! Key generation/import and known_hosts trust checks.

use shuai_keys::{KeyAlgorithm, KeyError, KnownHosts, PrivateKey, PublicKey};

/// Key algorithms that can be generated.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum KeyAlg {
    Ed25519,
    EcdsaP256,
    /// Only if shuai-keys is built with `rsa-generate`; otherwise `Unsupported`.
    Rsa,
}

/// A key pair as stored by the platform: the private half is an unencrypted OpenSSH PEM
/// (the platform keeps it in the Keychain).
#[derive(Clone, PartialEq, Eq, uniffi::Record)]
pub struct KeyMaterial {
    pub private_pem: String,
    /// `authorized_keys` line (`ssh-ed25519 AAAA... comment`).
    pub public_line: String,
    /// `SHA256:...`
    pub fingerprint: String,
    /// SSH algorithm name, e.g. `ssh-ed25519`.
    pub algorithm: String,
}

// Hand-written so the private PEM can never reach logs, panics or `dbg!` output.
impl std::fmt::Debug for KeyMaterial {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("KeyMaterial")
            .field("private_pem", &"<redacted>")
            .field("public_line", &self.public_line)
            .field("fingerprint", &self.fingerprint)
            .field("algorithm", &self.algorithm)
            .finish()
    }
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct PublicInfo {
    pub public_line: String,
    pub fingerprint: String,
    pub randomart: String,
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error, uniffi::Error)]
pub enum FfiKeyError {
    #[error("key is encrypted and needs a passphrase")]
    NeedsPassphrase,
    #[error("wrong passphrase")]
    WrongPassphrase,
    #[error("unsupported: {message}")]
    Unsupported { message: String },
    #[error("malformed key")]
    Malformed,
}

impl From<KeyError> for FfiKeyError {
    fn from(e: KeyError) -> Self {
        match e {
            KeyError::NeedsPassphrase => Self::NeedsPassphrase,
            KeyError::WrongPassphrase => Self::WrongPassphrase,
            KeyError::Unsupported(message) => Self::Unsupported { message },
            KeyError::Malformed => Self::Malformed,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum FfiHostKeyStatus {
    Trusted,
    Unknown,
    Mismatch { expected_fingerprints: Vec<String> },
    Revoked,
}

fn material(key: &PrivateKey) -> Result<KeyMaterial, FfiKeyError> {
    Ok(KeyMaterial {
        private_pem: shuai_keys::export_private_key(key, None)?,
        public_line: shuai_keys::authorized_keys_line(key.public_key()),
        fingerprint: shuai_keys::fingerprint(key.public_key()),
        algorithm: key.algorithm().as_str().to_string(),
    })
}

pub(crate) fn parse_public(line: &str) -> Result<PublicKey, FfiKeyError> {
    PublicKey::from_openssh(line.trim()).map_err(|_| FfiKeyError::Malformed)
}

#[uniffi::export]
pub fn generate_key(alg: KeyAlg, comment: String) -> Result<KeyMaterial, FfiKeyError> {
    let alg = match alg {
        KeyAlg::Ed25519 => KeyAlgorithm::Ed25519,
        KeyAlg::EcdsaP256 => KeyAlgorithm::EcdsaP256,
        KeyAlg::Rsa => KeyAlgorithm::Rsa,
    };
    material(&shuai_keys::generate(alg, &comment)?)
}

/// Imports any supported private-key format (OpenSSH, PKCS#1/#8, SEC1, encrypted or not)
/// and normalises it to an unencrypted OpenSSH PEM.
#[uniffi::export]
pub fn import_key(
    pem_bytes: Vec<u8>,
    passphrase: Option<String>,
) -> Result<KeyMaterial, FfiKeyError> {
    let pem = String::from_utf8(pem_bytes).map_err(|_| FfiKeyError::Malformed)?;
    material(&shuai_keys::import_private_key(
        &pem,
        passphrase.as_deref(),
    )?)
}

#[uniffi::export]
pub fn public_info(private_pem: String) -> Result<PublicInfo, FfiKeyError> {
    let key = shuai_keys::import_private_key(&private_pem, None)?;
    let public = key.public_key();
    Ok(PublicInfo {
        public_line: shuai_keys::authorized_keys_line(public),
        fingerprint: shuai_keys::fingerprint(public),
        randomart: shuai_keys::randomart(public),
    })
}

/// `SHA256:...` fingerprint of an `authorized_keys`-style public key line.
#[uniffi::export]
pub fn public_key_fingerprint(public_key_line: String) -> Result<String, FfiKeyError> {
    Ok(shuai_keys::fingerprint(&parse_public(&public_key_line)?))
}

#[uniffi::export]
pub fn known_hosts_check(
    text: String,
    host: String,
    port: u16,
    public_key_line: String,
) -> Result<FfiHostKeyStatus, FfiKeyError> {
    let key = parse_public(&public_key_line)?;
    Ok(match KnownHosts::parse(&text).check(&host, port, &key) {
        shuai_keys::HostKeyStatus::Trusted => FfiHostKeyStatus::Trusted,
        shuai_keys::HostKeyStatus::Unknown => FfiHostKeyStatus::Unknown,
        shuai_keys::HostKeyStatus::Mismatch {
            expected_fingerprints,
        } => FfiHostKeyStatus::Mismatch {
            expected_fingerprints,
        },
        shuai_keys::HostKeyStatus::Revoked => FfiHostKeyStatus::Revoked,
    })
}

/// Returns the new full `known_hosts` text with an entry for `host:port` appended.
#[uniffi::export]
pub fn known_hosts_add(
    text: String,
    host: String,
    port: u16,
    public_key_line: String,
    hashed: bool,
) -> Result<String, FfiKeyError> {
    let key = parse_public(&public_key_line)?;
    let mut kh = KnownHosts::parse(&text);
    kh.add(&host, port, &key, hashed);
    Ok(kh.to_text())
}
