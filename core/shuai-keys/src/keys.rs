use crate::KeyError;
use ssh_key::{PrivateKey, PublicKey};

/// Algorithms for which [`generate`] can create keys.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum KeyAlgorithm {
    /// `ssh-ed25519`.
    Ed25519,
    /// `ecdsa-sha2-nistp256`.
    EcdsaP256,
    /// `ssh-rsa` (3072 bits); requires the `rsa-generate` feature.
    Rsa,
}

/// Generates a new key pair with the given comment.
pub fn generate(_alg: KeyAlgorithm, _comment: &str) -> Result<PrivateKey, KeyError> {
    unimplemented!()
}

/// Parses a private key from PEM text, decrypting with `passphrase` if needed.
pub fn import_private_key(_pem: &str, _passphrase: Option<&str>) -> Result<PrivateKey, KeyError> {
    unimplemented!()
}

/// Serializes a private key as OpenSSH PEM, encrypted (aes256-ctr + bcrypt-pbkdf) if a passphrase is given.
pub fn export_private_key(
    _key: &PrivateKey,
    _passphrase: Option<&str>,
) -> Result<String, KeyError> {
    unimplemented!()
}

/// `authorized_keys` line: `ssh-ed25519 AAAA... comment`.
pub fn authorized_keys_line(_key: &PublicKey) -> String {
    unimplemented!()
}

/// OpenSSH SHA256 fingerprint, `SHA256:...`.
pub fn fingerprint(_key: &PublicKey) -> String {
    unimplemented!()
}

/// OpenSSH randomart image for the SHA256 fingerprint.
pub fn randomart(_key: &PublicKey) -> String {
    unimplemented!()
}
