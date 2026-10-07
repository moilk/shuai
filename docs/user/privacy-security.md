# Privacy and security

## Direct SSH, no relay

The app connects straight to your server over SSH. There is no shuai server, account, relay or
telemetry. Agent status travels inside the same SSH connection (an extra exec channel running
`shuai-agent watch`); permission answers go back the same way (`shuai-agent respond`).

## What is stored on the iPad

| Data | Where |
|---|---|
| Private keys | Keychain (`AfterFirstUnlockThisDeviceOnly`), unencrypted inside the Keychain; key metadata in a JSON file in Application Support |
| Saved passwords | Keychain (`AfterFirstUnlockThisDeviceOnly`) |
| "Ask each time" passwords | Memory only; cleared on disconnect, remote exit, auth failure |
| Host profiles | JSON file in Application Support |
| Trusted host keys | OpenSSH `known_hosts` file in Application Support |
| ntfy topic and token | Keychain; the topic is masked on screen until you tap Show |
| Preferences | UserDefaults (no secrets) |
| Sidebar expansion | UserDefaults: only the hosts and sessions you collapsed or expanded against the default, as host UUID and session name. No other tmux data is stored |

Deleting the app deletes all of it, including the keys.

## Host key verification

Trust on first use: the first key of a host is shown for confirmation; a changed key is refused
unless you explicitly accept the replacement. Passwords are only sent, and "Ask each time"
passwords only requested, after the host key has been verified.

## What is stored on the server

With AI integration enabled, `~/.shuai` (mode 0700, files 0600) holds:

- `events.jsonl` (+ one rotated file, about 5 MiB each): the hook events, which include prompts,
  tool input and Claude's messages, so the app can show state and permission previews;
- `config.toml`: host id, host name and ntfy settings (topic and token);
- runtime files (presence, sequence counter, permission responses, push gate, `agent.log`).

This is the same kind of data Claude Code already keeps under `~/.claude`. Remove AI integration
deletes the whole directory.

## What leaves the server

Only if you enable ntfy push, and only while no app is watching: an HTTPS request to your ntfy
server with a fixed status title, the host name and the tmux `session › window index` (window name
only if you opt in), a `shuai://` click link with the host id and pane id, and a priority. Never
prompts, commands, tool input, messages, paths or the working directory. See
[Notifications](notifications.md).

The ntfy topic and token are never logged by `shuai-agent`; errors that might quote them are
redacted, and `shuai-agent doctor` reports only whether ntfy is configured.

Copy topic puts the topic on this device's pasteboard for two minutes. It is also offered to your
other devices through Universal Clipboard, and a copy pasted there is not removed. A revealed topic
is hidden again when the app leaves the foreground or you leave the page.

## Untrusted input

The app treats everything from the server as untrusted: terminal output, tmux names, agent events
and `shuai://` links. Clipboard writes requested by the server (OSC 52) need your permission.
Details for contributors: [Security model](../design/security-model.md).

## Reporting a vulnerability

Please report security issues privately through GitHub's "Report a vulnerability" (Security tab of
the repository) rather than a public issue.
