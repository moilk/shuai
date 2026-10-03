# shuai — project conventions

iPad AI-coding SSH terminal. Rust core + UniFFI, native Swift UI. Plan: `docs/plan/`, decisions: `docs/adr/`.

## Layout
- `core/` Cargo workspace (shuai-proto, -keys, -ssh, -tmux, -agentkit, -ffi, -agent, uniffi-bindgen)
- `apple/ShuaiKit` Swift package (binaryTarget ShuaiCoreFFI + generated bindings + facade)
- `apple/ShuaiKit/Sources/ShuaiTerminal` terminal module (see below)
- `apple/App` iPad app (XcodeGen `project.yml`; the .xcodeproj is generated, never committed)
- `plugin/` Claude Code plugin, `android/` future, `scripts/` build scripts

## Environment
xcode-select may point at CommandLineTools. Always prefix Xcode commands with
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

## Commands
- Rust: `cd core && cargo test --workspace && cargo clippy --workspace --all-targets -- -D warnings && cargo fmt --check`
- XCFramework + bindings: `scripts/build-xcframework.sh` (idempotent; outputs are gitignored)
- Swift package: `cd apple/ShuaiKit && swift test` (macOS host)
- App: `cd apple/App && xcodegen generate && xcodebuild test -scheme Shuai -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)'`
- Agent cross-build: `cd core && cargo zigbuild --release -p shuai-agent --target x86_64-unknown-linux-musl`

## Rules
- Strict TDD where there is logic: failing test first (commit `test: ...`), then implementation (`feat: ...`).
- Keep the FFI layer thin; logic lives in Rust crates and is tested with `cargo test`.
- Conventional commits (feat/fix/test/docs/chore/ci/refactor).

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
