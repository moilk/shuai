# apple/ (Swift package + iPad app)

Build the core first: `scripts/build-xcframework.sh` (outputs gitignored). Logic tests:
`cd apple/ShuaiKit && swift test`. Simulator engine tests: `xcodebuild test -scheme ShuaiKit-Package`
in `apple/ShuaiKit`. App: `cd apple/App && xcodegen generate && xcodebuild test -scheme Shuai`.

## Targets

- `ShuaiCore`: generated UniFFI bindings (Swift 5 mode) + `Redaction.swift`. Never edit `Generated/`.
- `ShuaiPlatform` (Swift 6): `Connection` actor, `Shell`/`ExecSession`, `KeychainKeyStore`,
  `KnownHostsStore`/`TOFUVerifier`, `ReconnectController`.
- `ShuaiTerminal` (Swift 6): `TerminalEngine`, `GhosttyEngine`, `TerminalView`, key and bar models.
- `ShuaiApp` (Swift 6, testable with `swift test`): everything app-level that is not a scene, including
  `Notices/` (`NoticeCenter`, `NoticeQueue`) and `ConnectionPresentation`.
- `apple/App`: entry, root views, menus, settings, DEBUG launch code. Links only the `ShuaiApp`
  product (several dynamic products duplicate classes at runtime).

## Rules

- Streams: `Shell`/`ExecSession` pump every stream into a bounded queue; never read a stream lazily
  from UI code. A wrapper retains its `Connection`; the connection closes with the last reference.
- Host keys: `TOFUVerifier` rejects a changed key unless `decideChanged` accepts it. Password hosts
  use `FfiAuth.passwordPrompt` so the password is asked only after host key verification.
- Secrets go to the Keychain (`AfterFirstUnlockThisDeviceOnly`), never UserDefaults or logs.
- Ghostty-dependent code is `#if canImport(GhosttyTerminal)`; keep logic platform-neutral so
  `swift test` on macOS covers it.
- libghostty: `Lakr233/libghostty-spm` pinned `exact:` in `Package.swift` (ADR 0001); bump deliberately.
- All bytes for the remote, including engine replies, leave through `onInput`; device-query replies
  pass `DeviceReplyGuard`. OSC 52 is `ask`: answer `ClipboardRequest.respond(allow:)`.
- Option-as-Alt is handled in `TerminalView.pressesBegan` (`OptionAsAlt`), not by Ghostty's option.
- Claude strip mapping is fixed: Yes=`1`, Always=`2`, No=Esc (reasons in `AccessoryBarModel.swift`).
- Shortcuts: `ShortcutMap.defaults` -> `terminalBindings` -> `TerminalView.keyBindings` (priority key
  commands). App-level chords live in `ShuaiMain.swift` menus. ⌘1-9 are list positions.
- tmux: `TmuxMonitor` owns the control side channel and never writes to the PTY; `TmuxActions`
  targets the PTY client (`switch-client -c TTY`); kill window/pane always via
  `pendingConfirmation`.
- Agent: `AgentHub` keys hosts by `HostProfile.id` and maps to the remote hostname the agent reports.
  Permission previews render untrusted input with `Text(verbatim:)`, length-capped.
- `DeepLink` parsing stays strict (one UUID `host`, optional `%N` pane).
- Transient messages go through `NoticeCenter` (ADR 0008): views own no timers, sources post `Notice`
  values, per-host keys include the host id, text goes through `Notice.sanitize` and renders with
  `Text(verbatim:)`.
- Connection state UI is derived from `ConnectionPresentation`; only states without a usable live
  channel (connecting, signing in, host key, failed) block the terminal.
- Top stack, from the top: window tab strip, connection strip, notices; permission cards are drawn on
  top and the strip and notices reserve their column (`docs/design/interaction.md`).
- DEBUG-only code and launch arguments are wrapped in `#if DEBUG`; add new argument names to
  `scripts/check-no-debug-launch.sh` (e.g. `-debugConnectionState`).
- Signing: never put a team or bundle id in `project.yml`; use `Signing.xcconfig` + gitignored
  `Local.xcconfig`. The `.xcodeproj` and `Generated/Info.plist` are generated, never committed.
- Swift must compile with CI's older Xcode: e.g. write `_ = expr` in `Void` closures.

## Tests

- Swift Testing for packages, XCTest for the app's UI tests. Inject clocks and timers.
- Real-SSH tests need `SHUAI_FFI_TESTKIT=1` for both `build-xcframework.sh` and `swift test`.
- `TmuxRealTests` run against a private local tmux server (macOS only).
- UI tests use `-uiTesting` with `-debugTmuxFixture` / `-debugAgentFixture`; use a dedicated
  simulator when several run in parallel.
- `ShuaiE2ETests` run only with `SHUAI_E2E_HOST_FILE` (host JSON kept outside the repo).

More: `docs/design/architecture.md`, `docs/development/building.md`, `docs/development/testing.md`.
