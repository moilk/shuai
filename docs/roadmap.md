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

## Next: immersive terminal

Goal: give the terminal more of the screen. The foundation is merged: `ChromePolicy` (pure; rules in
[Chrome policy](design/interaction.md#chrome-policy)), `FullScreenState`, and the persisted settings
`tabStrip`, `hardwareKeyboardBar` and `fullScreen` in `AppSettings`. Nothing in the UI uses them yet.
The remaining steps, in this order, each a small PR that starts with a failing test:

1. **Window tabs: Automatic.** Hide the tab strip when the viewed session has one window *and* the
   host has one session (hiding on window count alone would leave touch-only users no way to reach
   another session while the sidebar is collapsed). Setting Terminal > Window tabs: Automatic
   (default) or Always; no "Never". Needs a single-window fixture: a DEBUG launch argument
   registered in `scripts/check-no-debug-launch.sh`.
2. **Accessory bar with a hardware keyboard.** Setting Keyboard > With a hardware keyboard: Show the
   floating bar (default) or Hide. It is hidden only with a hardware keyboard and no software
   keyboard on screen; there is no global Off, because touch-only users need Esc and Ctrl. Without
   the bar the Claude permission cards answer with ⌘↩ (Allow) and ⌘⌫ (Deny), the cards have no
   "Always", and without the AI integration `1`, `2` and Esc are typed directly (keyboards without
   an Esc key: Ctrl-[, or remap Caps Lock or Globe to Escape in iPadOS Settings). Do not reveal the
   bar when a permission is pending: it would resize the terminal.
3. **Full Screen mode.** Explicit, not auto-hiding: hiding the navigation bar on demand changes the
   safe area, resizes the terminal and makes tmux and Claude redraw on every reveal. Full screen
   hides the navigation bar, status bar and home indicator, collapses the sidebar (restored on exit
   by `FullScreenState`) and shows a small handle at the top trailing edge (docked into the tab strip
   when it is shown): status symbol only, 44 pt target, a menu with the host and status, Reconnect or
   Disconnect, Show Sidebar, Quick Switcher and Exit Full Screen. The handle is a menu overlay, so
   it never resizes the terminal, and it is prominent when the connection is not healthy or a
   permission is pending. Shortcut ⌃⌘F through `ShortcutMap` (`toggleFullScreen`) only; the View
   menu item carries no chord, because a second delivery path would toggle straight back (fallback
   ⇧⌘F if iPadOS reserves ⌃⌘F). Enter and leave in one state change so the terminal resizes once;
   leave through the handle, the chord or the VoiceOver escape gesture. No three-finger or top-edge
   gesture: iPadOS and the terminal already use them.
4. **Connect and Disconnect in the host context menu**, a touch path that does not need the
   navigation bar.

To check on a real iPad: one `window-change` per toggle and a clean Claude redraw; the terminal
keeping first responder when chrome changes; window controls overlapping the strip or handle under
Stage Manager and iPadOS 26 windowing; Magic Keyboard attach and detach without the bar flickering;
⌃⌘F delivered while the terminal has focus; VoiceOver, Switch Control and Full Keyboard Access
reaching the handle menu.

## Known issues and follow-ups

Not scheduled, in no particular order:

- A reconnect attempt that was replaced can still show its password prompt late; that answers the
  live attempt's prompt with nothing and ends the session (marked `withKnownIssue` in
  `SessionControllerTests`).
- Loss detection takes about 45 to 60 seconds (keepalive 15 s, three misses). Shortening it trades
  speed against false drops on unstable networks.
- Editing a host profile while it is disconnected creates a new session controller and engine that
  the terminal view does not pick up (`TerminalContainerRepresentable.updateUIView` ignores a new
  engine), so the screen stays on the old engine until the host is reselected.
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
