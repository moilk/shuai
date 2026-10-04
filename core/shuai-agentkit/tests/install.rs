use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::process::{Command, Stdio};

use shuai_agentkit::install::{expand_tilde, plugin_install_commands};
use shuai_agentkit::{InstallPlan, InstallStep, ProbeResult, parse_probe, probe_script};

const HOME: &str = "/home/ubuntu";
const AGENT: &str = "/home/ubuntu/.shuai/bin/shuai-agent";

fn probe() -> ProbeResult {
    ProbeResult {
        uname_s: "Linux".into(),
        uname_m: "x86_64".into(),
        home: HOME.into(),
        shell: "/usr/bin/zsh".into(),
        claude_path: Some("/home/ubuntu/.local/bin/claude".into()),
        tmux_version: Some("3.4".into()),
        agent_version: None,
        plugin_installed: false,
        codex_path: None,
        ..Default::default()
    }
}

fn tmux_lines(steps: &[InstallStep]) -> Option<Vec<String>> {
    steps.iter().find_map(|s| match s {
        InstallStep::AppendTmuxConf { lines, .. } => Some(lines.clone()),
        _ => None,
    })
}

#[test]
fn fresh_linux_with_claude_and_tmux() {
    let steps = InstallPlan::for_probe(&probe());
    assert_eq!(
        steps,
        vec![
            InstallStep::MakeDirs {
                path: "~/.shuai/bin".into()
            },
            InstallStep::UploadAgent {
                target_triple: "x86_64-unknown-linux-musl".into(),
                remote_path: "~/.shuai/bin/shuai-agent".into()
            },
            InstallStep::Chmod {
                path: "~/.shuai/bin/shuai-agent".into(),
                mode: 0o755
            },
            InstallStep::InstallPluginViaCli {
                claude_path: "/home/ubuntu/.local/bin/claude".into()
            },
            InstallStep::AppendTmuxConf {
                path: "~/.tmux.conf".into(),
                lines: tmux_lines(&steps).unwrap()
            },
            InstallStep::RunDoctor {
                agent_path: AGENT.into()
            },
        ]
    );
}

#[test]
fn target_triples() {
    let t = |s: &str, m: &str| {
        let mut p = probe();
        p.uname_s = s.into();
        p.uname_m = m.into();
        InstallPlan::for_probe(&p)
            .into_iter()
            .find_map(|st| match st {
                InstallStep::UploadAgent { target_triple, .. } => Some(target_triple),
                _ => None,
            })
    };
    assert_eq!(
        t("Linux", "x86_64").as_deref(),
        Some("x86_64-unknown-linux-musl")
    );
    assert_eq!(
        t("Linux", "amd64").as_deref(),
        Some("x86_64-unknown-linux-musl")
    );
    assert_eq!(
        t("Linux", "aarch64").as_deref(),
        Some("aarch64-unknown-linux-musl")
    );
    assert_eq!(
        t("Linux", "arm64").as_deref(),
        Some("aarch64-unknown-linux-musl")
    );
    assert_eq!(
        t("Darwin", "arm64").as_deref(),
        Some("aarch64-apple-darwin")
    );
    assert_eq!(
        t("Darwin", "x86_64").as_deref(),
        Some("x86_64-apple-darwin")
    );
    assert_eq!(t("FreeBSD", "amd64"), None);
    assert_eq!(t("Linux", "riscv64"), None);
}

#[test]
fn unsupported_platform_yields_single_unsupported_step() {
    let mut p = probe();
    p.uname_s = "FreeBSD".into();
    let steps = InstallPlan::for_probe(&p);
    assert_eq!(steps.len(), 1);
    assert!(matches!(&steps[0], InstallStep::Unsupported { reason } if reason.contains("FreeBSD")));
}

#[test]
fn without_claude_falls_back_to_merging_settings() {
    let mut p = probe();
    p.claude_path = None;
    let steps = InstallPlan::for_probe(&p);
    assert!(steps.contains(&InstallStep::MergeSettingsJson {
        path: "~/.claude/settings.json".into(),
        agent_path: AGENT.into()
    }));
    assert!(
        !steps
            .iter()
            .any(|s| matches!(s, InstallStep::InstallPluginViaCli { .. }))
    );
}

#[test]
fn plugin_already_installed_skips_plugin_and_merge() {
    for claude in [Some("/x/claude".to_string()), None] {
        let mut p = probe();
        p.claude_path = claude;
        p.plugin_installed = true;
        let steps = InstallPlan::for_probe(&p);
        assert!(!steps.iter().any(|s| matches!(
            s,
            InstallStep::InstallPluginViaCli { .. } | InstallStep::MergeSettingsJson { .. }
        )));
    }
}

#[test]
fn up_to_date_agent_is_not_reuploaded() {
    let mut p = probe();
    p.agent_version = Some(shuai_proto::version().to_string());
    let steps = InstallPlan::for_probe(&p);
    assert!(!steps.iter().any(|s| matches!(
        s,
        InstallStep::UploadAgent { .. } | InstallStep::Chmod { .. } | InstallStep::MakeDirs { .. }
    )));
    assert!(matches!(steps.last(), Some(InstallStep::RunDoctor { .. })));

    p.agent_version = Some("0.0.1".into());
    let steps = InstallPlan::for_probe(&p);
    assert!(
        steps
            .iter()
            .any(|s| matches!(s, InstallStep::UploadAgent { .. }))
    );
}

#[test]
fn codex_notify_uses_absolute_agent_path() {
    let mut p = probe();
    p.codex_path = Some("/usr/local/bin/codex".into());
    let steps = InstallPlan::for_probe(&p);
    assert!(steps.contains(&InstallStep::ConfigureCodexNotify {
        config_path: "~/.codex/config.toml".into(),
        notify_argv: vec![AGENT.into(), "codex-notify".into()],
    }));
    assert!(
        !InstallPlan::for_probe(&probe())
            .iter()
            .any(|s| matches!(s, InstallStep::ConfigureCodexNotify { .. }))
    );
}

#[test]
fn tmux_conf_depends_on_version() {
    let lines = |v: Option<&str>| {
        let mut p = probe();
        p.tmux_version = v.map(str::to_string);
        tmux_lines(&InstallPlan::for_probe(&p))
    };
    assert_eq!(lines(None), None);
    let new = lines(Some("3.4")).unwrap();
    let body = new.join("\n");
    assert!(body.contains("set -g allow-passthrough on"));
    assert!(body.contains("set -g set-titles on"));
    assert!(body.contains("set -g extended-keys on"));
    assert!(new.first().unwrap().contains("shuai"), "begin marker");
    assert!(new.last().unwrap().contains("shuai"), "end marker");
    let mid = lines(Some("3.2a")).unwrap().join("\n");
    assert!(!mid.contains("allow-passthrough"));
    assert!(mid.contains("extended-keys"));
    let old = lines(Some("3.0")).unwrap().join("\n");
    assert!(!old.contains("allow-passthrough") && !old.contains("extended-keys"));
    assert!(old.contains("set-titles"));
    // dev builds / unparsable: only the universally safe option
    let weird = lines(Some("tmux-wat")).unwrap().join("\n");
    assert!(weird.contains("set-titles") && !weird.contains("extended-keys"));
    assert!(
        lines(Some("next-3.5"))
            .unwrap()
            .join("\n")
            .contains("allow-passthrough")
    );
}

#[test]
fn tilde_expansion_and_commands() {
    assert_eq!(
        expand_tilde("~/.shuai/bin", "/home/u"),
        "/home/u/.shuai/bin"
    );
    assert_eq!(expand_tilde("~", "/home/u"), "/home/u");
    assert_eq!(expand_tilde("/abs/~x", "/home/u"), "/abs/~x");
    assert_eq!(expand_tilde("~/x", ""), "~/x");
    assert_eq!(expand_tilde("~/x", "/home/u/"), "/home/u/x");
    let cmds = plugin_install_commands("/home/my user/.local/bin/claude");
    assert_eq!(
        cmds,
        vec![
            "'/home/my user/.local/bin/claude' plugin marketplace add moilk/shuai".to_string(),
            "'/home/my user/.local/bin/claude' plugin install shuai@shuai".to_string(),
        ]
    );
}

#[test]
fn missing_home_falls_back_to_tilde_agent_path() {
    let mut p = probe();
    p.home = String::new();
    let steps = InstallPlan::for_probe(&p);
    assert!(
        matches!(steps.last(), Some(InstallStep::RunDoctor { agent_path }) if agent_path == "~/.shuai/bin/shuai-agent")
    );
}

// ---------------- parse_probe ----------------

#[test]
fn parse_probe_full_output() {
    let out = "uname_s=Linux\nuname_m=x86_64\nhome=/home/ubuntu\nshell=/usr/bin/zsh\n\
               claude_path=/home/ubuntu/.local/bin/claude\ntmux_version=tmux 3.4\n\
               agent_version=shuai-agent 0.1.0\nplugin_installed=1\ncodex_path=/usr/bin/codex\n";
    let p = parse_probe(out);
    assert_eq!(p.uname_s, "Linux");
    assert_eq!(p.uname_m, "x86_64");
    assert_eq!(p.home, "/home/ubuntu");
    assert_eq!(p.shell, "/usr/bin/zsh");
    assert_eq!(
        p.claude_path.as_deref(),
        Some("/home/ubuntu/.local/bin/claude")
    );
    assert_eq!(p.tmux_version.as_deref(), Some("3.4"));
    assert_eq!(p.agent_version.as_deref(), Some("0.1.0"));
    assert!(p.plugin_installed);
    assert_eq!(p.codex_path.as_deref(), Some("/usr/bin/codex"));
}

#[test]
fn parse_probe_is_lenient() {
    let out = "Welcome to Ubuntu!\r\nuname_s=Darwin\r\nuname_m=arm64\r\nclaude_path=\r\n\
               tmux_version=\nplugin_installed=0\nweird line\nunknown=1\n  home = /home/x \n\
               codex_path=/a=b/codex\n";
    let p = parse_probe(out);
    assert_eq!(p.uname_s, "Darwin");
    assert_eq!(p.uname_m, "arm64");
    assert_eq!(p.home, "/home/x");
    assert_eq!(p.claude_path, None);
    assert_eq!(p.tmux_version, None);
    assert!(!p.plugin_installed);
    assert_eq!(p.codex_path.as_deref(), Some("/a=b/codex"));
    assert_eq!(p.agent_version, None);
    assert_eq!(parse_probe(""), ProbeResult::default());
}

#[test]
fn parse_probe_plugin_flag_variants() {
    for (v, want) in [
        ("1", true),
        ("true", true),
        ("yes", true),
        ("0", false),
        ("", false),
        ("no", false),
    ] {
        assert_eq!(
            parse_probe(&format!("plugin_installed={v}\n")).plugin_installed,
            want,
            "{v}"
        );
    }
}

// ---------------- probe_script (really executed) ----------------

fn run_probe(sh: &str, home: &Path, path: &str) -> String {
    let mut child = Command::new(sh)
        .arg("-s")
        .env_clear()
        .env("HOME", home)
        .env("PATH", path)
        .env("SHELL", "/bin/zsh")
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

#[test]
fn probe_script_is_posix_and_defensive() {
    let s = probe_script();
    assert!(s.starts_with("#!/bin/sh"));
    for needle in [
        "command -v",
        ".local/bin",
        ".claude/local",
        ".npm-global/bin",
        "/usr/local/bin",
        "/opt/homebrew/bin",
        "</dev/null",
    ] {
        assert!(s.contains(needle), "missing {needle}");
    }
    assert!(!s.contains("[["), "bashism");
}

#[test]
fn probe_script_runs_locally_on_empty_home() {
    let home = tempfile::tempdir().unwrap();
    let out = run_probe("sh", home.path(), "/usr/bin:/bin");
    let p = parse_probe(&out);
    assert!(!p.uname_s.is_empty(), "{out}");
    assert!(!p.uname_m.is_empty());
    assert_eq!(p.home, home.path().to_str().unwrap());
    assert_eq!(p.shell, "/bin/zsh");
    assert_eq!(p.claude_path, None);
    assert_eq!(p.agent_version, None);
    assert!(!p.plugin_installed);
}

#[test]
fn probe_script_finds_claude_off_path() {
    for rel in [".local/bin", ".claude/local", ".npm-global/bin", ".bun/bin"] {
        let home = tempfile::tempdir().unwrap();
        let bin = home.path().join(rel).join("claude");
        fake_exe(&bin, "echo 2.1.0");
        let p = parse_probe(&run_probe("sh", home.path(), "/usr/bin:/bin"));
        assert_eq!(p.claude_path.as_deref(), bin.to_str(), "{rel}");
    }
}

#[test]
fn probe_script_prefers_command_v_and_finds_nvm_node_bins() {
    let home = tempfile::tempdir().unwrap();
    let on_path = home.path().join("custom/bin/claude");
    fake_exe(&on_path, "echo x");
    fake_exe(&home.path().join(".local/bin/claude"), "echo y");
    let path = format!("{}:/usr/bin:/bin", on_path.parent().unwrap().display());
    let p = parse_probe(&run_probe("sh", home.path(), &path));
    assert_eq!(p.claude_path.as_deref(), on_path.to_str());

    let home = tempfile::tempdir().unwrap();
    let nvm = home.path().join(".nvm/versions/node/v22.1.0/bin/codex");
    fake_exe(&nvm, "echo x");
    let p = parse_probe(&run_probe("sh", home.path(), "/usr/bin:/bin"));
    assert_eq!(p.codex_path.as_deref(), nvm.to_str());
}

#[test]
fn probe_script_ignores_directories_named_claude() {
    let home = tempfile::tempdir().unwrap();
    std::fs::create_dir_all(home.path().join(".local/bin/claude")).unwrap();
    let p = parse_probe(&run_probe("sh", home.path(), "/usr/bin:/bin"));
    assert_eq!(p.claude_path, None);
}

#[test]
fn probe_script_detects_agent_and_plugin() {
    let home = tempfile::tempdir().unwrap();
    fake_exe(
        &home.path().join(".shuai/bin/shuai-agent"),
        "echo 'shuai-agent 0.3.7'",
    );
    std::fs::create_dir_all(home.path().join(".claude/plugins")).unwrap();
    std::fs::write(
        home.path().join(".claude/plugins/installed_plugins.json"),
        r#"{"plugins":{"shuai@shuai":[]}}"#,
    )
    .unwrap();
    let p = parse_probe(&run_probe("sh", home.path(), "/usr/bin:/bin"));
    assert_eq!(p.agent_version.as_deref(), Some("0.3.7"));
    assert!(p.plugin_installed);

    // settings.json merge also counts
    let home = tempfile::tempdir().unwrap();
    std::fs::create_dir_all(home.path().join(".claude")).unwrap();
    std::fs::write(
        home.path().join(".claude/settings.json"),
        r#"{"hooks":{"Stop":[{"hooks":[{"command":"/h/.shuai/bin/shuai-agent hook stop"}]}]}}"#,
    )
    .unwrap();
    assert!(parse_probe(&run_probe("sh", home.path(), "/usr/bin:/bin")).plugin_installed);
}

#[test]
fn probe_script_does_not_let_children_eat_the_script_from_stdin() {
    // a fake tmux that drains stdin would swallow the rest of `sh -s` input if not redirected
    let home = tempfile::tempdir().unwrap();
    fake_exe(
        &home.path().join(".local/bin/tmux"),
        "cat >/dev/null; echo 'tmux 3.4'",
    );
    fake_exe(
        &home.path().join(".shuai/bin/shuai-agent"),
        "cat >/dev/null; echo 'shuai-agent 1.2.3'",
    );
    let p = parse_probe(&run_probe("sh", home.path(), "/usr/bin:/bin"));
    assert_eq!(p.tmux_version.as_deref(), Some("3.4"));
    assert_eq!(p.agent_version.as_deref(), Some("1.2.3"));
    assert!(!p.uname_s.is_empty());
}

#[test]
fn probe_script_runs_under_dash_if_available() {
    let Some(dash) = ["/bin/dash", "/usr/bin/dash"]
        .into_iter()
        .find(|p| Path::new(p).exists())
    else {
        return;
    };
    let home = tempfile::tempdir().unwrap();
    let p = parse_probe(&run_probe(dash, home.path(), "/usr/bin:/bin"));
    assert!(!p.uname_s.is_empty());
}

/// Manual: `SHUAI_PROBE_SSH_HOST=<ssh-host> cargo test -p shuai-agentkit -- --ignored probe_over_ssh`
#[test]
#[ignore]
fn probe_over_ssh() {
    let host = std::env::var("SHUAI_PROBE_SSH_HOST").expect("set SHUAI_PROBE_SSH_HOST");
    let mut child = Command::new("ssh")
        .args([host.as_str(), "sh -s"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
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
    let text = String::from_utf8(out.stdout).unwrap();
    println!("{text}");
    let p = parse_probe(&text);
    println!("{p:?}\n{:?}", InstallPlan::for_probe(&p));
    assert!(!p.uname_s.is_empty());
    assert!(p.claude_path.is_some());
}
