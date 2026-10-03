# shuai — project conventions

iPad AI-coding SSH terminal. Rust core + UniFFI, native Swift UI. Plan: `docs/plan/`, decisions: `docs/adr/`.

## Layout
- `core/` Cargo workspace (shuai-proto, -keys, -ssh, -tmux, -agentkit, -ffi, -agent, uniffi-bindgen)
- `apple/ShuaiKit` Swift package (binaryTarget ShuaiCoreFFI + generated bindings + facade)
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
