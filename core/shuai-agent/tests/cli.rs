use assert_cmd::Command;

#[test]
fn version_flag_prints_version() {
    let out = Command::cargo_bin("shuai-agent")
        .unwrap()
        .arg("--version")
        .output()
        .unwrap();
    assert!(out.status.success());
    let s = String::from_utf8(out.stdout).unwrap();
    assert_eq!(
        s.trim(),
        format!("shuai-agent {}", env!("CARGO_PKG_VERSION"))
    );
}
