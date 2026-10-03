use shuai_ffi::*;

#[test]
fn generate_ed25519_returns_consistent_material() {
    let k = generate_key(KeyAlg::Ed25519, "me@ipad".into()).unwrap();
    assert!(
        k.private_pem
            .starts_with("-----BEGIN OPENSSH PRIVATE KEY-----")
    );
    assert!(k.public_line.starts_with("ssh-ed25519 "));
    assert!(k.fingerprint.starts_with("SHA256:"));
    assert_eq!(k.algorithm, "ssh-ed25519");
    let info = public_info(k.private_pem.clone()).unwrap();
    assert_eq!(info.public_line, k.public_line);
    assert_eq!(info.fingerprint, k.fingerprint);
    assert!(info.randomart.contains('+'));
}

#[test]
fn generate_ecdsa_p256() {
    let k = generate_key(KeyAlg::EcdsaP256, "x".into()).unwrap();
    assert_eq!(k.algorithm, "ecdsa-sha2-nistp256");
}

#[test]
fn import_round_trips_generated_key_through_bytes() {
    let k = generate_key(KeyAlg::Ed25519, "c".into()).unwrap();
    let imported = import_key(k.private_pem.clone().into_bytes(), None).unwrap();
    assert_eq!(imported.fingerprint, k.fingerprint);
    assert_eq!(imported.public_line, k.public_line);
    assert!(
        imported
            .private_pem
            .starts_with("-----BEGIN OPENSSH PRIVATE KEY-----")
    );
}

#[test]
fn import_garbage_is_malformed() {
    assert_eq!(
        import_key(b"not a key".to_vec(), None).unwrap_err(),
        FfiKeyError::Malformed
    );
    assert_eq!(
        import_key(vec![0xff, 0xfe, 0x00], None).unwrap_err(),
        FfiKeyError::Malformed
    );
}

#[test]
fn import_encrypted_needs_then_accepts_passphrase() {
    let k = generate_key(KeyAlg::Ed25519, "c".into()).unwrap();
    let parsed = shuai_keys::import_private_key(&k.private_pem, None).unwrap();
    let enc = shuai_keys::export_private_key(&parsed, Some("hunter2")).unwrap();
    assert_eq!(
        import_key(enc.clone().into_bytes(), None).unwrap_err(),
        FfiKeyError::NeedsPassphrase
    );
    assert_eq!(
        import_key(enc.clone().into_bytes(), Some("nope".into())).unwrap_err(),
        FfiKeyError::WrongPassphrase
    );
    let ok = import_key(enc.into_bytes(), Some("hunter2".into())).unwrap();
    assert_eq!(ok.fingerprint, k.fingerprint);
    // Normalised output is unencrypted.
    assert!(import_key(ok.private_pem.into_bytes(), None).is_ok());
}

#[test]
fn public_info_rejects_garbage() {
    assert_eq!(
        public_info("zzz".into()).unwrap_err(),
        FfiKeyError::Malformed
    );
}

#[test]
fn known_hosts_tofu_flow() {
    let a = generate_key(KeyAlg::Ed25519, "a".into()).unwrap();
    let b = generate_key(KeyAlg::Ed25519, "b".into()).unwrap();
    let text = String::new();
    assert_eq!(
        known_hosts_check(text.clone(), "example.com".into(), 22, a.public_line.clone()).unwrap(),
        FfiHostKeyStatus::Unknown
    );
    let text =
        known_hosts_add(text, "example.com".into(), 22, a.public_line.clone(), false).unwrap();
    assert!(text.ends_with('\n'));
    assert!(text.starts_with("example.com ssh-ed25519 "));
    assert_eq!(
        known_hosts_check(text.clone(), "example.com".into(), 22, a.public_line.clone()).unwrap(),
        FfiHostKeyStatus::Trusted
    );
    match known_hosts_check(text.clone(), "example.com".into(), 22, b.public_line.clone()).unwrap()
    {
        FfiHostKeyStatus::Mismatch {
            expected_fingerprints,
        } => {
            assert_eq!(expected_fingerprints, vec![a.fingerprint.clone()])
        }
        other => panic!("{other:?}"),
    }
    // Non-default port uses the [host]:port form.
    let text = known_hosts_add(text, "h".into(), 2222, a.public_line.clone(), false).unwrap();
    assert!(text.contains("[h]:2222 ssh-ed25519 "));
}

#[test]
fn known_hosts_bad_key_line_is_malformed() {
    assert_eq!(
        known_hosts_check(String::new(), "h".into(), 22, "garbage".into()).unwrap_err(),
        FfiKeyError::Malformed
    );
}
