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
- App icon (light, dark, tinted) generated from configuration; see [App icon](development/icon.md).

There is no TestFlight or App Store build; users build and sign from source.

## Immersive terminal: device validation

The terminal can use more of the screen: `ChromePolicy` (pure; rules in
[Chrome policy](design/interaction.md#chrome-policy)), Window tabs: Automatic, the hardware-keyboard
accessory bar setting, Full Screen mode (⌃⌘F and a handle menu) and Connect or Disconnect in the host
context menu. What remains is validating it on a real iPad.

To check on a real iPad (checklist B5 and B6): one `window-change` per toggle and a clean Claude redraw; the terminal
keeping first responder when chrome changes; window controls overlapping the strip or handle under
Stage Manager and iPadOS 26 windowing; Magic Keyboard attach and detach without the bar flickering;
⌃⌘F delivered while the terminal has focus; VoiceOver, Switch Control and Full Keyboard Access
reaching the handle menu.

## Known issues and follow-ups

Not scheduled, in no particular order:

- Loss detection takes about 45 to 60 seconds (keepalive 15 s, three misses). Shortening it trades
  speed against false drops on unstable networks.
- Time-based tests can fail on a loaded runner: `TmuxMonitorTests` (`silentAttachProbeTimesOutRetriesThenEnds`
  asserts a wall-clock bound, `slowAttachProbeStillSucceedsOnALaterAttempt` uses 40 ms timeouts).
  UI tests that failed once and passed on rerun: `testAddHostAppearsInSidebar` (simulator keyboard
  focus) and `testClosingAPaneFromItsContextMenuAsksFirst` (long-press menu).
- CI builds with Xcode 26.6 against iOS 26; a newer local SDK behaves differently in the
  accessibility tree, menus and `performAccessibilityAudit`. Several UI tests passed locally and
  failed on CI for that reason. Running the UI suite on an iOS 26 simulator locally would catch it.
- The sidebar settings button reports 36 pt (the system's icon-only bottom-bar button); a 44 pt frame
  made the bottom bar buttons report as not hittable.
- A host row may announce its waiting count twice under VoiceOver (row value and the count badge).
- The tmux menu items have no chords: the terminal's priority key commands own them and a second
  delivery path could run a non-idempotent tmux action twice.

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
