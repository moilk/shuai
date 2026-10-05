# Documentation

## Using shuai

| Document | Contents |
|---|---|
| [Installation](user/installation.md) | Build from source, sign with a free Apple ID, install on an iPad, 7-day re-signing, troubleshooting |
| [Getting started](user/getting-started.md) | Hosts, keys and key import, host key trust, tmux, keyboard bars |
| [Claude Code integration](user/claude-integration.md) | What "Enable AI integration" installs, badges, permission cards, ⌘K / ⌘⇧A, Codex |
| [Notifications](user/notifications.md) | ntfy push setup, what a push contains, deep links |
| [Keyboard shortcuts](user/keyboard-shortcuts.md) | All hardware keyboard shortcuts |
| [Privacy and security](user/privacy-security.md) | What is stored where, what leaves the device or server |

## Design

| Document | Contents |
|---|---|
| [Architecture](design/architecture.md) | Components, Rust crates, Swift targets, FFI rules, data flows |
| [Agent protocol](design/agent-protocol.md) | Hooks, event format, `shuai-agent` CLI, state directory, config |
| [tmux integration](design/tmux-integration.md) | Control-mode side channel, client targeting, version compatibility |
| [Interaction](design/interaction.md) | Connection states and how the UI presents them |
| [Security model](design/security-model.md) | Threats, mitigations, release guards |
| [Architecture decisions](adr/README.md) | ADRs 0000-0007 |

## Developing

| Document | Contents |
|---|---|
| [Building](development/building.md) | Toolchain, build scripts, app project, DEBUG launch arguments |
| [Testing](development/testing.md) | Test policy and layers, live E2E test, flaky tests |
| [App icon](development/icon.md) | Regenerating the icon and brand exports, theme and mark config, fidelity gates |
| [CI](development/ci.md) | Jobs and what they cover |
| [Release](development/release.md) | Versioning, release guards, checklist |
| [Contributing](development/contributing.md) | Workflow, commits, PRs, review checklist |
| [Device QA checklist](development/device-qa-checklist.md) | Manual checks on a real iPad |

## Project

- [Roadmap](roadmap.md): current status and planned work.
- Component READMEs: [plugin](../plugin/README.md), [android](../android/README.md).
- Agent instructions: [CLAUDE.md](../CLAUDE.md), [core/CLAUDE.md](../core/CLAUDE.md),
  [apple/CLAUDE.md](../apple/CLAUDE.md).
