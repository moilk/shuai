# shuai Claude Code plugin

Forwards Claude Code hook events to `shuai-agent`, so the shuai iPad app can show agent status and
answer permission requests. Every hook runs:

```sh
[ -x "$HOME/.shuai/bin/shuai-agent" ] || exit 0; exec "$HOME/.shuai/bin/shuai-agent" hook <Event>
```

The app uploads the binary to `~/.shuai/bin/shuai-agent` over SSH; without it the hooks are a
silent no-op.

- Hooks: `SessionStart`, `SessionEnd`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`,
  `Notification`, `Stop`, `SubagentStop`, `StopFailure` (all `async`, timeout 15 s) and
  `PermissionRequest` (synchronous, timeout 120 s). For a permission request the agent waits up to
  110 s for an answer from the app and exits immediately when no app is connected; in both cases
  Claude then shows its normal local dialog.
- Install (normally done by the app's "Enable AI integration…"):
  ```sh
  claude plugin marketplace add moilk/shuai
  claude plugin install shuai@shuai
  ```
- Uninstall: `claude plugin uninstall shuai@shuai && claude plugin marketplace remove shuai`.
- Validate after editing: `claude plugin validate plugin --strict`.

The marketplace manifest is `.claude-plugin/marketplace.json` at the repository root. The plugin
version must equal the Rust workspace version (checked by `core/shuai-agent/tests/plugin.rs`).
Protocol details: [docs/design/agent-protocol.md](../docs/design/agent-protocol.md).
