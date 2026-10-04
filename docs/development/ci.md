# Continuous integration

Workflow: `.github/workflows/ci.yml`, on every push to `main` and every pull request. All jobs must
pass before merging.

## Jobs

### `rust` (ubuntu-latest)

Working directory `core/`, stable Rust with rustfmt and clippy.

1. `cargo fmt --all --check`
2. `cargo clippy --workspace --all-targets -- -D warnings`
3. `cargo test --workspace`
4. `cargo test -p shuai-ffi --features testkit`

The Ubuntu image's stock tmux (3.4 on Ubuntu 24.04) runs the real-tmux tests, which covers the
escaped `\037` field-separator path. Raw-separator versions are covered by fixtures and local runs.

### `apple` (macos-latest)

1. Rust with the Apple targets, XcodeGen, zig and cargo-zigbuild.
2. `scripts/build-agent.sh` (both Linux targets; the app must bundle them).
3. `scripts/test-check-no-testkit.sh` (self-test of the release guard).
4. **Testkit pass**: `SHUAI_FFI_TESTKIT=1 scripts/build-xcframework.sh`, then
   `SHUAI_FFI_TESTKIT=1 swift test` in `apple/ShuaiKit` (real-SSH Swift tests).
5. **Normal pass**: `scripts/build-xcframework.sh`, `scripts/check-no-testkit.sh` (explicitly),
   `swift test`.
6. `xcodegen generate`, then `SHUAI_REQUIRE_AGENT=1 xcodebuild test -scheme Shuai` on the newest
   available iPad simulator (app unit tests and UI tests with DEBUG fixtures).

The app is always tested against the normal (non-testkit) xcframework, the one that could ship.

### `agent-build` (ubuntu-latest, matrix)

`cargo zigbuild --release -p shuai-agent` for `x86_64-unknown-linux-musl` and
`aarch64-unknown-linux-musl`; uploads each binary as a workflow artifact
(`shuai-agent-<target>`).

## Xcode version

The `apple` job uses the default Xcode of the `macos-latest` runner image (Xcode 26.6 at the time of
writing), which may be older than the Xcode you develop with. Avoid constructs that only a newer
Swift compiler accepts; for example, write `_ = expr` in a closure that must return `Void` instead
of relying on a single-expression closure whose value type differs.

## Not covered by CI

- The simulator engine tests of the `ShuaiKit-Package` scheme (run them locally; see
  [Testing](testing.md)).
- `scripts/check-no-debug-launch.sh` (Release build guard; part of the release checklist).
- The live E2E UI tests and anything that needs a real device.
