//! "Enable AI integration on this host": probe script, probe parsing and the install plan.
//!
//! Pure: the app runs [`probe_script`] over SSH, feeds the output to [`parse_probe`], asks
//! [`InstallPlan::for_probe`] for the steps and executes them with its own SSH/SFTP layer.

use shuai_tmux::TmuxVersion;

/// Where the agent binary lives on the remote host.
pub const AGENT_REMOTE_PATH: &str = "~/.shuai/bin/shuai-agent";
const AGENT_DIR: &str = "~/.shuai/bin";
const MARKETPLACE: &str = "moilk/shuai";
const PLUGIN: &str = "shuai@shuai";
const CLAUDE_SETTINGS: &str = "~/.claude/settings.json";
const CODEX_CONFIG: &str = "~/.codex/config.toml";
const TMUX_CONF: &str = "~/.tmux.conf";
/// Markers around the block appended to `~/.tmux.conf`, so an executor can stay idempotent.
pub const TMUX_BEGIN: &str = "# >>> shuai >>>";
pub const TMUX_END: &str = "# <<< shuai <<<";

/// What [`probe_script`] found on the remote host.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ProbeResult {
    pub uname_s: String,
    pub uname_m: String,
    pub home: String,
    pub shell: String,
    pub claude_path: Option<String>,
    /// `tmux -V` without the leading `tmux `, e.g. `3.4`.
    pub tmux_version: Option<String>,
    /// Version of an already installed `~/.shuai/bin/shuai-agent`.
    pub agent_version: Option<String>,
    pub plugin_installed: bool,
    pub codex_path: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum InstallStep {
    /// Nothing can be installed (unknown OS / CPU).
    Unsupported {
        reason: String,
    },
    MakeDirs {
        path: String,
    },
    /// Upload the prebuilt `shuai-agent` for `target_triple` (SFTP does not expand `~`;
    /// see [`expand_tilde`]).
    UploadAgent {
        target_triple: String,
        remote_path: String,
    },
    Chmod {
        path: String,
        mode: u32,
    },
    /// `claude plugin marketplace add` + `claude plugin install`; see [`plugin_install_commands`].
    InstallPluginViaCli {
        claude_path: String,
    },
    /// Fallback without the claude CLI: merge hook entries (running `agent_path hook ...`) into
    /// the user's settings.json without overwriting their own hooks.
    MergeSettingsJson {
        path: String,
        agent_path: String,
    },
    /// Set `notify = notify_argv` in the Codex config.
    ConfigureCodexNotify {
        config_path: String,
        notify_argv: Vec<String>,
    },
    /// Append `lines` (wrapped in [`TMUX_BEGIN`] / [`TMUX_END`]) unless the begin marker exists.
    AppendTmuxConf {
        path: String,
        lines: Vec<String>,
    },
    RunDoctor {
        agent_path: String,
    },
}

/// Namespace for the planning function.
pub struct InstallPlan;

impl InstallPlan {
    /// Steps to bring the host to a working state, skipping what the probe shows is done.
    pub fn for_probe(probe: &ProbeResult) -> Vec<InstallStep> {
        Self::for_probe_with(probe, shuai_proto::version())
    }

    /// Like [`for_probe`](Self::for_probe), with an explicit expected agent version.
    pub fn for_probe_with(probe: &ProbeResult, expected_agent_version: &str) -> Vec<InstallStep> {
        let Some(triple) = target_triple(&probe.uname_s, &probe.uname_m) else {
            return vec![InstallStep::Unsupported {
                reason: format!(
                    "unsupported platform: {} {}",
                    probe.uname_s.trim(),
                    probe.uname_m.trim()
                ),
            }];
        };
        let agent_abs = expand_tilde(AGENT_REMOTE_PATH, &probe.home);
        let mut steps = Vec::new();

        if probe.agent_version.as_deref().map(str::trim) != Some(expected_agent_version) {
            steps.push(InstallStep::MakeDirs {
                path: AGENT_DIR.into(),
            });
            steps.push(InstallStep::UploadAgent {
                target_triple: triple.into(),
                remote_path: AGENT_REMOTE_PATH.into(),
            });
            steps.push(InstallStep::Chmod {
                path: AGENT_REMOTE_PATH.into(),
                mode: 0o755,
            });
        }

        if !probe.plugin_installed {
            steps.push(match &probe.claude_path {
                Some(c) => InstallStep::InstallPluginViaCli {
                    claude_path: c.clone(),
                },
                None => InstallStep::MergeSettingsJson {
                    path: CLAUDE_SETTINGS.into(),
                    agent_path: agent_abs.clone(),
                },
            });
        }

        if probe.codex_path.is_some() {
            steps.push(InstallStep::ConfigureCodexNotify {
                config_path: CODEX_CONFIG.into(),
                notify_argv: vec![
                    agent_abs.clone(),
                    "hook".into(),
                    "codex-turn-complete".into(),
                ],
            });
        }

        if let Some(v) = &probe.tmux_version {
            steps.push(InstallStep::AppendTmuxConf {
                path: TMUX_CONF.into(),
                lines: tmux_conf_lines(TmuxVersion::parse(v)),
            });
        }

        steps.push(InstallStep::RunDoctor {
            agent_path: agent_abs,
        });
        steps
    }
}

fn target_triple(uname_s: &str, uname_m: &str) -> Option<&'static str> {
    let arch = match uname_m.trim() {
        "x86_64" | "amd64" => "x86_64",
        "aarch64" | "arm64" => "aarch64",
        _ => return None,
    };
    Some(match (uname_s.trim(), arch) {
        ("Linux", "x86_64") => "x86_64-unknown-linux-musl",
        ("Linux", _) => "aarch64-unknown-linux-musl",
        ("Darwin", "x86_64") => "x86_64-apple-darwin",
        ("Darwin", _) => "aarch64-apple-darwin",
        _ => return None,
    })
}

fn tmux_conf_lines(v: Option<TmuxVersion>) -> Vec<String> {
    let mut lines = vec![TMUX_BEGIN.to_string()];
    if v.is_some_and(|v| v.at_least(3, 3)) {
        lines.push("set -g allow-passthrough on".into());
    }
    lines.push("set -g set-titles on".into());
    if v.is_some_and(|v| v.at_least(3, 2)) {
        lines.push("set -g extended-keys on".into());
    }
    lines.push(TMUX_END.into());
    lines
}

/// Expand a leading `~` / `~/` using `home` (unchanged when `home` is empty).
pub fn expand_tilde(path: &str, home: &str) -> String {
    let home = home.trim_end_matches('/');
    if home.is_empty() {
        return path.to_string();
    }
    if path == "~" {
        home.to_string()
    } else if let Some(rest) = path.strip_prefix("~/") {
        format!("{home}/{rest}")
    } else {
        path.to_string()
    }
}

fn sh_quote(s: &str) -> String {
    if !s.is_empty()
        && s.bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"/._-:@%+=,".contains(&b))
    {
        s.to_string()
    } else {
        format!("'{}'", s.replace('\'', r"'\''"))
    }
}

/// Shell commands that install the Claude Code plugin through the CLI.
pub fn plugin_install_commands(claude_path: &str) -> Vec<String> {
    let c = sh_quote(claude_path);
    vec![
        format!("{c} plugin marketplace add {MARKETPLACE}"),
        format!("{c} plugin install {PLUGIN}"),
    ]
}

/// Parse the `key=value` lines printed by [`probe_script`]. Lenient: unknown keys, noise
/// (login banners) and CRLF are ignored; empty values mean "not found".
pub fn parse_probe(output: &str) -> ProbeResult {
    let mut p = ProbeResult::default();
    for line in output.lines() {
        let Some((k, v)) = line.split_once('=') else {
            continue;
        };
        let (k, v) = (k.trim(), v.trim());
        let opt = || (!v.is_empty()).then(|| v.to_string());
        match k {
            "uname_s" => p.uname_s = v.into(),
            "uname_m" => p.uname_m = v.into(),
            "home" => p.home = v.into(),
            "shell" => p.shell = v.into(),
            "claude_path" => p.claude_path = opt(),
            "codex_path" => p.codex_path = opt(),
            "tmux_version" => {
                p.tmux_version = Some(v.strip_prefix("tmux").unwrap_or(v).trim().to_string())
                    .filter(|s| !s.is_empty());
            }
            "agent_version" => {
                p.agent_version = v.split_whitespace().last().map(str::to_string);
            }
            "plugin_installed" => p.plugin_installed = matches!(v, "1" | "true" | "yes"),
            _ => {}
        }
    }
    p
}

/// Read-only POSIX `sh` script (run as `ssh host 'sh -s' < script`) printing `key=value` lines.
///
/// Non-interactive SSH shells do not source `~/.zshrc`, so tools installed by npm/the native
/// installer are not on `PATH`; besides `command -v` it probes the usual install locations.
/// The whole script is a function called with `</dev/null`, so no child process can swallow
/// the rest of the script from stdin.
pub fn probe_script() -> &'static str {
    PROBE_SCRIPT
}

const PROBE_SCRIPT: &str = r#"#!/bin/sh
# shuai remote probe: read-only, prints key=value lines.
main() {
  home=${HOME:-}
  if [ -z "$home" ]; then home=$(cd ~ 2>/dev/null && pwd); fi
  emit() { printf '%s=%s\n' "$1" "$2"; }

  # find_bin NAME: PATH first, then the places installers put things.
  find_bin() {
    p=$(command -v "$1" 2>/dev/null)
    case $p in
      /*) if [ -f "$p" ] && [ -x "$p" ]; then printf '%s\n' "$p"; return 0; fi ;;
    esac
    for d in "$home/.local/bin" "$home/.claude/local" "$home/.npm-global/bin" \
             "$home/.bun/bin" "$home/.volta/bin" "$home/.cargo/bin" \
             /usr/local/bin /opt/homebrew/bin /usr/bin /bin \
             "$home"/.nvm/versions/node/*/bin; do
      if [ -f "$d/$1" ] && [ -x "$d/$1" ]; then printf '%s\n' "$d/$1"; return 0; fi
    done
    return 1
  }

  emit uname_s "$(uname -s 2>/dev/null | head -n 1)"
  emit uname_m "$(uname -m 2>/dev/null | head -n 1)"
  emit home "$home"
  login_shell=${SHELL:-}
  if [ -z "$login_shell" ] && command -v getent >/dev/null 2>&1; then
    login_shell=$(getent passwd "$(id -un 2>/dev/null)" 2>/dev/null | cut -d: -f7)
  fi
  emit shell "$login_shell"

  emit claude_path "$(find_bin claude)"
  emit codex_path "$(find_bin codex)"

  tmux_bin=$(find_bin tmux)
  if [ -n "$tmux_bin" ]; then
    emit tmux_version "$("$tmux_bin" -V 2>/dev/null | head -n 1)"
  else
    emit tmux_version ""
  fi

  agent="$home/.shuai/bin/shuai-agent"
  if [ -f "$agent" ] && [ -x "$agent" ]; then
    emit agent_version "$("$agent" --version 2>/dev/null | head -n 1)"
  else
    emit agent_version ""
  fi

  plugin=0
  if grep -q '"shuai@' "$home/.claude/plugins/installed_plugins.json" 2>/dev/null; then plugin=1; fi
  if grep -q 'shuai-agent' "$home/.claude/settings.json" 2>/dev/null; then plugin=1; fi
  emit plugin_installed "$plugin"
}
main </dev/null
"#;
