# Release

> **Status:** there are no published releases, no TestFlight and no App Store build yet. Users
> build and sign the app themselves ([Installation](../user/installation.md)). The checklist below
> is the required process for any build that leaves a developer's machine; the steps marked
> *manual* are not automated yet.

## Versioned artifacts

| Artifact | Version source | Notes |
|---|---|---|
| Rust crates, `shuai-agent` | `[workspace.package] version` in `core/Cargo.toml` (shared by all crates) | `shuai-agent --version`; `core_version()` over FFI; shown in Settings > About |
| Wire protocol | `PROTOCOL_VERSION` in `core/shuai-proto/src/lib.rs` | Bump only for incompatible changes; additive optional fields do not need a bump |
| Claude Code plugin | `version` in `plugin/.claude-plugin/plugin.json` and `.claude-plugin/marketplace.json` | Equal to the workspace version (`core/shuai-agent/tests/plugin.rs` checks `plugin.json`); keep `marketplace.json` in step |
| iPad app | Xcode marketing/build version | Not set in `project.yml` yet |

Rules:

- The app bundles the agent it was built with. The installer uploads the bundled binary whenever the
  host's `shuai-agent --version` differs, so app and agent ship as one unit; bump the workspace
  version whenever agent behaviour changes.
- The plugin only calls `~/.shuai/bin/shuai-agent hook <Event>`; keep old agents tolerant of new
  hooks (unknown events are recorded as `other`).
- New event fields must be optional on both sides (lenient decoding).
- Tag releases `vX.Y.Z` matching the workspace version.

## Release checklist

1. `main` is green in CI.
2. Bump versions: workspace, `plugin.json` and `marketplace.json` together; the protocol only if
   incompatible.
3. Build the agent binaries:
   ```sh
   scripts/build-agent.sh
   ```
4. Build the xcframework in normal mode; this also runs the testkit guard:
   ```sh
   scripts/build-xcframework.sh
   scripts/check-no-testkit.sh      # must print "ok"
   ```
5. Run the debug-launch guard (*manual*): builds Release for the simulator and scans the binary.
   ```sh
   scripts/check-no-debug-launch.sh
   ```
6. Build the app in Release (*manual*). The pre-build check fails if
   `apple/App/Resources/agent/shuai-agent-{x86_64,aarch64}-unknown-linux-musl` is missing.
7. Sign with your own team (*manual*; `Local.xcconfig`). There is no shared signing identity.
8. Run the [device QA checklist](device-qa-checklist.md) on a real iPad (*manual*).
9. Tag and publish release notes (*manual*). The `agent-build` CI job's artifacts are the
   reference Linux agent binaries for that commit.

## Never ship

- An xcframework built with `SHUAI_FFI_TESTKIT=1` (in-process SSH server with fixed credentials).
- A Debug build (DEBUG launch arguments can disable host key verification and log keystrokes).
- A build without bundled agent binaries.
