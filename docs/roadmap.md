# Roadmap

## Current status

**v1 is feature-complete; real-device validation is pending.** Features are covered by unit,
integration, simulator and UI tests, and a gated live UI test drives the full flow against a real
server from the simulator. What remains is the [device QA checklist](development/device-qa-checklist.md)
on physical iPads (IME, hardware keyboards, Stage Manager, background and push).

v1 contains:

- Rust core with UniFFI bindings; SSH (password, key, keyboard-interactive), TOFU, keepalive,
  automatic reconnect.
- Keys: ed25519/ECDSA generation; OpenSSH, PKCS#1, PKCS#8 and SEC1 import; Keychain storage.
- Terminal on libghostty: IME, CJK, mouse, bracketed paste, OSC 52/9/777, zoom, themes, Option as Alt,
  keyboard bars with the Claude strip.
- Host management; tmux attach with plain-shell fallback; live tmux tree, quick switcher,
  hardware shortcuts.
- Claude Code integration: one-tap install/remove, badges, native permission cards with offline
  fallback, attention navigation; Codex via `notify`.
- Status-only ntfy push with `shuai://` deep links; local notifications.

There is no TestFlight or App Store build; users build and sign from source.

## v1.x

- Image paste: upload the image to the server and insert its path.
- SFTP file browser (and SFTP-based uploads).
- Secure Enclave keys.
- iCloud sync of host profiles.
- Shortcut customization UI (the `ShortcutMap` JSON format already exists).
- ⌘. sends Esc.

## v2

- APNs relay with Live Activities and lock-screen approvals.
- Clean-room, MIT-licensed mosh-compatible transport in Rust ([ADR 0004](adr/0004-mit-license-no-mosh.md)).
- Native `tmux -CC` splits with per-pane views ([ADR 0006](adr/0006-tmux-control-side-channel.md)).
- Android app (Jetpack Compose on the same Rust core, libghostty-vt renderer).
