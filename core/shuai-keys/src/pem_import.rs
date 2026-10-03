//! Import of non-OpenSSH private key formats: PKCS#1 (`RSA PRIVATE KEY`, incl. legacy
//! OpenSSL `Proc-Type`/`DEK-Info` encryption), PKCS#8 (`PRIVATE KEY`, `ENCRYPTED PRIVATE KEY`)
//! and SEC1 (`EC PRIVATE KEY`). Everything is converted into an [`ssh_key::PrivateKey`].

use crate::KeyError;
use base64::Engine;
use base64::engine::general_purpose::STANDARD as B64;
use cbc::cipher::block_padding::Pkcs7;
use cbc::cipher::{BlockModeDecrypt, KeyIvInit};
use p256::elliptic_curve::sec1::ToSec1Point;
use pkcs8::DecodePrivateKey;
use pkcs8::pkcs5::pbes2::Kdf;
use rsa::pkcs1::DecodeRsaPrivateKey;
use ssh_key::PrivateKey;
use ssh_key::private::{EcdsaKeypair, EcdsaPrivateKey, Ed25519Keypair, KeypairData, RsaKeypair};
use zeroize::Zeroizing;

/// Upper bound on PBKDF2 iterations in encrypted PKCS#8 (OpenSSL defaults to 2048..600k).
const MAX_PBKDF2_ITERATIONS: u32 = 10_000_000;
/// Upper bound on scrypt `N * r` (memory is about `128 * N * r` bytes, i.e. 256 MiB).
const MAX_SCRYPT_N_TIMES_R: u64 = 1 << 21;

const OID_RSA: &str = "1.2.840.113549.1.1.1";
const OID_ED25519: &str = "1.3.101.112";
const OID_EC: &str = "1.2.840.10045.2.1";
const OID_P256: &str = "1.2.840.10045.3.1.7";
const OID_P384: &str = "1.3.132.0.34";

/// A decoded PEM block.
struct Pem {
    label: String,
    /// `Proc-Type`/`DEK-Info` style RFC 1421 headers, as `(name, value)`.
    headers: Vec<(String, String)>,
    der: Zeroizing<Vec<u8>>,
}

/// PEM labels handled by [`import`].
pub(crate) fn handles(text: &str) -> bool {
    [
        "RSA PRIVATE KEY",
        "EC PRIVATE KEY",
        "PRIVATE KEY",
        "ENCRYPTED PRIVATE KEY",
    ]
    .iter()
    .any(|l| {
        text.trim_start()
            .starts_with(&format!("-----BEGIN {l}-----"))
    })
}

fn parse_pem(text: &str) -> Option<Pem> {
    let mut lines = text.lines().map(str::trim).filter(|l| !l.is_empty());
    let label = lines
        .next()?
        .strip_prefix("-----BEGIN ")?
        .strip_suffix("-----")?
        .to_string();
    let end = format!("-----END {label}-----");
    let mut headers = Vec::new();
    let mut body = Zeroizing::new(String::new());
    let mut in_headers = true;
    let mut terminated = false;
    for l in lines {
        if l == end {
            terminated = true;
            break;
        }
        if in_headers && l.contains(':') {
            let (k, v) = l.split_once(':')?;
            headers.push((k.trim().to_string(), v.trim().to_string()));
            continue;
        }
        in_headers = false;
        body.push_str(l);
    }
    if !terminated {
        return None;
    }
    let der = Zeroizing::new(B64.decode(body.as_bytes()).ok()?);
    Some(Pem {
        label,
        headers,
        der,
    })
}

/// Imports a PKCS#1 / PKCS#8 / SEC1 PEM key. Call only when [`handles`] returned true.
pub(crate) fn import(text: &str, passphrase: Option<&str>) -> Result<PrivateKey, KeyError> {
    let pem = parse_pem(text).ok_or(KeyError::Malformed)?;
    // Defence in depth: third-party parsers must not take the app down on hostile input.
    let res = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        import_pem(&pem, passphrase)
    }));
    res.unwrap_or(Err(KeyError::Malformed))
}

fn import_pem(pem: &Pem, passphrase: Option<&str>) -> Result<PrivateKey, KeyError> {
    let dek = pem
        .headers
        .iter()
        .find(|(k, _)| k.eq_ignore_ascii_case("DEK-Info"))
        .map(|(_, v)| v.as_str());
    let encrypted_legacy = pem
        .headers
        .iter()
        .any(|(k, v)| k.eq_ignore_ascii_case("Proc-Type") && v.contains("ENCRYPTED"));
    let der: Zeroizing<Vec<u8>> = if encrypted_legacy || dek.is_some() {
        let pass = passphrase.ok_or(KeyError::NeedsPassphrase)?;
        legacy_decrypt(dek.ok_or(KeyError::Malformed)?, &pem.der, pass)?
    } else {
        Zeroizing::new(pem.der.to_vec())
    };
    let decrypted = encrypted_legacy || dek.is_some();
    // After a legacy decryption, a structurally invalid result means a wrong passphrase.
    let bad = |e: KeyError| {
        if decrypted {
            KeyError::WrongPassphrase
        } else {
            e
        }
    };
    match pem.label.as_str() {
        "RSA PRIVATE KEY" => rsa_from_pkcs1(&der).map_err(bad),
        "EC PRIVATE KEY" => ec_from_sec1(&der).map_err(bad),
        "PRIVATE KEY" => from_pkcs8(&der),
        "ENCRYPTED PRIVATE KEY" => {
            let pass = passphrase.ok_or(KeyError::NeedsPassphrase)?;
            let doc = pkcs8_decrypt(&der, pass)?;
            from_pkcs8(doc.as_bytes())
        }
        _ => Err(KeyError::Malformed),
    }
}

fn build(kd: KeypairData) -> Result<PrivateKey, KeyError> {
    PrivateKey::new(kd, "").map_err(|e| KeyError::Unsupported(e.to_string()))
}

fn rsa_to_key(k: &rsa::RsaPrivateKey) -> Result<PrivateKey, KeyError> {
    let kp = RsaKeypair::try_from(k).map_err(|_| KeyError::Malformed)?;
    build(KeypairData::from(kp))
}

fn rsa_from_pkcs1(der: &[u8]) -> Result<PrivateKey, KeyError> {
    let k = rsa::RsaPrivateKey::from_pkcs1_der(der).map_err(|_| KeyError::Malformed)?;
    rsa_to_key(&k)
}

fn p256_to_key(sk: &p256::SecretKey) -> Result<PrivateKey, KeyError> {
    build(KeypairData::Ecdsa(EcdsaKeypair::NistP256 {
        public: sk.public_key().to_sec1_point(false),
        private: EcdsaPrivateKey::from(sk.clone()),
    }))
}

fn p384_to_key(sk: &p384::SecretKey) -> Result<PrivateKey, KeyError> {
    build(KeypairData::Ecdsa(EcdsaKeypair::NistP384 {
        public: sk.public_key().to_sec1_point(false),
        private: EcdsaPrivateKey::from(sk.clone()),
    }))
}

fn ec_from_sec1(der: &[u8]) -> Result<PrivateKey, KeyError> {
    if let Ok(sk) = p256::SecretKey::from_sec1_der(der) {
        return p256_to_key(&sk);
    }
    if let Ok(sk) = p384::SecretKey::from_sec1_der(der) {
        return p384_to_key(&sk);
    }
    // Structurally valid SEC1 on another curve (e.g. P-521) is not imported.
    Err(KeyError::Malformed)
}

fn from_pkcs8(der: &[u8]) -> Result<PrivateKey, KeyError> {
    let info = pkcs8::PrivateKeyInfoRef::try_from(der).map_err(|_| KeyError::Malformed)?;
    let oid = info.algorithm.oid.to_string();
    match oid.as_str() {
        OID_RSA => {
            let k = rsa::RsaPrivateKey::from_pkcs8_der(der).map_err(|_| KeyError::Malformed)?;
            rsa_to_key(&k)
        }
        OID_ED25519 => {
            let k =
                ed25519_dalek::SigningKey::from_pkcs8_der(der).map_err(|_| KeyError::Malformed)?;
            build(KeypairData::Ed25519(Ed25519Keypair::from(&k)))
        }
        OID_EC => {
            let curve = info
                .algorithm
                .parameters_oid()
                .map_err(|_| KeyError::Malformed)?
                .to_string();
            match curve.as_str() {
                OID_P256 => p256_to_key(
                    &p256::SecretKey::from_pkcs8_der(der).map_err(|_| KeyError::Malformed)?,
                ),
                OID_P384 => p384_to_key(
                    &p384::SecretKey::from_pkcs8_der(der).map_err(|_| KeyError::Malformed)?,
                ),
                other => Err(KeyError::Unsupported(format!("EC curve {other}"))),
            }
        }
        other => Err(KeyError::Unsupported(format!("PKCS#8 algorithm {other}"))),
    }
}

fn pkcs8_decrypt(der: &[u8], pass: &str) -> Result<pkcs8::SecretDocument, KeyError> {
    let info = pkcs8::EncryptedPrivateKeyInfoRef::try_from(der).map_err(|_| KeyError::Malformed)?;
    // Refuse KDF parameters that would hang or crash the app (hostile key files).
    if let Some(p) = info.encryption_algorithm.pbes2() {
        match &p.kdf {
            Kdf::Pbkdf2(k)
                if k.iteration_count == 0 || k.iteration_count > MAX_PBKDF2_ITERATIONS =>
            {
                return Err(KeyError::Unsupported(format!(
                    "PBKDF2 iterations {} out of range",
                    k.iteration_count
                )));
            }
            Kdf::Scrypt(k)
                if !k.cost_parameter.is_power_of_two()
                    || k.cost_parameter < 2
                    || k.block_size == 0
                    || k.cost_parameter.saturating_mul(u64::from(k.block_size))
                        > MAX_SCRYPT_N_TIMES_R =>
            {
                return Err(KeyError::Unsupported(
                    "scrypt parameters out of range".into(),
                ));
            }
            _ => {}
        }
    }
    info.decrypt(pass).map_err(|e| {
        let msg = e.to_string().to_ascii_lowercase();
        if msg.contains("unsupported") || msg.contains("algorithm") {
            KeyError::Unsupported(e.to_string())
        } else {
            KeyError::WrongPassphrase
        }
    })
}

/// OpenSSL `EVP_BytesToKey(MD5, salt = iv[..8], count = 1)`.
fn evp_bytes_to_key(pass: &[u8], salt: &[u8], len: usize) -> Zeroizing<Vec<u8>> {
    let mut out = Zeroizing::new(Vec::with_capacity(len + 16));
    let mut prev: Zeroizing<Vec<u8>> = Zeroizing::new(Vec::new());
    while out.len() < len {
        let mut ctx = md5::Context::new();
        ctx.consume(&prev);
        ctx.consume(pass);
        ctx.consume(salt);
        prev = Zeroizing::new(ctx.finalize().0.to_vec());
        out.extend_from_slice(&prev);
    }
    out.truncate(len);
    out
}

fn legacy_decrypt(dek: &str, data: &[u8], pass: &str) -> Result<Zeroizing<Vec<u8>>, KeyError> {
    let (alg, iv_hex) = dek.split_once(',').ok_or(KeyError::Malformed)?;
    let iv = hex_decode(iv_hex.trim()).ok_or(KeyError::Malformed)?;
    if iv.len() < 8 {
        return Err(KeyError::Malformed);
    }
    let alg = alg.trim().to_ascii_uppercase();
    let key_len = match alg.as_str() {
        "AES-128-CBC" => 16,
        "AES-192-CBC" => 24,
        "AES-256-CBC" => 32,
        "DES-EDE3-CBC" => 24,
        other => return Err(KeyError::Unsupported(format!("PEM cipher {other}"))),
    };
    let key = evp_bytes_to_key(pass.as_bytes(), &iv[..8], key_len);
    let mut buf = Zeroizing::new(data.to_vec());
    let bad_len = || KeyError::Malformed;
    macro_rules! dec {
        ($c:ty) => {{
            let d = cbc::Decryptor::<$c>::new_from_slices(&key, &iv).map_err(|_| bad_len())?;
            let n = d
                .decrypt_padded::<Pkcs7>(&mut buf)
                .map_err(|_| KeyError::WrongPassphrase)?
                .len();
            n
        }};
    }
    if iv.len() != if alg == "DES-EDE3-CBC" { 8 } else { 16 } {
        return Err(KeyError::Malformed);
    }
    let n = match alg.as_str() {
        "AES-128-CBC" => dec!(aes::Aes128),
        "AES-192-CBC" => dec!(aes::Aes192),
        "AES-256-CBC" => dec!(aes::Aes256),
        _ => dec!(des::TdesEde3),
    };
    buf.truncate(n);
    Ok(buf)
}

fn hex_decode(s: &str) -> Option<Vec<u8>> {
    if !s.len().is_multiple_of(2) || !s.is_ascii() {
        return None;
    }
    (0..s.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&s[i..i + 2], 16).ok())
        .collect()
}
