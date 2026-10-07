# Claude Code integration

shuai does not wrap the `claude` CLI. You keep running `claude` (or `codex`) inside tmux as usual;
a small server-side helper, `shuai-agent`, receives Claude Code hook events and the app reads them
over your existing SSH connection. Without the integration shuai is still a complete SSH + tmux
terminal.

## Enable AI integration

Connect to the host, then long-press (or right-click) the host row and choose
**Enable AI integration…**. The sheet first inspects the host and shows exactly what it would do;
nothing changes until you tap **Install**. The steps, each skipped when already done:

1. **Probe** (read-only): OS and CPU (`uname -sm`), home directory, shell, tmux version, `claude`
   and `codex` paths, an installed agent version, an existing plugin, Codex `notify`, the tmux block.
2. **Upload `shuai-agent`** to `~/.shuai/bin/shuai-agent` (mode 755). The app bundles static
   binaries for Linux x86_64 and aarch64; other platforms are reported as unsupported. The file
   is uploaded beside the target and moved into place, so a running agent is never overwritten
   in place.
3. **Install the Claude Code plugin**:
   `claude plugin marketplace add moilk/shuai && claude plugin install shuai@shuai`.
   If the host cannot reach GitHub, the app uploads the same marketplace (embedded in the app) to
   `~/.shuai/plugin-marketplace` and installs from there. If there is no `claude` CLI, or both
   fail, the hook entries are merged into `~/.claude/settings.json` without touching your own
   hooks (the original is kept once as `settings.json.shuai-bak`).
4. **Codex** (only if `codex` is found): sets `notify = ["<home>/.shuai/bin/shuai-agent", "codex-notify"]`
   in `~/.codex/config.toml`. If Codex already has a different `notify`, the app asks; choosing
   **Replace and retry** replaces it and keeps the original as `config.toml.shuai-bak`.
5. **tmux settings**: appends a block between `# >>> shuai >>>` and `# <<< shuai <<<` to
   `~/.tmux.conf` containing `set -g allow-passthrough on` (tmux 3.3+), `set -g set-titles on` and
   `set -g extended-keys on` (tmux 3.2+), then `tmux source-file` if a server is running.
6. **Write notification settings** to `~/.shuai/config.toml` (host id, host name, ntfy settings;
   see [Notifications](notifications.md)).
7. **Run diagnostics**: `shuai-agent doctor`.

The host row then shows "AI integration <version>", or "(update to <version>)" when the installed
agent is older than the one bundled with the app; run Enable AI integration again to update.

Requirements on the host: Linux on x86_64 or aarch64, a POSIX shell, and Claude Code with plugin
support (or a writable `~/.claude/settings.json`). tmux is recommended.

## Remove AI integration

**Remove AI integration…** in the same menu undoes everything the install did:

- `claude plugin uninstall shuai@shuai` and `claude plugin marketplace remove shuai`, plus removal
  of shuai hook entries from `~/.claude/settings.json`;
- the marked block from `~/.tmux.conf` and `~/.config/tmux/tmux.conf` (a file left empty is deleted);
- shuai's `notify` from `~/.codex/config.toml`;
- stops any running `shuai-agent` and deletes `~/.shuai` (binary, event log, config) and
  `~/.claude/plugins/cache/shuai`.

Your other configuration is not touched.

## Badges

Each pane running an agent gets a status badge in the sidebar. Sessions and windows show the most
urgent badge of their panes:

| Symbol | Meaning | Priority |
|---|---|---|
| raised hand | needs approval | highest |
| question bubble | needs input | |
| warning triangle | failed | |
| gear | working | |
| check mark | done (until seen) | |
| moon | idle | lowest |

A host row also shows the most urgent badge of all its panes, so it stays visible when the host or
its sessions are collapsed. The number of agents waiting for you is shown next to it with a raised
hand symbol.

The orange number on a host row counts sessions waiting for you. State changes of a session you
are not looking at appear as short in-app banners (notices at the top of the terminal area):

- One banner per session; a newer state of the same session replaces it.
- Tap a banner to jump to that agent's pane; the **x** dismisses it. A banner also goes away on its
  own after a few seconds, and does not come back once dismissed or expired.
- No banner for the session you are viewing, and it is removed when the session ends or the
  request is answered.
- Needs input and done are shown as attention and success, a failure as an error. Permission
  requests are never banners: they stay cards, which are drawn above the banners.

How state is derived: the app follows the agent's event stream (`shuai-agent watch`), replays
history after a reconnect without re-alerting, marks sessions whose tmux pane disappeared as
ended, and every 60 seconds cross-checks with `claude agents --json` when `claude` is available.
Details: [Agent protocol](../design/agent-protocol.md).

## Permission cards

When Claude asks for permission (a Bash command, a file edit, ...):

- **The app is connected to that host**: a card appears at the top right with the tool, a preview
  (command, or a diff for edits and writes), the working directory and an optional message to
  Claude. **Allow** (⌘↩) or **Deny** (⌘⌫) answers it and Claude continues immediately. **Show**
  jumps to the pane.
- **No app is watching the host**: the hook sees that nobody is present and exits at once without
  output, so Claude shows its own dialog in the terminal. Nothing ever blocks Claude.
- **The app is watching but you do not answer**: the hook waits up to 110 seconds, then falls back
  to Claude's own dialog in the same way.
- If you answer in the terminal instead (for example with the Yes/Always/No strip), the card
  disappears.

Card content comes from the server and is treated as untrusted text: it is length-capped and
never interpreted.

## Finding the agent that needs you

- **⌘K** opens the quick switcher: fuzzy search over hosts, tmux sessions, windows and panes
  (names, commands, working directories, agent titles). Sessions that want you are listed first:
  needs approval, then needs input, then failed, then done-and-unseen.
- **⌘⇧A** jumps straight to the next agent needing attention, cycling across all connected hosts,
  and marks it seen.

## Codex

Codex is supported through its `notify` program only. Codex reports finished turns
(`agent-turn-complete`), so a Codex session shows as done (with its last message) and can trigger
a "Codex finished" push. There are no working/approval states and no permission cards for Codex.

## Local notifications

Settings > Notifications > **Notify when an agent needs me** posts local notifications for
agent events while the app is in the background. iOS suspends apps shortly after they leave the
screen, so this is best effort; for reliable background alerts use [ntfy push](notifications.md).
