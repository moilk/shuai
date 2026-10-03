//! Remote command lines, the plugin bundle and `settings.json` merging used by the app.
//!
//! Pure string/JSON builders: the app runs the commands over SSH. Everything user-controlled
//! is shell-quoted.

use serde_json::{Map, Value};

use crate::install::{AGENT_REMOTE_PATH, TMUX_BEGIN, TMUX_END, expand_tilde, sh_quote};

/// Where the local (private-repo friendly) plugin marketplace is uploaded.
pub const PLUGIN_MARKETPLACE_DIR: &str = "~/.shuai/plugin-marketplace";
const PLUGIN: &str = "shuai@shuai";
const MARKETPLACE_NAME: &str = "shuai";

/// A file of the plugin marketplace, path relative to [`PLUGIN_MARKETPLACE_DIR`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PluginFile {
    pub path: String,
    pub contents: String,
}

const MARKETPLACE_JSON: &str = include_str!("../../../.claude-plugin/marketplace.json");
const PLUGIN_JSON: &str = include_str!("../../../plugin/.claude-plugin/plugin.json");
const HOOKS_JSON: &str = include_str!("../../../plugin/hooks/hooks.json");

/// The repo's marketplace + plugin, embedded at build time so the app can install the plugin
/// from a local directory (works while the GitHub repository is private or offline).
pub fn plugin_bundle() -> Vec<PluginFile> {
    [
        (".claude-plugin/marketplace.json", MARKETPLACE_JSON),
        ("plugin/.claude-plugin/plugin.json", PLUGIN_JSON),
        ("plugin/hooks/hooks.json", HOOKS_JSON),
    ]
    .into_iter()
    .map(|(p, c)| PluginFile {
        path: p.into(),
        contents: c.into(),
    })
    .collect()
}

/// `~/.shuai/bin/shuai-agent respond ID allow|deny [--message=MSG]` (the leading `~` is left
/// unquoted so the remote shell expands it). Fails for ids the agent would reject.
pub fn respond_command(
    request_id: &str,
    allow: bool,
    message: Option<&str>,
) -> Result<String, String> {
    if !shuai_proto::is_valid_request_id(request_id) {
        return Err(format!("invalid request id {request_id:?}"));
    }
    let mut c = format!(
        "{AGENT_REMOTE_PATH} respond {request_id} {}",
        if allow { "allow" } else { "deny" }
    );
    if let Some(m) = message.filter(|m| !m.is_empty()) {
        // `--message=` keeps a message that starts with `-` from being parsed as a flag.
        c.push_str(&format!(" --message={}", sh_quote(m)));
    }
    Ok(c)
}

/// `~/.shuai/bin/shuai-agent watch --since N`.
pub fn watch_command(since: u64) -> String {
    format!("{AGENT_REMOTE_PATH} watch --since {since}")
}

/// `<claude> agents --json` (reconciliation source for [`crate::AgentTracker`]).
pub fn claude_agents_command(claude_path: &str) -> String {
    format!("{} agents --json", sh_quote(claude_path))
}

/// Register the uploaded local marketplace and install the plugin from it.
pub fn local_plugin_install_commands(claude_path: &str, home: &str) -> Vec<String> {
    let c = sh_quote(claude_path);
    let dir = sh_quote(&expand_tilde(PLUGIN_MARKETPLACE_DIR, home));
    vec![
        format!("{c} plugin marketplace add {dir}"),
        format!("{c} plugin install {PLUGIN}"),
    ]
}

pub fn plugin_uninstall_commands(claude_path: &str) -> Vec<String> {
    let c = sh_quote(claude_path);
    vec![
        format!("{c} plugin uninstall {PLUGIN}"),
        format!("{c} plugin marketplace remove {MARKETPLACE_NAME}"),
    ]
}

fn path_arg(path: &str) -> String {
    // Keep a leading `~/` expandable by the shell.
    match path.strip_prefix("~/") {
        Some(rest) => format!("~/{}", sh_quote(rest)),
        None => sh_quote(path),
    }
}

/// Append `lines` to `path` unless the begin marker is already there. Creates the file; a
/// last line without a trailing newline is terminated first so the markers stay on their own lines.
pub fn append_tmux_block_command(path: &str, lines: &[String]) -> String {
    let p = path_arg(path);
    let body: String = lines
        .iter()
        .map(|l| format!(" {}", sh_quote(l)))
        .collect::<String>();
    format!(
        "grep -qF {} {p} 2>/dev/null || {{ [ -s {p} ] && [ -n \"$(tail -c1 {p})\" ] && printf '\\n' >> {p}; printf '%s\\n'{body} >> {p}; }}",
        sh_quote(TMUX_BEGIN)
    )
}

/// Delete the marker block from `path` (no error if the file is missing). A begin marker
/// without a matching end marker is left alone rather than deleting to the end of the file.
/// Rewrites in place (`cat >`) so permissions and symlinks survive.
pub fn remove_tmux_block_command(path: &str) -> String {
    let p = path_arg(path);
    let awk = "skip { buf = buf $0 \"\\n\"; if ($0 == e) { skip = 0; buf = \"\" } next } \
               $0 == b { skip = 1; buf = $0 \"\\n\"; next } { print } \
               END { if (skip) printf \"%s\", buf }";
    format!(
        "[ -f {p} ] && {{ awk -v b={} -v e={} {} {p} > {p}.shuai-tmp && cat {p}.shuai-tmp > {p}; rm -f {p}.shuai-tmp; }}; true",
        sh_quote(TMUX_BEGIN),
        sh_quote(TMUX_END),
        sh_quote(awk)
    )
}

fn is_ours(group: &Value) -> bool {
    group
        .get("hooks")
        .and_then(Value::as_array)
        .is_some_and(|hs| {
            hs.iter().any(|h| {
                h.get("command")
                    .and_then(Value::as_str)
                    .is_some_and(|c| c.contains("shuai-agent"))
            })
        })
}

fn substitute_agent(v: &mut Value, agent: &str) {
    match v {
        Value::String(s) => *s = s.replace("$HOME/.shuai/bin/shuai-agent", agent),
        Value::Array(a) => a.iter_mut().for_each(|x| substitute_agent(x, agent)),
        Value::Object(o) => o.values_mut().for_each(|x| substitute_agent(x, agent)),
        _ => {}
    }
}

fn parse_settings(text: &str) -> Result<Map<String, Value>, String> {
    if text.trim().is_empty() {
        return Ok(Map::new());
    }
    match serde_json::from_str::<Value>(text).map_err(|e| format!("settings.json: {e}"))? {
        Value::Object(o) => Ok(o),
        _ => Err("settings.json is not a JSON object".into()),
    }
}

fn render(o: Map<String, Value>) -> String {
    let mut s = serde_json::to_string_pretty(&Value::Object(o)).expect("serializable");
    s.push('\n');
    s
}

/// Add the plugin's hook entries (pointing at `agent_path`) to a `settings.json` text,
/// keeping everything else; entries of ours that already exist are not duplicated.
pub fn merge_claude_settings(existing: &str, agent_path: &str) -> Result<String, String> {
    let mut root = parse_settings(existing)?;
    let mut ours: Value =
        serde_json::from_str(HOOKS_JSON).map_err(|e| format!("bundled hooks.json: {e}"))?;
    // The path lands inside double quotes of a shell command: escape it there (not in the JSON text).
    let escaped = agent_path
        .replace('\\', "\\\\")
        .replace('"', "\\\"")
        .replace('$', "\\$")
        .replace('`', "\\`");
    substitute_agent(&mut ours, &escaped);
    let events = ours["hooks"].as_object().cloned().unwrap_or_default();
    let hooks = root
        .entry("hooks")
        .or_insert_with(|| Value::Object(Map::new()));
    let hooks = hooks
        .as_object_mut()
        .ok_or_else(|| "settings.json: \"hooks\" is not an object".to_string())?;
    for (event, groups) in events {
        let list = hooks
            .entry(event.clone())
            .or_insert_with(|| Value::Array(vec![]));
        let list = list
            .as_array_mut()
            .ok_or_else(|| format!("settings.json: hooks.{event} is not an array"))?;
        if list.iter().any(is_ours) {
            continue;
        }
        list.extend(groups.as_array().cloned().unwrap_or_default());
    }
    Ok(render(root))
}

fn is_our_hook(h: &Value) -> bool {
    h.get("command")
        .and_then(Value::as_str)
        .is_some_and(|c| c.contains("shuai-agent"))
}

/// Inverse of [`merge_claude_settings`]: drop the hook entries that run `shuai-agent` (and the
/// groups / events / `hooks` key that become empty because of it; nothing else is touched).
pub fn remove_claude_settings_hooks(existing: &str) -> Result<String, String> {
    let mut root = parse_settings(existing)?;
    if let Some(Value::Object(hooks)) = root.get_mut("hooks") {
        let mut emptied = Vec::new();
        for (event, list) in hooks.iter_mut() {
            let Value::Array(groups) = list else { continue };
            if !groups.iter().any(is_ours) {
                continue;
            }
            groups.retain_mut(|g| {
                if !is_ours(g) {
                    return true;
                }
                let Some(Value::Array(hs)) = g.get_mut("hooks") else {
                    return true;
                };
                hs.retain(|h| !is_our_hook(h));
                !hs.is_empty()
            });
            if groups.is_empty() {
                emptied.push(event.clone());
            }
        }
        for e in emptied {
            hooks.shift_remove(&e);
        }
        if hooks.is_empty() {
            root.remove("hooks");
        }
    }
    Ok(render(root))
}
