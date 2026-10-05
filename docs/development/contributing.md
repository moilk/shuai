# Contributing

Contributions are welcome under the MIT license. Read [Architecture](../design/architecture.md)
first, and the [ADRs](../adr/) for decisions that are already settled.

## Workflow

1. **Plan.** For anything larger than a small fix, open an issue (or a draft PR) describing the
   change, the affected components and the test plan. Decisions that change architecture get an ADR
   in `docs/adr/`.
2. **Branch** from `main` (`feat/...`, `fix/...`, `docs/...`).
3. **TDD.** Commit the failing test first (`test: ...`), then the implementation
   (`feat: ...` / `fix: ...`). See [Testing](testing.md).
4. **Check locally** before pushing:
   ```sh
   cd core && cargo fmt --all --check && cargo clippy --workspace --all-targets -- -D warnings && cargo test --workspace
   cd apple/ShuaiKit && swift test
   ```
   plus the simulator and app tests when you touched `ShuaiTerminal` or `apple/App`.
5. **Review** your own diff against the checklist below, then open a PR.
6. **Merge** when CI is green and review comments are resolved.

## Commits

[Conventional Commits](https://www.conventionalcommits.org/): `feat`, `fix`, `test`, `docs`, `chore`,
`ci`, `refactor`, with an optional scope (`fix(tmux): ...`). Imperative subject, at most about
72 characters; the body explains *why*.

## Pull requests

- One logical change per PR; keep refactors separate from behaviour changes.
- Describe what changed, why, and how it was tested (commands run, simulator/device used).
- Update docs in the same PR when behaviour, commands, settings or shortcuts change; docs describe
  the current state, not the history of the change.
- Screenshots must use fixture data only (`-debugTmuxFixture`, `-debugAgentFixture`), never a real
  server.

## Review checklist

- [ ] Tests first, covering the new logic and the bug being fixed.
- [ ] Logic lives in a pure Rust crate or platform-neutral Swift, not in views or the FFI layer.
- [ ] FFI changes follow the boundary rules (coarse API, records vs objects, flat errors).
- [ ] Every new SSH stream is drained continuously.
- [ ] Server output, tmux data, agent events and URLs are treated as untrusted.
- [ ] No secrets in logs, pushes or `Debug`/`description` output; pushes stay status-only.
- [ ] Hooks still always exit 0 and never block Claude.
- [ ] DEBUG-only code is under `#if DEBUG`; nothing from the testkit can reach a release build.
- [ ] Swift compiles with the CI Xcode (see [CI](ci.md)).
- [ ] No machine-specific paths, host names or personal data in code, fixtures or docs.
- [ ] Docs and CLAUDE.md files updated if conventions or commands changed.
- [ ] Docs, comments and PR text describe the current design, not the fix history.

## AI agents

Coding agents working in this repo follow the root `CLAUDE.md` and the nested `core/CLAUDE.md` and
`apple/CLAUDE.md`; the same rules apply to humans.
