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
