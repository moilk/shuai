use crate::KeyError;
#[cfg(feature = "rsa-generate")]
use ssh_key::private::{KeypairData, RsaKeypair};
use ssh_key::{Algorithm, EcdsaCurve, HashAlg, LineEnding, PrivateKey, PublicKey};

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
///
/// [`KeyAlgorithm::Rsa`] returns [`KeyError::Unsupported`] unless the
/// `rsa-generate` feature is enabled.
pub fn generate(alg: KeyAlgorithm, comment: &str) -> Result<PrivateKey, KeyError> {
    let mut rng = rand::rng();
    let mut key = match alg {
        KeyAlgorithm::Ed25519 => PrivateKey::random(&mut rng, Algorithm::Ed25519),
        KeyAlgorithm::EcdsaP256 => PrivateKey::random(
            &mut rng,
            Algorithm::Ecdsa {
                curve: EcdsaCurve::NistP256,
            },
        ),
        #[cfg(feature = "rsa-generate")]
        KeyAlgorithm::Rsa => RsaKeypair::random(&mut rng, 3072)
            .and_then(|kp| PrivateKey::new(KeypairData::from(kp), "")),
        #[cfg(not(feature = "rsa-generate"))]
        KeyAlgorithm::Rsa => {
            return Err(KeyError::Unsupported(
                "RSA generation is disabled (enable the `rsa-generate` feature)".into(),
            ));
        }
    }
    .map_err(|e| KeyError::Unsupported(e.to_string()))?;
    key.set_comment(comment);
    Ok(key)
}

/// PEM headers of formats we recognise but do not import.
const UNSUPPORTED_PEM: &[(&str, &str)] = &[
    (
        "-----BEGIN RSA PRIVATE KEY-----",
        "legacy PEM RSA key; convert with `ssh-keygen -p -m RFC4716` or re-export as OpenSSH",
    ),
    ("-----BEGIN EC PRIVATE KEY-----", "legacy PEM EC key"),
    ("-----BEGIN DSA PRIVATE KEY-----", "DSA keys"),
    ("-----BEGIN PRIVATE KEY-----", "PKCS#8 keys"),
    (
        "-----BEGIN ENCRYPTED PRIVATE KEY-----",
        "encrypted PKCS#8 keys",
    ),
    ("PuTTY-User-Key-File", "PuTTY .ppk keys"),
];

/// Upper bound on bcrypt-pbkdf rounds accepted on import (`ssh-keygen -a` defaults to 16).
const MAX_BCRYPT_ROUNDS: u32 = 1024;

/// Parses an OpenSSH private key from PEM text, decrypting with `passphrase` if needed.
///
/// A passphrase supplied for an unencrypted key is ignored. Legacy PEM and PKCS#8 keys yield
/// [`KeyError::Unsupported`]. Never panics on arbitrary input.
pub fn import_private_key(pem: &str, passphrase: Option<&str>) -> Result<PrivateKey, KeyError> {
    let trimmed = pem.trim_start();
    for (header, what) in UNSUPPORTED_PEM {
        if trimmed.starts_with(header) {
            return Err(KeyError::Unsupported((*what).to_string()));
        }
    }
    let key = PrivateKey::from_openssh(pem).map_err(|e| match e {
        ssh_key::Error::AlgorithmUnsupported { algorithm } => {
            KeyError::Unsupported(format!("algorithm {algorithm}"))
        }
        ssh_key::Error::AlgorithmUnknown => KeyError::Unsupported("unknown algorithm".into()),
        _ => KeyError::Malformed,
    })?;
    if !key.is_encrypted() {
        return Ok(key);
    }
    let pass = passphrase.ok_or(KeyError::NeedsPassphrase)?;
    // A hostile key file could request billions of bcrypt rounds and hang the app.
    if let ssh_key::Kdf::Bcrypt { rounds, .. } = key.kdf() {
        if *rounds > MAX_BCRYPT_ROUNDS {
            return Err(KeyError::Unsupported(format!(
                "bcrypt-pbkdf rounds {rounds} exceeds limit {MAX_BCRYPT_ROUNDS}"
            )));
        }
    }
    key.decrypt(pass).map_err(|e| match e {
        ssh_key::Error::AlgorithmUnsupported { algorithm } => {
            KeyError::Unsupported(format!("algorithm {algorithm}"))
        }
        ssh_key::Error::AlgorithmUnknown => KeyError::Unsupported("unknown algorithm".into()),
        // A wrong passphrase surfaces as a failed check-int / padding / decode error.
        _ => KeyError::WrongPassphrase,
    })
}

/// Serializes a private key as OpenSSH PEM, encrypted (aes256-ctr + bcrypt-pbkdf) if a
/// non-empty passphrase is given. An already-encrypted key is exported as-is.
pub fn export_private_key(key: &PrivateKey, passphrase: Option<&str>) -> Result<String, KeyError> {
    let pem_of = |k: &PrivateKey| {
        k.to_openssh(LineEnding::LF)
            .map(|z| z.to_string())
            .map_err(|e| KeyError::Unsupported(e.to_string()))
    };
    match passphrase.filter(|p| !p.is_empty()) {
        Some(p) if !key.is_encrypted() => {
            let enc = key
                .encrypt(&mut rand::rng(), p)
                .map_err(|e| KeyError::Unsupported(e.to_string()))?;
            pem_of(&enc)
        }
        _ => pem_of(key),
    }
}

/// `authorized_keys` line: `ssh-ed25519 AAAA... comment` (no trailing newline).
pub fn authorized_keys_line(key: &PublicKey) -> String {
    // Encoding a well-formed in-memory key cannot fail.
    key.to_openssh().unwrap_or_default()
}

/// OpenSSH SHA256 fingerprint, `SHA256:...` (unpadded base64), as printed by `ssh-keygen -l`.
pub fn fingerprint(key: &PublicKey) -> String {
    key.fingerprint(HashAlg::Sha256).to_string()
}

/// OpenSSH randomart image for the SHA256 fingerprint, as printed by `ssh-keygen -lv`.
pub fn randomart(key: &PublicKey) -> String {
    let header = key.algorithm().as_str().to_string();
    let bits = key_bits(key);
    let header = format!("[{} {}]", header_name(&header), bits);
    key.fingerprint(HashAlg::Sha256).to_randomart(&header)
}

fn header_name(alg: &str) -> &'static str {
    match alg {
        "ssh-ed25519" => "ED25519",
        "ssh-rsa" => "RSA",
        a if a.starts_with("ecdsa-") => "ECDSA",
        _ => "KEY",
    }
}

fn key_bits(key: &PublicKey) -> usize {
    use ssh_key::public::KeyData;
    match key.key_data() {
        KeyData::Ed25519(_) => 256,
        KeyData::Ecdsa(k) => match k {
            ssh_key::public::EcdsaPublicKey::NistP256(_) => 256,
            ssh_key::public::EcdsaPublicKey::NistP384(_) => 384,
            ssh_key::public::EcdsaPublicKey::NistP521(_) => 521,
        },
        KeyData::Rsa(k) => k.key_size() as usize,
        _ => 0,
    }
}
