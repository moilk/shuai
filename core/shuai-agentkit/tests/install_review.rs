use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::process::{Command, Stdio};

use shuai_agentkit::install::{PROBE_BEGIN, PROBE_END, TMUX_BEGIN};
use shuai_agentkit::{InstallPlan, InstallStep, ProbeResult, parse_probe, probe_script};

const AGENT: &str = "/home/ubuntu/.shuai/bin/shuai-agent";

fn probe() -> ProbeResult {
    ProbeResult {
        uname_s: "Linux".into(),
        uname_m: "x86_64".into(),
        home: "/home/ubuntu".into(),
        shell: "/usr/bin/zsh".into(),
        claude_path: Some("/home/ubuntu/.local/bin/claude".into()),
        tmux_version: Some("3.4".into()),
        ..Default::default()
    }
}

fn has_tmux(steps: &[InstallStep]) -> bool {
    steps
        .iter()
        .any(|s| matches!(s, InstallStep::AppendTmuxConf { .. }))
}

fn our_notify() -> String {
    format!("notify = [\"{AGENT}\", \"codex-notify\"]")
}

#[test]
fn parse_probe_only_trusts_the_sentinel_framed_region() {
    let out = format!(
        "home=/evil\nplugin_installed=1\nmotd: uname_s=Plan9\n{PROBE_BEGIN}\r\n\
         uname_s=Linux\nuname_m=aarch64\nhome=/home/u\nnoise from bashrc\n{PROBE_END}\n\
         uname_s=Darwin\nclaude_path=/trailing/junk\n"
    );
    let p = parse_probe(&out);
    assert_eq!(p.uname_s, "Linux");
    assert_eq!(p.uname_m, "aarch64");
    assert_eq!(p.home, "/home/u");
    assert!(!p.plugin_installed);
    assert_eq!(p.claude_path, None);
    // truncated output (no END): still use what we got after BEGIN
    let p = parse_probe(&format!("junk\n{PROBE_BEGIN}\nuname_s=Linux\n"));
    assert_eq!(p.uname_s, "Linux");
}

#[test]
fn parse_probe_keeps_significant_spaces_in_values() {
    let p = parse_probe(&format!(
        "{PROBE_BEGIN}\nhome=/home/my user \r\n{PROBE_END}\n"
    ));
    assert_eq!(p.home, "/home/my user ");
}

#[test]
fn parse_probe_codex_notify_and_tmux_block() {
    let p = parse_probe(&format!(
        "{PROBE_BEGIN}\ncodex_notify=notify = [\"a\", \"b\"]\ntmux_conf_block=1\n{PROBE_END}\n"
    ));
    assert_eq!(p.codex_notify.as_deref(), Some("notify = [\"a\", \"b\"]"));
    assert!(p.tmux_conf_block);
}

#[test]
fn codex_existing_foreign_notify_yields_conflict_not_overwrite() {
    let mut p = probe();
    p.codex_path = Some("/usr/bin/codex".into());
    p.codex_notify = Some("notify = [\"/usr/bin/terminal-notifier\"]".into());
    let steps = InstallPlan::for_probe(&p);
    assert!(
        !steps
            .iter()
            .any(|s| matches!(s, InstallStep::ConfigureCodexNotify { .. }))
    );
    assert!(steps.iter().any(|s| matches!(
        s,
        InstallStep::CodexNotifyConflict { config_path, existing }
            if config_path == "~/.codex/config.toml" && existing.contains("terminal-notifier")
    )));
}

#[test]
fn codex_notify_already_ours_is_skipped() {
    let mut p = probe();
    p.codex_path = Some("/usr/bin/codex".into());
    p.codex_notify = Some(our_notify());
    let steps = InstallPlan::for_probe(&p);
    assert!(!steps.iter().any(|s| matches!(
        s,
        InstallStep::ConfigureCodexNotify { .. } | InstallStep::CodexNotifyConflict { .. }
    )));
}

#[test]
fn tmux_block_already_present_is_skipped() {
    let mut p = probe();
    assert!(has_tmux(&InstallPlan::for_probe(&p)));
    p.tmux_conf_block = true;
    assert!(!has_tmux(&InstallPlan::for_probe(&p)));
}

#[test]
fn unsupported_arches_and_systems() {
    for (s, m) in [
        ("Linux", "armv7l"),
        ("Linux", "armv8l"),
        ("Linux", "i686"),
        ("Linux", "riscv64"),
        ("Linux", ""),
        ("OpenBSD", "x86_64"),
    ] {
        let mut p = probe();
        p.uname_s = s.into();
        p.uname_m = m.into();
        let steps = InstallPlan::for_probe(&p);
        assert!(
            matches!(steps.as_slice(), [InstallStep::Unsupported { .. }]),
            "{s} {m}"
        );
    }
}

#[test]
fn replanning_after_a_complete_install_is_just_a_doctor_run() {
    let mut p = probe();
    p.agent_version = Some(shuai_proto::version().into());
    p.plugin_installed = true;
    p.tmux_conf_block = true;
    p.codex_path = Some("/usr/bin/codex".into());
    p.codex_notify = Some(our_notify());
    assert_eq!(
        InstallPlan::for_probe(&p),
        vec![InstallStep::RunDoctor {
            agent_path: AGENT.into()
        }]
    );
}

// ---------------- executed probe ----------------

fn run_probe(home: &Path, path: &str) -> String {
    let mut child = Command::new("sh")
        .arg("-s")
        .env_clear()
        .env("HOME", home)
        .env("PATH", path)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    use std::io::Write;
    child
        .stdin
        .take()
        .unwrap()
        .write_all(probe_script().as_bytes())
        .unwrap();
    let out = child.wait_with_output().unwrap();
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    String::from_utf8(out.stdout).unwrap()
}

fn fake_exe(path: &Path, body: &str) {
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(path, format!("#!/bin/sh\n{body}\n")).unwrap();
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o755)).unwrap();
}

fn snapshot(dir: &Path) -> Vec<String> {
    fn walk(d: &Path, v: &mut Vec<String>) {
        for e in std::fs::read_dir(d).unwrap().flatten() {
            v.push(e.path().display().to_string());
            if e.path().is_dir() {
                walk(&e.path(), v);
            }
        }
    }
    let mut v = Vec::new();
    walk(dir, &mut v);
    v.sort();
    v
}

#[test]
fn probe_script_is_sentinel_framed_and_survives_banner_junk_spaced_home_and_hangs() {
    let s = probe_script();
    assert!(s.contains(PROBE_BEGIN) && s.contains(PROBE_END));
    let base = tempfile::tempdir().unwrap();
    let home = base.path().join("my home dir");
    fake_exe(&home.join(".local/bin/claude"), "echo claude");
    // a hostile tmux that hangs: the probe must not wait for it
    fake_exe(&home.join(".local/bin/tmux"), "sleep 30");
    let before = snapshot(&home);
    let started = std::time::Instant::now();
    let out = run_probe(&home, "/usr/bin:/bin");
    assert!(started.elapsed() < std::time::Duration::from_secs(15));
    let lines: Vec<&str> = out.lines().collect();
    assert_eq!(lines.first(), Some(&PROBE_BEGIN));
    assert_eq!(lines.last(), Some(&PROBE_END));
    let p = parse_probe(&format!("banner\nhome=/x\n{out}goodbye\n"));
    assert_eq!(p.home, home.to_str().unwrap());
    assert_eq!(
        p.claude_path.as_deref(),
        Some(home.join(".local/bin/claude").to_str().unwrap())
    );
    assert_eq!(snapshot(&home), before, "probe must be read-only");
}

#[test]
fn probe_script_reports_foreign_codex_notify_and_tmux_block() {
    let home = tempfile::tempdir().unwrap();
    std::fs::create_dir_all(home.path().join(".codex")).unwrap();
    std::fs::write(
        home.path().join(".codex/config.toml"),
        "model = \"x\"\nnotify = [\"/bin/foo\"]\n[tui]\nnotify = \"nope\"\n",
    )
    .unwrap();
    std::fs::write(
        home.path().join(".tmux.conf"),
        format!("set -g mouse on\n{TMUX_BEGIN}\n"),
    )
    .unwrap();
    let p = parse_probe(&run_probe(home.path(), "/usr/bin:/bin"));
    assert_eq!(p.codex_notify.as_deref(), Some("notify = [\"/bin/foo\"]"));
    assert!(p.tmux_conf_block);
    let empty = tempfile::tempdir().unwrap();
    let p = parse_probe(&run_probe(empty.path(), "/usr/bin:/bin"));
    assert_eq!(p.codex_notify, None);
    assert!(!p.tmux_conf_block);
}
