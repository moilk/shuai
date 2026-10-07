# Testing

## Policy

- **TDD where there is logic.** Write the failing test first and commit it (`test: ...`), then the
  implementation (`feat: ...` / `fix: ...`). Bug fixes start with a test that reproduces the bug.
- Put logic where it is cheapest to test: pure Rust crates first, then platform-neutral Swift
  (`swift test` on macOS), then simulator tests, then UI tests.
- Tests must be deterministic: inject clocks, sleeps and timers (see `ReconnectController`,
  `TmuxMonitor`'s debounce timer) instead of racing the wall clock.
- Real external dependencies (tmux, an SSH server) are used only when the test can provide them
  itself or skips cleanly when they are missing.

## Test layers

| Layer | Command | Notes |
|---|---|---|
| Rust unit + integration | `cd core && cargo test --workspace` | All pure crates; golden fixtures, property tests (`proptest`), robustness tests |
| In-process SSH | included above | `shuai-ssh` and `shuai-ffi` tests run against `shuai-testkit`, a russh server on 127.0.0.1 |
| FFI with testkit | `cd core && cargo test -p shuai-ffi --features testkit` | Exercises the exported `startTestSshServer()` |
| Real tmux | included in `cargo test` | `shuai-tmux/tests/real_tmux.rs`, skipped if tmux is missing |
| Swift logic | `cd apple/ShuaiKit && swift test` | Swift Testing on the macOS host |
| Swift real SSH | `SHUAI_FFI_TESTKIT=1 scripts/build-xcframework.sh`, then `cd apple/ShuaiKit && SHUAI_FFI_TESTKIT=1 swift test` | Compiles the `#if SHUAI_TESTKIT` tests (`ConnectionTests`, `SessionControllerRealSSHTests`, `AgentRemoteRealSSHTests`) |
| Swift engine (simulator) | `cd apple/ShuaiKit && xcodebuild test -scheme ShuaiKit-Package -destination 'platform=iOS Simulator,name=<iPad simulator>'` | libghostty-dependent tests (`#if canImport(GhosttyTerminal)`) need iOS |
| App unit + UI | `cd apple/App && xcodegen generate && xcodebuild test -scheme Shuai -destination 'platform=iOS Simulator,name=<iPad simulator>'` | `ShuaiTests` + `ShuaiUITests` with DEBUG fixtures |
| Live end-to-end | see below | Manual, against your own server |
| Real device | [Device QA checklist](device-qa-checklist.md) | IME, hardware keyboard, background, push |

List simulators with `xcrun simctl list devices available`; any iPad running iOS 18+ works.

### Rust details

- `shuai-testkit` users: password `alice`/`secret`, keyboard-interactive `kbd`/`123456`; exec
  commands `ok`, `fail`, `stream`, `cat`, `cat > PATH` (records uploads), `big`, `utf8`, `cut`,
  `drop`, and shell inputs such as `HANG`, `EXIT3`, `BYE` script edge cases.
- Real tmux tests start a private server per test (`tmux -L shuaim4-<pid>-<n> -f /dev/null`) and
  kill it afterwards. Run them against a specific tmux build:
  ```sh
  cd core && SHUAI_TMUX_BIN=/path/to/tmux cargo test -p shuai-tmux --test real_tmux
  ```
  Fixtures for every supported version: `core/shuai-tmux/tests/fixtures/listpanes-tmux*.txt`.
- `shuai-agent` tests run the real binary against a temporary `SHUAI_HOME`; push tests use a local
  HTTP listener and assert the status-only content.
- Ignored manual tests:
  ```sh
  SHUAI_TEST_SSH_HOST=<host> SHUAI_TEST_SSH_USER=<user> SHUAI_TEST_SSH_KEY=<unencrypted key file> \
    cargo test -p shuai-ssh -- --ignored real_sshd_smoke
  SHUAI_PROBE_SSH_HOST=<ssh-host> cargo test -p shuai-agentkit -- --ignored probe_over_ssh
  ```

### Swift details

- `TmuxRealTests` (macOS only) drive `TmuxMonitor`/`TmuxActions` against a private local tmux server
  through a shim and skip when tmux is not installed.
- `SHUAI_FFI_TESTKIT=1` must be set in the environment of `swift test` (not only the build): it makes
  `Package.swift` define `SHUAI_TESTKIT`. SwiftPM caches manifest evaluation, which is why this is an
  environment variable and not a marker file.
- UI tests launch with `-uiTesting` (ephemeral stores) and `-debugTmuxFixture` or
  `-debugAgentFixture`; `-debugConnectionState <reconnecting|failed|disconnected>` shows a fixed
  connection state for screenshots and layout checks; `-debugNoticeTimeScale <n>` makes notices last
  `n` times longer, so transient-notice tests do not race a slow runner; `-debugSidebarCollapsed` starts with
  the sidebar collapsed so the window tab strip is shown; `-debugSingleWindow` seeds one session with
  one window (with `-tabStrip always`, the persisted setting as a launch argument, the strip shows anyway); `-debugHardwareKeyboard` fakes a hardware keyboard and no software one (with
  `-hardwareKeyboardBar hide` the bar is gone). The agent fixture plays the recorded Claude Code transcript
  `core/shuai-agent/tests/fixtures/e2e-claude-2.1.288.jsonl` through the real monitor; `respond`
  calls are exposed via the `agent-fixture-log` accessibility value.
- When several simulators or agents run at once, give UI tests their own simulator device; a shared
  device makes XCUITest time out.

## Live end-to-end test

`ShuaiE2ETests` (in the UI test target) drives the real app against a real server. Every test skips
unless `SHUAI_E2E_HOST_FILE` is set, so it never runs in CI.

1. Prepare a disposable Linux server with tmux and Claude Code, and an unencrypted SSH key for it.
2. Write a host file **outside the repository**:
   ```json
   {"name": "e2e", "host": "server.example.com", "port": 22, "user": "dev",
    "keyPath": "/path/to/e2e_key", "tmuxSession": "shuai-e2e"}
   ```
3. Run one phase at a time (pass variables to the test runner with the `TEST_RUNNER_` prefix):
   ```sh
   cd apple/App && xcodegen generate
   TEST_RUNNER_SHUAI_E2E_HOST_FILE=/path/to/host.json \
     xcodebuild test -scheme Shuai -destination 'platform=iOS Simulator,name=<iPad simulator>' \
     -only-testing:ShuaiUITests/ShuaiE2ETests/testE2EInstall
   ```

Phases: `testE2EInstall`, `testE2ETypeAndEnter` (`SHUAI_E2E_TEXT`), `testE2EPermissionCard`
(`SHUAI_E2E_TEXT`, `SHUAI_E2E_DECISION=allow|deny`, optional `SHUAI_E2E_OUT_DIR` for a screenshot),
`testE2EQuickSwitcher`, `testE2EUninstall`. They are separate so you can inspect the server between
phases. The app is launched with `-debugAutoAcceptHostKey`, so only use a server you control.

## README screenshot

`docs/assets/integration.webp` is a landscape capture of the DEBUG agent fixture (fixture data only)
on the iPad Pro 13-inch simulator, stored as 1800 px wide lossy WebP (about 50 KB) so the README
loads fast. With a Debug build installed on the simulator, set its language to English, rotate it to
landscape (⌘←) and run:

```sh
xcrun simctl status_bar <udid> override --time "2007-01-09T01:41:00.000Z" \
  --batteryState charged --batteryLevel 100 --wifiBars 3 --cellularMode notSupported
xcrun simctl launch <udid> <bundle id> -uiTesting -debugAgentFixture
xcrun simctl io <udid> screenshot shot.png                        # after ~10 s
sips -Z 1800 shot.png --out shot-1800.png
cwebp -q 88 -m 6 -sharp_yuv shot-1800.png -o docs/assets/integration.webp
```

Use `simctl io`: `XCUIScreen` and `XCUIApplication` screenshots of a rotated simulator come out
sideways. The time is UTC and renders as 9:41 AM in UTC+8; pick the matching value for your zone.
The on-screen keyboard appears only after the terminal is tapped, so do not tap before capturing.

## Flaky tests

- A flaky test is a bug. Do not add retries or longer sleeps to hide it; find the race and inject the
  clock or wait on an explicit condition.
- If a fix is not immediate, disable the test with a reason in the same PR and open an issue.
- Timing-sensitive Swift tests wait for idle state (`TmuxMonitor` exposes it) rather than sleeping.
