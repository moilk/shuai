# shuai

AI-coding-aware SSH terminal for iPad: Rust core exported via UniFFI, native SwiftUI/UIKit app with a
libghostty terminal, tmux-native navigation, and a server-side `shuai-agent` fed by a Claude Code
plugin. Direct SSH, no relay, MIT. Status: v1 feature-complete, real-device QA pending
(`docs/roadmap.md`).

## Repo map

- `core/` Cargo workspace: `shuai-proto`, `shuai-keys`, `shuai-ssh`, `shuai-tmux`, `shuai-agentkit`,
  `shuai-ffi` (UniFFI layer), `shuai-agent` (server binary), `shuai-testkit` (dev-only SSH server),
  `uniffi-bindgen`. Conventions: `core/CLAUDE.md`.
- `apple/ShuaiKit` Swift package (`ShuaiCore`, `ShuaiPlatform`, `ShuaiTerminal`, `ShuaiApp`);
  `apple/App` iPad app (XcodeGen). Conventions: `apple/CLAUDE.md`.
- `plugin/` + `.claude-plugin/` Claude Code plugin and marketplace. `scripts/` build and release
  guards. `fixtures/` shared test data. `android/` not started.
- `docs/` user, design, development docs and ADRs; index `docs/README.md`.

## Commands

If `xcode-select -p` points at the Command Line Tools, export `DEVELOPER_DIR` with your Xcode.app's
`Contents/Developer` before any Xcode command.

```sh
cd core && cargo fmt --all --check && cargo clippy --workspace --all-targets -- -D warnings && cargo test --workspace
cd core && cargo test -p shuai-ffi --features testkit
scripts/build-agent.sh                 # shuai-agent musl binaries -> apple/App/Resources/agent/
scripts/build-xcframework.sh           # xcframework + Swift bindings (runs check-no-testkit)
cd apple/ShuaiKit && swift test        # Swift logic on macOS
cd apple/App && xcodegen generate && xcodebuild test -scheme Shuai -destination 'platform=iOS Simulator,name=<iPad simulator>'
```

Real-SSH Swift tests, simulator engine tests, live E2E: `docs/development/testing.md`.

## Non-negotiable rules

- TDD where there is logic: failing test committed first (`test: ...`), then `feat:`/`fix:`.
- Logic lives in pure Rust crates or platform-neutral Swift; FFI and views stay thin.
- Every open SSH stream is drained continuously until `Closed`, or the whole session stalls.
- Everything from the server (terminal bytes, tmux output, agent events, `shuai://` links) is
  untrusted: parse strictly, cap sizes, never execute.
- Pushes are status-only: never prompts, commands, tool input, messages, paths or cwd.
- Hooks must never block or fail Claude: `shuai-agent hook` always exits 0 and falls back silently.
- Secrets (keys, passwords, ntfy topic/token) never reach logs or `description`; Keychain only.
- Never ship a `SHUAI_FFI_TESTKIT=1` xcframework or DEBUG launch arguments (guards:
  `scripts/check-no-testkit.sh`, `scripts/check-no-debug-launch.sh`).
- No machine-specific paths, host names or personal data in code, fixtures or docs. Screenshots use
  fixture data only.
- Keep CI's older Xcode compiling (see `docs/development/ci.md`).

## Workflow

1. Plan: for non-trivial work write the plan (issue/PR description); architecture changes get an ADR.
2. TDD: test commit, then implementation commit, small and focused.
3. Review: run the checks above, then go through `docs/development/contributing.md#review-checklist`.
4. PR: Conventional Commits (feat/fix/test/docs/chore/ci/refactor), branch from `main`, CI green.
5. Docs describe the final state; update them in the same PR when behaviour or commands change.

## Deeper docs

- Design: `docs/design/architecture.md`, `agent-protocol.md`, `tmux-integration.md`,
  `security-model.md`; decisions in `docs/adr/`.
- Development: `docs/development/building.md`, `testing.md`, `ci.md`, `release.md`, `contributing.md`.
- User-facing behaviour: `docs/user/` (shortcuts, notifications, Claude integration).
