# Installing on an iPad

shuai is not on the App Store or TestFlight. You build it from source and install it on your own
iPad from Xcode. A free Apple ID is enough; the trade-off is that free provisioning profiles
expire after 7 days (see [Re-signing every 7 days](#re-signing-every-7-days)).

## Requirements

| Item | Notes |
|---|---|
| Mac with Xcode | A recent Xcode with the iOS 18 SDK or newer (CI builds with Xcode 26.6). If `xcode-select -p` points at the Command Line Tools, set `DEVELOPER_DIR` to your Xcode.app's `Contents/Developer` directory for every command below. |
| iPad on iPadOS 18 or newer | The app targets iPad only (deployment target 18.0). |
| Rust (rustup, stable) | `rustup target add aarch64-apple-ios aarch64-apple-ios-sim aarch64-apple-darwin x86_64-unknown-linux-musl aarch64-unknown-linux-musl` |
| XcodeGen | `brew install xcodegen` |
| zig + cargo-zigbuild | Cross-compile the server-side `shuai-agent`: `brew install zig` and `cargo install cargo-zigbuild --locked` |
| Apple ID | Signed in under Xcode > Settings > Accounts. A free account works. |

## Build

From the repository root:

```sh
# 1. Cross-compile shuai-agent (static Linux musl binaries, x86_64 + aarch64).
#    Output: apple/App/Resources/agent/ (gitignored), bundled into the app.
scripts/build-agent.sh

# 2. Build the Rust core as ShuaiCoreFFI.xcframework and generate the Swift bindings.
scripts/build-xcframework.sh

# 3. Generate the Xcode project (the .xcodeproj is generated and never committed).
cd apple/App && xcodegen generate
open Shuai.xcodeproj
```

> **Never install or distribute an xcframework built with `SHUAI_FFI_TESTKIT=1`.** That mode
> compiles an in-process SSH server with hard-coded credentials into the library for tests. A
> normal `scripts/build-xcframework.sh` run ends with `scripts/check-no-testkit.sh`, which fails if
> the test server is present. To replace a testkit build, run the script again without the
> variable.

Release builds fail when `apple/App/Resources/agent/shuai-agent-*` is missing (a pre-build check
in `project.yml`). Debug builds only warn, but the app then cannot enable AI integration on a host.

## Configure signing (once)

Signing lives in two xcconfig files, never in the generated project:

- `apple/App/Signing.xcconfig` (committed): device builds are unsigned by default, so CI and fresh
  clones build without an Apple account.
- `apple/App/Local.xcconfig` (gitignored, included by `Signing.xcconfig`): your personal values.

Do not edit signing in Xcode's Signing & Capabilities tab: the next `xcodegen generate` discards it.

1. Copy the template:
   ```sh
   cp apple/App/Local.xcconfig.example apple/App/Local.xcconfig
   ```
2. Edit `apple/App/Local.xcconfig`:
   - `DEVELOPMENT_TEAM`: your Team ID (Xcode > Settings > Accounts > your Apple ID > Personal Team).
   - `SHUAI_BUNDLE_ID`: a bundle id nobody else has registered, for example
     `io.github.<your-name>.shuai`. The default `io.github.moilk.shuai` is taken and a free account
     reports "Failed to register bundle identifier". Test targets derive `<SHUAI_BUNDLE_ID>.tests`
     and `.uitests` automatically.
   - Keep `CODE_SIGNING_ALLOWED = YES`.
3. Regenerate: `cd apple/App && xcodegen generate`, open `Shuai.xcodeproj` and check that the
   Signing section shows your team without errors.

## Prepare the iPad

1. Connect the iPad (USB or the same network) and select it as the run destination in Xcode.
2. Enable **Developer Mode**: Settings > Privacy & Security > Developer Mode, then restart and
   confirm. The option appears only after the iPad has been connected to Xcode once.
3. Run (⌘R). The first launch is blocked as an untrusted developer: open Settings > General >
   VPN & Device Management, select your Apple ID under Developer App and tap Trust.
4. Open shuai from the Home Screen.

Continue with [Getting started](getting-started.md).

## Re-signing every 7 days

A profile from a free account expires after 7 days; the app icon stays but the app no longer
launches.

- Run the project from Xcode again. The same bundle id updates in place, so hosts, keys and
  settings are kept.
- No need to rerun `build-agent.sh` or `build-xcframework.sh` unless the sources changed.
- Free accounts limit how many new App IDs you can register per week and how many self-signed
  apps can be installed at once: do not change the bundle id often.
- Deleting the app also deletes its Keychain items (your private keys). Keep a copy of any key you
  cannot regenerate.

## Troubleshooting

| Symptom | Fix |
|---|---|
| Keychain error `-34018` (errSecMissingEntitlement) | The app is unsigned. For a device, set `DEVELOPMENT_TEAM` and `CODE_SIGNING_ALLOWED = YES` in `Local.xcconfig`, then `xcodegen generate`. Simulator builds are ad-hoc signed by `project.yml` and need nothing. |
| "Failed to register bundle identifier" / "No profiles for 'io.github.moilk.shuai' were found" | Set a unique `SHUAI_BUNDLE_ID` in `Local.xcconfig`, check `DEVELOPMENT_TEAM`, regenerate. |
| "Untrusted Developer", the app does not open | Settings > General > VPN & Device Management > trust your developer certificate. |
| Xcode does not list the iPad / asks for Developer Mode | Connect it, tap "Trust This Computer", enable Developer Mode and restart. |
| The app quits immediately after a week | The profile expired: run from Xcode again. |
| Build error `Bundled agent binaries missing` | Run `scripts/build-agent.sh` (needs zig and cargo-zigbuild). |
| Missing `ShuaiCoreFFI` module or generated bindings | Run `scripts/build-xcframework.sh` (outputs `apple/ShuaiKit/ShuaiCoreFFI.xcframework`, gitignored). |
| Command-line errors mentioning CommandLineTools | Set `DEVELOPER_DIR` to your Xcode.app's `Contents/Developer`, or switch with `sudo xcode-select -s <path to Xcode.app>/Contents/Developer`. |
