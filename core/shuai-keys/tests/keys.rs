use proptest::prelude::*;
use shuai_keys::*;
use std::fs;
use std::path::PathBuf;

fn fx(name: &str) -> String {
    let p = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixtures")
        .join(name);
    fs::read_to_string(&p).unwrap_or_else(|e| panic!("{}: {e}", p.display()))
}

/// Expected fingerprint as captured from `ssh-keygen -lf` for the key with this comment.
fn expected_fp(comment: &str) -> String {
    for line in fx("fingerprints.txt").lines() {
        let parts: Vec<&str> = line.split_whitespace().collect();
        if parts[2] == comment {
            return parts[1].to_string();
        }
    }
    panic!("no fingerprint for {comment}");
}

const PASS: &str = "shuai-test-pass";

#[test]
fn generate_ed25519() {
    let k = generate(KeyAlgorithm::Ed25519, "me@ipad").unwrap();
    assert_eq!(k.algorithm().as_str(), "ssh-ed25519");
    assert_eq!(k.comment().as_str().unwrap(), "me@ipad");
}

#[test]
fn generate_ecdsa_p256() {
    let k = generate(KeyAlgorithm::EcdsaP256, "c").unwrap();
    assert_eq!(k.algorithm().as_str(), "ecdsa-sha2-nistp256");
}

#[cfg(feature = "rsa-generate")]
#[test]
fn generate_rsa() {
    let k = generate(KeyAlgorithm::Rsa, "c").unwrap();
    assert_eq!(k.algorithm().as_str(), "ssh-rsa");
}

#[cfg(not(feature = "rsa-generate"))]
#[test]
fn generate_rsa_unsupported_without_feature() {
    assert!(matches!(
        generate(KeyAlgorithm::Rsa, "c"),
        Err(KeyError::Unsupported(_))
    ));
}

#[test]
fn generated_keys_are_distinct() {
    let a = generate(KeyAlgorithm::Ed25519, "").unwrap();
    let b = generate(KeyAlgorithm::Ed25519, "").unwrap();
    assert_ne!(a.public_key().key_data(), b.public_key().key_data());
}

#[test]
fn import_plain_ed25519_matches_ssh_keygen_fingerprint() {
    let k = import_private_key(&fx("test_ed25519_plain"), None).unwrap();
    assert_eq!(
        fingerprint(k.public_key()),
        expected_fp("shuai-test-ed25519")
    );
}

#[test]
fn import_plain_ecdsa_and_rsa_match_fingerprints() {
    let k = import_private_key(&fx("test_ecdsa_plain"), None).unwrap();
    assert_eq!(fingerprint(k.public_key()), expected_fp("shuai-test-ecdsa"));
    let k = import_private_key(&fx("test_rsa_plain"), None).unwrap();
    assert_eq!(fingerprint(k.public_key()), expected_fp("shuai-test-rsa"));
}

#[test]
fn import_encrypted_ed25519_with_passphrase() {
    let k = import_private_key(&fx("test_ed25519_enc"), Some(PASS)).unwrap();
    assert_eq!(
        fingerprint(k.public_key()),
        expected_fp("shuai-test-ed25519-enc")
    );
}

#[test]
fn import_encrypted_ecdsa_and_rsa() {
    let k = import_private_key(&fx("test_ecdsa_enc"), Some(PASS)).unwrap();
    assert_eq!(
        fingerprint(k.public_key()),
        expected_fp("shuai-test-ecdsa-enc")
    );
    let k = import_private_key(&fx("test_rsa_enc"), Some(PASS)).unwrap();
    assert_eq!(
        fingerprint(k.public_key()),
        expected_fp("shuai-test-rsa-enc")
    );
}

#[test]
fn encrypted_without_passphrase_needs_passphrase() {
    assert_eq!(
        import_private_key(&fx("test_ed25519_enc"), None).unwrap_err(),
        KeyError::NeedsPassphrase
    );
}

#[test]
fn encrypted_with_wrong_passphrase() {
    assert_eq!(
        import_private_key(&fx("test_ed25519_enc"), Some("nope")).unwrap_err(),
        KeyError::WrongPassphrase
    );
}

#[test]
fn passphrase_on_plain_key_is_ignored() {
    assert!(import_private_key(&fx("test_ed25519_plain"), Some("x")).is_ok());
}

#[test]
fn garbage_is_malformed() {
    for s in [
        "",
        "hello",
        "-----BEGIN OPENSSH PRIVATE KEY-----\nAAAA\n-----END OPENSSH PRIVATE KEY-----\n",
    ] {
        assert_eq!(
            import_private_key(s, None).unwrap_err(),
            KeyError::Malformed,
            "{s:?}"
        );
    }
}

#[test]
fn legacy_rsa_pem_is_unsupported_not_panic() {
    assert!(matches!(
        import_private_key(&fx("test_rsa_legacy_pem"), None),
        Err(KeyError::Unsupported(_))
    ));
}

#[test]
fn pkcs8_is_unsupported_not_panic() {
    assert!(matches!(
        import_private_key(&fx("test_ed25519_pkcs8"), None),
        Err(KeyError::Unsupported(_))
    ));
}

proptest! {
    #[test]
    fn random_bytes_never_panic(bytes in proptest::collection::vec(any::<u8>(), 0..512)) {
        let s = String::from_utf8_lossy(&bytes).into_owned();
        let _ = import_private_key(&s, None);
        let _ = import_private_key(&s, Some("p"));
    }

    #[test]
    fn mutated_pem_never_panics(idx in 0usize..400, byte in any::<u8>()) {
        let mut b = fx("test_ed25519_enc").into_bytes();
        let i = idx % b.len();
        b[i] = byte;
        let s = String::from_utf8_lossy(&b).into_owned();
        let _ = import_private_key(&s, Some(PASS));
        let _ = import_private_key(&s, None);
    }
}

#[test]
fn export_unencrypted_roundtrip() {
    let k = generate(KeyAlgorithm::Ed25519, "rt").unwrap();
    let pem = export_private_key(&k, None).unwrap();
    assert!(pem.starts_with("-----BEGIN OPENSSH PRIVATE KEY-----"));
    let k2 = import_private_key(&pem, None).unwrap();
    assert_eq!(k.public_key().key_data(), k2.public_key().key_data());
    assert_eq!(k2.comment().as_str().unwrap(), "rt");
}

#[test]
fn export_encrypted_roundtrip() {
    let k = generate(KeyAlgorithm::EcdsaP256, "rt").unwrap();
    let pem = export_private_key(&k, Some("secret")).unwrap();
    assert_eq!(
        import_private_key(&pem, None).unwrap_err(),
        KeyError::NeedsPassphrase
    );
    assert_eq!(
        import_private_key(&pem, Some("bad")).unwrap_err(),
        KeyError::WrongPassphrase
    );
    let k2 = import_private_key(&pem, Some("secret")).unwrap();
    assert_eq!(k.public_key().key_data(), k2.public_key().key_data());
}

#[test]
fn export_encrypted_is_readable_by_ssh_keygen() {
    // Uses real ssh-keygen when present: `ssh-keygen -y -P secret -f key` must print the public key.
    let dir = env!("CARGO_TARGET_TMPDIR");
    let k = generate(KeyAlgorithm::Ed25519, "x").unwrap();
    let pem = export_private_key(&k, Some("secret")).unwrap();
    let path = PathBuf::from(dir).join("exported_enc_key");
    fs::write(&path, pem).unwrap();
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).unwrap();
    }
    let Ok(out) = std::process::Command::new("ssh-keygen")
        .args(["-y", "-P", "secret", "-f"])
        .arg(&path)
        .output()
    else {
        return;
    };
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    let printed = String::from_utf8(out.stdout).unwrap();
    assert!(
        printed.starts_with(
            &authorized_keys_line(k.public_key())
                .rsplit_once(' ')
                .unwrap()
                .0
                .to_string()
        )
    );
}

#[test]
fn authorized_keys_line_matches_pub_fixture() {
    for n in ["test_ed25519_plain", "test_ecdsa_plain", "test_rsa_plain"] {
        let k = import_private_key(&fx(n), None).unwrap();
        assert_eq!(
            authorized_keys_line(k.public_key()),
            fx(&format!("{n}.pub")).trim()
        );
    }
}

#[test]
fn fingerprint_has_openssh_format() {
    let k = generate(KeyAlgorithm::Ed25519, "").unwrap();
    let f = fingerprint(k.public_key());
    assert!(f.starts_with("SHA256:"));
    assert_eq!(f.len(), 7 + 43); // unpadded base64 of 32 bytes
}

#[test]
fn randomart_has_box_shape() {
    let k = import_private_key(&fx("test_ed25519_plain"), None).unwrap();
    let art = randomart(k.public_key());
    let lines: Vec<&str> = art.lines().collect();
    assert_eq!(lines.len(), 11);
    assert!(lines[0].starts_with("+--[ED25519 256]"));
    assert_eq!(lines[10], "+----[SHA256]-----+");
    assert!(lines.iter().all(|l| l.chars().count() == 19));
}
