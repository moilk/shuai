# shuai — project conventions

iPad AI-coding SSH terminal. Rust core + UniFFI, native Swift UI. Plan: `docs/plan/`, decisions: `docs/adr/`.

## Layout
- `core/` Cargo workspace (shuai-proto, -keys, -ssh, -tmux, -agentkit, -ffi, -agent, -testkit (dev only: in-process SSH server), uniffi-bindgen)
- `apple/ShuaiKit` Swift package: `ShuaiCore` (binaryTarget ShuaiCoreFFI + generated bindings, Swift 5 mode) and `ShuaiPlatform` (Swift 6: Keychain key store, known_hosts/TOFU, `Connection`/`Shell` wrappers)
- `apple/ShuaiKit/Sources/ShuaiTerminal` terminal module (see below)
- `apple/App` iPad app (XcodeGen `project.yml`; the .xcodeproj is generated, never committed)
- `plugin/` Claude Code plugin, `android/` future, `scripts/` build scripts

## Environment
xcode-select may point at CommandLineTools. Always prefix Xcode commands with
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

## Commands
- Rust: `cd core && cargo test --workspace && cargo clippy --workspace --all-targets -- -D warnings && cargo fmt --check`
- XCFramework + bindings: `scripts/build-xcframework.sh` (idempotent; outputs are gitignored). Add `SHUAI_FFI_TESTKIT=1` to also build the `testkit` feature (in-process SSH server) into every slice and enable the real-SSH Swift tests (dev/CI only, never ship that build).
- Swift package: `cd apple/ShuaiKit && swift test` (macOS host; for the real-SSH `ConnectionTests` build the xcframework with `SHUAI_FFI_TESTKIT=1` and run `SHUAI_FFI_TESTKIT=1 swift test`)
- FFI testkit Rust test: `cd core && cargo test -p shuai-ffi --features testkit`
- App: `cd apple/App && xcodegen generate && xcodebuild test -scheme Shuai -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)'`
- Agent cross-build: `cd core && cargo zigbuild --release -p shuai-agent --target x86_64-unknown-linux-musl`

## Rules
- Strict TDD where there is logic: failing test first (commit `test: ...`), then implementation (`feat: ...`).
- Keep the FFI layer thin; logic lives in Rust crates and is tested with `cargo test`.
- Conventional commits (feat/fix/test/docs/chore/ci/refactor).

## FFI conventions (core/shuai-ffi)
- **Boundary**: session/stream-level API only (`SshConnection`, `ShellStream`, `ExecStream`, `TmuxController`, `ReconnectPolicy`); never per-byte or per-cell calls. Terminal bytes go Rust -> platform terminal engine directly.
- **Records vs objects**: plain data (`KeyMaterial`, `FfiTopology`, `FfiTmuxCommand`, events, config) are `uniffi::Record`/`Enum`, tmux ids are strings (`$0`, `@1`, `%2`). Anything stateful or owning I/O (connection, streams, controller, policy) is a `uniffi::Object`. Enum variants use named fields (`Data { bytes }`).
- **Naming**: Rust types that have a nicer Swift wrapper are `Ffi`-prefixed or live in ShuaiCore only; Swift-facing wrappers (`Connection` actor, `Shell`, `ExecSession`, `KeychainKeyStore`, `KnownHostsStore`, `TOFUVerifier`) are in ShuaiPlatform. Swift error cases are PascalCase (`FfiSshError.HostKeyRejected`).
- **Errors**: one flat enum per domain (`FfiKeyError`, `FfiSshError`, `FfiTmuxError`) mapped 1:1 from the pure crates' errors; no panics across the boundary.
- **Async**: exported with `#[uniffi::export(async_runtime = "tokio")]`. Foreign (Swift) traits use `#[uniffi::export(with_foreign)]` + `#[async_trait::async_trait]` for async methods (UniFFI 0.32 supports this): `HostKeyVerifierCallback` and `KbdPrompterCallback` are async (they ask the user), `SignerCallback` is sync (may block on biometrics, runs on a blocking-capable thread).
- **Drain requirement**: every open `ShellStream`/`ExecStream` must be read continuously (`next_event()` until `Closed`), even if the output is ignored, or the whole SSH session (all channels, keepalive) stalls. The Swift `Shell`/`ExecSession` wrappers start a pump task per stream (`PumpCore`) feeding a byte-bounded, coalescing queue (64 MiB per stream, `Connection.defaultStreamBufferBytes`); terminal bytes are never dropped. When the queue is full the pump waits for the consumer, which stalls the whole session until the consumer resumes (documented trade-off, see `EventPump.swift`). Never read a stream lazily from UI code. A `Shell`/`ExecSession` retains its `Connection`; the `Connection` disconnects when the last reference goes away.
- **Upload**: shuai-ssh has no SFTP yet; `SshConnection.upload` streams bytes to `cat > PATH && chmod -- MODE PATH` (path shell-quoted, mode masked to 0o7777) over an exec channel (`upload_command`), writing stdin while concurrently reading events so an early remote exit cannot hang it. Replace with SFTP later without changing the API.
- **Keys**: private keys cross as unencrypted OpenSSH PEM strings; Swift keeps them in the Keychain (`io.github.moilk.shuai.keys`, AfterFirstUnlockThisDeviceOnly) and metadata in a JSON file. `import_key` normalises every supported format to that PEM.
- **Testkit**: `core/shuai-testkit` is the in-process russh server (user `alice`/`secret`, `kbd`/`123456` for keyboard-interactive; exec `ok`, `fail`, `stream`, `cat`, `cat > path` uploads, shell echoes input) shared by shuai-ssh tests and, behind the `testkit` cargo feature, exported to Swift as `startTestSshServer()`. The feature is compiled into all slices of the testkit xcframework so bindings match; `SHUAI_FFI_TESTKIT=1` in the environment of `swift test` makes `Package.swift` define `SHUAI_TESTKIT` for the real-SSH Swift tests (an env var, because SwiftPM caches manifest evaluation and would miss a marker file).
- **Testkit guard**: a `SHUAI_FFI_TESTKIT=1` xcframework must never ship. `scripts/build-xcframework.sh` prints a loud warning in that mode and runs `scripts/check-no-testkit.sh` (`nm` for `start_test_ssh_server`) after every normal build; CI runs the guard explicitly. Release/archive steps must run it too.
- **Host keys**: `TOFUVerifier` rejects a *changed* key unless `decideChanged` is given (the `decide` prompt only sees unknown hosts); accepting replaces the old entry (`known_hosts_replace`).
- **Reconnect**: `ReconnectController` (ShuaiPlatform) drives the exported `ReconnectPolicy` with injectable clock/sleep and network/foreground `AsyncStream`s.

## Terminal module (ShuaiTerminal)
- Engine: libghostty via `Lakr233/libghostty-spm`, pinned `exact: 1.6.20261003` (ADR 0001). Bump deliberately; API churns.
- `TerminalEngine` protocol (platform-neutral) + `GhosttyEngine` (iOS only). All bytes for the remote, including engine
  replies (DA1, DECRQM, kitty `CSI ? u`), come out of `onInput`. OSC 52 is `clipboard-write = ask`: the app must answer
  `ClipboardRequest.respond(allow:)`.
- `TerminalView` subclasses libghostty's `UITerminalView` (IME inline preedit, selection, scroll, pointer, pinch/⌘± zoom,
  hardware keys via Ghostty's encoder incl. kitty). Platform-neutral logic: `KeyEncoder` (fallback), `AccessoryBarModel`,
  `ResizeDebouncer`, `FontSizeModel`, `EchoTransform`.
- Ghostty-dependent code is `#if canImport(GhosttyTerminal)` (iOS only). Logic tests: `swift test` (macOS). Engine tests need
  the simulator: `cd apple/ShuaiKit && xcodebuild test -scheme ShuaiKit-Package -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)'`.
- Debug playground: run the app with launch arg `-debugTerminal` (DEBUG builds) to replay `fixtures/recordings/*pre-exit.out` or echo input.
- Not CI-testable: real-device IME (see ADR "Pending manual IME test").
- Theme: `TerminalTheme` (default `claudeDark`; `claudeLight`) is applied as both Ghostty light/dark variants, so the terminal ignores system appearance; contrast (WCAG >= 3.0 for colors 1-15) is unit-tested. Scrollback is capped via `scrollback-limit` (bytes; `ScrollbackPolicy`, 10k lines default).
- Hardware Option->Alt is mapped in `TerminalView.pressesBegan` (`OptionAsAlt`), not trusted to Ghostty's `macos-option-as-alt` on iOS. Claude strip: Yes=`1`, Always=`2`, No=Esc (see AccessoryBarModel comments).

## App shell (ShuaiApp target + apple/App)
- `ShuaiApp` (ShuaiKit, Swift 6, testable with `swift test`): `HostProfile`/`HostStore` (JSON v1 in Application Support, atomic, legacy-array migration, refuses newer schema), `KeyLibrary`, `PasswordStore` (Keychain service `io.github.moilk.shuai.passwords`), `AppSettings`, `TmuxLaunch`, `SessionController` (@MainActor @Observable state machine over `ConnectionFactory`/`RemoteConnection`/`RemoteShell`; fakes in tests, `LiveConnectionFactory` in the app), `SessionRegistry`.
- tmux attaches via `Connection.openPtyExec("tmux new -A -s 'NAME'")` (FFI `open_pty_exec`: exec on a PTY channel, nothing typed). Reconnect uses `ReconnectController.adopt()` after the first connect; reattach nudges the window height to force a tmux redraw.
- The app links only the `ShuaiApp` product (linking several dynamic package products duplicates classes at runtime). Simulator builds are ad-hoc signed (`CODE_SIGN_IDENTITY[sdk=iphonesimulator*]: "-"`) because the Keychain fails with -34018 unsigned.
- Host key before password: password hosts (`.ask`, or no stored password) use `FfiAuth.passwordPrompt` (`PasswordPromptCallback`, Rust `AuthMethod::PasswordPrompt`), asked by the SSH layer only after host key verification; stored passwords/keys are sent as before. A typed `.ask` password lives in memory only, is cleared on user disconnect, remote exit, give-up and auth failure.
- tmux missing: `tmux new -A` exiting 127 (or a short "not found" output) right after open makes `SessionController` open a plain login shell on the same connection and set `notice` (`tmuxMissingNotice`, non-blocking banner); later reconnects of that session skip tmux. A fresh `connect()` retries tmux.
- Release guard: `scripts/check-no-debug-launch.sh` builds Release for the simulator and fails if `debugAutoAcceptHostKey`/other DEBUG launch-arg strings are present (run it with release steps; DEBUG args are all `#if DEBUG`).
- DEBUG launch args: `-uiTesting` (ephemeral stores), `-debugHostFile <json {name,host,port,user,keyPath,tmuxSession?}>`, `-debugAutoAcceptHostKey`, `-debugSendAfterConnect <text>` (results via NSLog `[debug]`). Keep the JSON outside the repo.
- Gotcha: `swift test` for ShuaiAppTests real-SSH tests needs `SHUAI_FFI_TESTKIT=1` (xcframework built with the testkit).

## tmux native management (ShuaiApp)
- `TmuxMonitor` (per `SessionController`, started after every tmux attach, stopped on teardown): second channel on the same connection running `tmux -C attach -t =S:` via `execStream` (no PTY), first stdin line `refresh-client -f no-output`, always drained; structural notifications are debounced (100 ms) into one `list-panes -a -F` + `list-clients`, renames patch the tree. tmux < 3.2 is polled with one-shot exec; missing tmux or tmux disabled leaves it off. Commands from the control client never move the terminal: `TmuxActions` names the PTY client (`switch-client -c TTY`, tty found with `list-clients` + `pick_pty_client`, sticky) and switches session first when acting on another session.
- Shortcuts: `ShortcutMap` -> `ShortcutMap.terminalBindings` -> `TerminalView.keyBindings` (priority `UIKeyCommand`s while the terminal is first responder); ⌘K also lives in the app's Go menu for when the sidebar has focus. ⌘1-9 are list positions, not tmux indexes.
- Real-tmux tests (`TmuxRealTests`, macOS only) run on a private server (`tmux -L shuaim4 -f /dev/null`) and kill it afterwards. UI tests use a made-up topology (`-debugTmuxFixture`). Use your own simulator device for UI tests when other agents run sims (shared devices make XCUITest time out).

## CI
CI uses Xcode 26.6, older than the local Xcode 27. Avoid constructs only the newer compiler accepts (e.g. a single-expression closure whose value type mismatches `Void`: write `_ = expr`). Check new Swift against that when in doubt.
CI's rust job runs on Ubuntu 24.04 with its stock tmux 3.4, so the real-tmux tests there cover the escaped-separator path.
- tmux version compatibility: `-F` output is split with `shuai_tmux::parse::split_fields`, never `split(FIELD_SEP)` directly. tmux 3.2/3.3/3.6+ print the `\x1f` separator raw, 3.4/3.5 print it as the four characters `\037`; values are always escaped by tmux, so an unescaped `\037` is a separator. Fixtures: `core/shuai-tmux/tests/fixtures/listpanes-tmux*.txt`; run the real-tmux tests against a specific build with `SHUAI_TMUX_BIN=/path/to/tmux cargo test -p shuai-tmux --test real_tmux`.
- PTY client targeting: with several clients on one session (laptop etc.) `TmuxMonitor` picks ours via `ClientProcessTree` (`ps -A -o pid= -o ppid=` on the host: the candidate sharing the deepest ancestor with the control client, both being children of our SSH connection), falling back to the Rust heuristic (size, age). The tty is sticky per `start`, forgotten on every restart. `PaneBadge`/`PaneBadgeProvider` live in `AgentHooks.swift` (M5); `PaneBadge.swift` only adds symbol/tint/priority. Kill window/pane always go through `TmuxActions.pendingConfirmation`.

## Agent integration in the app (M4+M5 wiring)
- `AgentHub` (ShuaiApp) owns one `AgentMonitor` per connected host and is the app's `PaneBadgeProvider`/`PaneAgentInfoProvider`. **Host key**: the UI keys hosts by `HostProfile.id` (UUID, `uuidString` where the provider API takes a `String`); the agent's events carry the *remote hostname*. Per connection the hub probes it (`AgentHostProbe`: `SHUAI_HOSTNAME` or `uname -n`, same rule as the agent, plus agent version and `claude` path), creates the monitor with `host: <hostname>` and translates both ways (`profileID(for:)`, `badge(host: <uuid>, ...)`). No agent installed -> no monitor, status `.notInstalled`; older than bundled -> `.outdated`.
- `SessionController.agentRemote`/`onAgentRemoteChange` expose the live connection (`ConnectionAgentRemote`); `SessionRegistry(agentHub:)` wires connect/disconnect/remove.
- ⌘K uses `AttentionRanker` (permission > input > failed > unseen done); ⌘⇧A (`ShortcutAction.nextAttention`, UI-level) cycles `AgentHub.nextNeedingAttention` across hosts then `selectPane` + `markSeen`. Banners: `AgentBannerView`/`InAppBanner` (4 s, shared with OSC 9/777), cards: `PermissionCardStack` (top-trailing, max 55% height). Local notifications: `AttentionNotificationPolicy` + `LocalNotifier`, opt-in (explainer alert, Settings toggle).
- DEBUG `-debugAgentFixture` (implies the tmux fixture): the real transcript `core/shuai-agent/tests/fixtures/e2e-claude-2.1.288.jsonl` (bundled) is played through a fake `AgentRemote` into the real monitor; `respond` calls are readable via the `agent-fixture-log` accessibility value.

## Background push (M6: ntfy + deep links)
- **Status only, always.** `shuai-agent` (`ntfy.rs`) pushes a title (`Claude needs approval` / `Claude is waiting for input` / `Claude finished` / `Claude stopped with an error` / `Codex finished`) and a body of host label + tmux `session › index: window` (`tmux display-message`, 1.5 s, best effort). It classifies events by type only; no prompt, tool input, assistant message, cwd or path is ever read into a push (`tests/push.rs::no_event_content_ever_reaches_the_ntfy_request`). Click = `shuai://open?host=<host_id>&pane=<%N>` (percent-encoded). Approval = priority high.
- Gate (`push.json` under `push.lock`): `PermissionRequest` + `Notification:permission_prompt` of one session pair up within 60 s into ONE push; other pushes are limited to one per session per 10 s (`SHUAI_PUSH_MIN_INTERVAL_SECS`), approvals exempt. Only when no app is present.
- `~/.shuai/config.toml` is written by the app (`AgentConfigToml`, golden `fixtures/agent-config/hostile.toml` shared with a Rust test): `host_id` (HostProfile UUID), `host_name`, `[ntfy] server/topic/token`. Written by the installer (step before diagnostics), `PushSyncCoordinator.syncNow` ("Sync notification settings" / "Sync to connected hosts") and automatically on connect when the rendered config's fingerprint changed (`AgentHub.onAgentReady`). Atomic tmp + `mv`, 0600.
- `PushSettings`: default `https://ntfy.sh` + random `shuai-<26 base32>` topic (128 bit, `SecRandomCopyBytes`); topic and token live in the Keychain (`PushSecretStore`), never UserDefaults. "Send test notification" posts status-only text from the app.
- `DeepLink`/`DeepLinkRouter` (ShuaiApp): strict parser (`host` UUID once, optional `pane` matching `%[0-9]{1,9}`, extras ignored); `AppModel: PaneNavigating` connects, selects the pane, marks seen; local-notification taps use the same router. URL scheme registered via `info:` in `project.yml` (generated `Generated/Info.plist`, gitignored). DEBUG `-debugTmuxFixture` host has a fixed id and fakes the selection locally for UI tests.
