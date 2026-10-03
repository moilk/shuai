use shuai_keys::*;
use std::fs;
use std::path::PathBuf;

fn fx(name: &str) -> String {
    let p = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixtures")
        .join(name);
    fs::read_to_string(&p).unwrap_or_else(|e| panic!("{}: {e}", p.display()))
}

fn pubkey(name: &str) -> PublicKey {
    PublicKey::from_openssh(fx(&format!("{name}.pub")).trim()).unwrap()
}

fn ed() -> PublicKey {
    pubkey("test_ed25519_plain")
}
fn ec() -> PublicKey {
    pubkey("test_ecdsa_plain")
}
fn rsa() -> PublicKey {
    pubkey("test_rsa_plain")
}
fn other() -> PublicKey {
    pubkey("test_ed25519_enc")
}

#[test]
fn plain_host_trusted_unknown_mismatch() {
    let kh = KnownHosts::parse(&fx("known_hosts"));
    assert_eq!(kh.check("example.com", 22, &ed()), HostKeyStatus::Trusted);
    assert_eq!(kh.check("nowhere.org", 22, &ed()), HostKeyStatus::Unknown);
    assert_eq!(
        kh.check("example.com", 22, &other()),
        HostKeyStatus::Mismatch {
            expected_fingerprints: vec![fingerprint(&ed())]
        }
    );
}

#[test]
fn port_matters() {
    let kh = KnownHosts::parse(&fx("known_hosts"));
    // plain entry is for port 22 only
    assert_eq!(kh.check("example.com", 2222, &ed()), HostKeyStatus::Unknown);
    // bracketed entry is for port 2222 only
    assert_eq!(
        kh.check("git.example.com", 2222, &ec()),
        HostKeyStatus::Trusted
    );
    assert_eq!(
        kh.check("git.example.com", 22, &ec()),
        HostKeyStatus::Unknown
    );
}

#[test]
fn comma_list_matches_each_alias() {
    let kh = KnownHosts::parse(&fx("known_hosts"));
    assert_eq!(kh.check("10.0.0.5", 2222, &ec()), HostKeyStatus::Trusted);
}

#[test]
fn host_matching_is_case_insensitive() {
    let kh = KnownHosts::parse(&fx("known_hosts"));
    assert_eq!(kh.check("EXAMPLE.com", 22, &ed()), HostKeyStatus::Trusted);
}

#[test]
fn hashed_entry_from_ssh_keygen() {
    let kh = KnownHosts::parse(&fx("known_hosts_hashed"));
    assert_eq!(
        kh.check("hashedhost.example.com", 22, &ed()),
        HostKeyStatus::Trusted
    );
    assert_eq!(
        kh.check("other.example.com", 22, &ed()),
        HostKeyStatus::Unknown
    );
    assert!(matches!(
        kh.check("hashedhost.example.com", 22, &other()),
        HostKeyStatus::Mismatch { .. }
    ));
}

#[test]
fn revoked_key_is_revoked() {
    let kh = KnownHosts::parse(&fx("known_hosts"));
    assert_eq!(
        kh.check("bad.example.com", 22, &rsa()),
        HostKeyStatus::Revoked
    );
    // a different key for that host is merely unknown
    assert_eq!(
        kh.check("bad.example.com", 22, &ed()),
        HostKeyStatus::Unknown
    );
}

#[test]
fn revoked_wins_over_trusted() {
    let text = format!(
        "h.example {k}\n@revoked h.example {k}\n",
        k = authorized_keys_line(&ed())
    );
    let kh = KnownHosts::parse(&text);
    assert_eq!(kh.check("h.example", 22, &ed()), HostKeyStatus::Revoked);
}

#[test]
fn cert_authority_is_ignored() {
    let kh = KnownHosts::parse(&fx("known_hosts"));
    assert_eq!(
        kh.check("x.ca.example.com", 22, &ed()),
        HostKeyStatus::Unknown
    );
}

#[test]
fn wildcards_and_negation() {
    let k = authorized_keys_line(&ed());
    let kh = KnownHosts::parse(&format!("*.corp.example,!secret.corp.example {k}\n"));
    assert_eq!(
        kh.check("a.corp.example", 22, &ed()),
        HostKeyStatus::Trusted
    );
    assert_eq!(
        kh.check("secret.corp.example", 22, &ed()),
        HostKeyStatus::Unknown
    );
    let kh = KnownHosts::parse(&format!("h?st {k}\n"));
    assert_eq!(kh.check("host", 22, &ed()), HostKeyStatus::Trusted);
}

#[test]
fn multiple_keys_per_host_any_match_is_trusted() {
    let text = format!(
        "h {}\nh {}\n",
        authorized_keys_line(&ed()),
        authorized_keys_line(&ec())
    );
    let kh = KnownHosts::parse(&text);
    assert_eq!(kh.check("h", 22, &ec()), HostKeyStatus::Trusted);
    match kh.check("h", 22, &other()) {
        HostKeyStatus::Mismatch {
            expected_fingerprints,
        } => {
            assert_eq!(expected_fingerprints.len(), 2)
        }
        s => panic!("{s:?}"),
    }
}

#[test]
fn comments_blank_and_garbage_lines_are_skipped_and_preserved() {
    let text = "# c\n\nnot a valid line\nexample.com ssh-ed25519 !!!notbase64\n";
    let kh = KnownHosts::parse(text);
    assert_eq!(kh.check("example.com", 22, &ed()), HostKeyStatus::Unknown);
    assert_eq!(kh.to_text(), text);
}

#[test]
fn text_roundtrip() {
    let t = fx("known_hosts");
    assert_eq!(KnownHosts::parse(&t).to_text(), t);
    let t = fx("known_hosts_hashed");
    assert_eq!(KnownHosts::parse(&t).to_text(), t);
}

#[test]
fn crlf_input_is_handled() {
    let t = fx("known_hosts").replace('\n', "\r\n");
    let kh = KnownHosts::parse(&t);
    assert_eq!(kh.check("example.com", 22, &ed()), HostKeyStatus::Trusted);
}

#[test]
fn add_entry_plain_port_22() {
    let line = add_entry("example.org", 22, &ed(), false);
    assert_eq!(line, format!("example.org {}", authorized_keys_line(&ed())));
}

#[test]
fn add_entry_plain_nonstandard_port() {
    let line = add_entry("example.org", 2222, &ed(), false);
    assert!(line.starts_with("[example.org]:2222 ssh-ed25519 "));
}

#[test]
fn add_entry_omits_key_comment_whitespace_issues() {
    // known_hosts lines carry no comment; keep it out so the line is stable.
    let line = add_entry("h", 22, &ed(), false);
    assert_eq!(line.split_whitespace().count(), 3);
}

#[test]
fn add_entry_hashed_roundtrips_via_check() {
    for port in [22u16, 2222] {
        let line = add_entry("Secret.Host", port, &ec(), true);
        assert!(line.starts_with("|1|"), "{line}");
        assert!(!line.contains("Secret"));
        let kh = KnownHosts::parse(&format!("{line}\n"));
        assert_eq!(kh.check("secret.host", port, &ec()), HostKeyStatus::Trusted);
        assert_eq!(
            kh.check("secret.host", port + 1, &ec()),
            HostKeyStatus::Unknown
        );
    }
}

#[test]
fn hashed_entries_are_salted_randomly() {
    assert_ne!(
        add_entry("h", 22, &ed(), true),
        add_entry("h", 22, &ed(), true)
    );
}

#[test]
fn add_entry_hash_format_is_accepted_by_ssh_keygen() {
    let dir = env!("CARGO_TARGET_TMPDIR");
    let path = PathBuf::from(dir).join("kh_check");
    fs::write(
        &path,
        format!("{}\n", add_entry("verify.example", 2222, &ed(), true)),
    )
    .unwrap();
    let Ok(out) = std::process::Command::new("ssh-keygen")
        .args(["-F", "[verify.example]:2222", "-f"])
        .arg(&path)
        .output()
    else {
        return;
    };
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stdout)
    );
}

#[test]
fn known_hosts_add_appends_and_trusts() {
    let mut kh = KnownHosts::default();
    assert_eq!(kh.check("h", 22, &ed()), HostKeyStatus::Unknown);
    let line = kh.add("h", 22, &ed(), false);
    assert!(kh.to_text().ends_with(&format!("{line}\n")));
    assert_eq!(kh.check("h", 22, &ed()), HostKeyStatus::Trusted);
    // appending to text that lacks a trailing newline keeps lines separate
    let mut kh = KnownHosts::parse("# no newline");
    kh.add("h", 22, &ed(), false);
    assert_eq!(kh.to_text().lines().count(), 2);
}

#[test]
fn parse_never_panics_on_garbage() {
    for s in [
        "|1|",
        "|1|a|b ssh-ed25519 AAAA",
        "@revoked",
        "@",
        "[",
        "[h]:",
        "[h]:99999 x y",
        ",,, a b",
        "\u{0}\u{1}",
    ] {
        let kh = KnownHosts::parse(s);
        let _ = kh.check("h", 22, &ed());
        let _ = kh.to_text();
    }
}
