# Building

## Toolchain

| Tool | Used for |
|---|---|
| Rust stable via rustup (edition 2024), with `rustfmt` and `clippy` | `core/` |
| Rust targets `aarch64-apple-ios`, `aarch64-apple-ios-sim`, `aarch64-apple-darwin` | xcframework slices |
| Rust targets `x86_64-unknown-linux-musl`, `aarch64-unknown-linux-musl` | `shuai-agent` |
| zig + `cargo-zigbuild` | cross-linking `shuai-agent` from macOS |
| Xcode with the iOS 18 SDK or newer | Swift package and app (CI: Xcode 26.6) |
| XcodeGen | generating `apple/App/Shuai.xcodeproj` |
| tmux (optional) | real-tmux tests |

```sh
rustup target add aarch64-apple-ios aarch64-apple-ios-sim aarch64-apple-darwin \
  x86_64-unknown-linux-musl aarch64-unknown-linux-musl
brew install xcodegen zig tmux
cargo install cargo-zigbuild --locked
```

If `xcode-select -p` points at the Command Line Tools, export `DEVELOPER_DIR` with your Xcode.app's
`Contents/Developer` directory before running Xcode tools. The scripts default `DEVELOPER_DIR` to
`/Applications/Xcode.app/Contents/Developer` when it is unset.

## Build steps

All scripts are idempotent and write only gitignored outputs.

```sh
# Rust workspace
cd core && cargo build --workspace

# Server agent: static, stripped musl binaries for both Linux targets
# -> apple/App/Resources/agent/shuai-agent-<triple>
scripts/build-agent.sh                       # or: scripts/build-agent.sh x86_64-unknown-linux-musl

# Rust core for Apple platforms + Swift bindings
# -> apple/ShuaiKit/ShuaiCoreFFI.xcframework, apple/ShuaiKit/Sources/ShuaiCore/Generated/
scripts/build-xcframework.sh

# App project (never committed)
cd apple/App && xcodegen generate
```

What `scripts/build-xcframework.sh` does: builds `shuai-ffi` in release for the three Apple
targets, generates Swift bindings with `uniffi-bindgen` (library mode), assembles
`ShuaiCoreFFI.xcframework`, and finally runs `scripts/check-no-testkit.sh`. It sets
`MACOSX_DEPLOYMENT_TARGET=15.0` and `IPHONEOS_DEPLOYMENT_TARGET=18.0` to match the Swift package.

### Testkit mode

```sh
SHUAI_FFI_TESTKIT=1 scripts/build-xcframework.sh
```

Builds every slice with the `testkit` cargo feature, which exports `startTestSshServer()` (an
in-process SSH server with hard-coded credentials) so the real-SSH Swift tests can run. The script
prints a loud warning and skips the guard. **Never ship, archive or install this build**; rerun
the script without the variable to replace it.

## The app project

`apple/App/project.yml` is the source of truth; the `.xcodeproj` and `Generated/Info.plist` are
generated.

- iPad only, iOS 18.0 deployment target, Swift 6.
- The app links only the `ShuaiApp` package product (linking several dynamic products duplicates
  classes at runtime).
- Bundled resources: the CJK terminal recording (DEBUG terminal playground), the recorded Claude
  hook transcript (DEBUG agent fixture), and `Resources/agent/` (agent binaries).
- Pre-build check: missing agent binaries fail Release builds and any build with
  `SHUAI_REQUIRE_AGENT=1`; Debug builds only warn.
- Simulator builds are ad-hoc signed so the Keychain works. Device signing comes from
  `Signing.xcconfig` + your gitignored `Local.xcconfig`; see
  [Installation](../user/installation.md#configure-signing-once).
- The `shuai://` URL scheme is declared under `info:` in `project.yml`.

## DEBUG launch arguments

Compiled only in DEBUG builds; set them in the scheme or via XCUITest `launchArguments`.

| Argument | Effect |
|---|---|
| `-uiTesting` | Ephemeral stores (temp files, in-memory secrets) |
| `-debugTmuxFixture` | A fixture host with a made-up tmux topology and a fixed id (UI tests, deep links) |
| `-debugAgentFixture` | Implies the tmux fixture; plays the bundled Claude transcript through the real agent monitor |
| `-debugHostFile <path>` | Creates and selects a host from JSON `{name, host, port, user, keyPath, tmuxSession?, tmuxArgs?}`; keep the file outside the repo |
| `-debugAutoAcceptHostKey` | Accepts the TOFU prompt (scripted runs only) |
| `-debugSendAfterConnect <text>` | Types text + Enter after attach |
| `-debugByteTap` | Logs hex of every channel write/read via NSLog (contains your keystrokes) |
| `-debugDelayReplies <seconds>` | Delays engine replies to device queries |
| `-debugTerminal` | Terminal playground replaying the bundled recording |

`scripts/check-no-debug-launch.sh` verifies none of these strings survive in a Release build.
