# ADR 0003: Server agent driven by Claude Code hooks, JSONL event log, `watch` over SSH exec

Status: Accepted

## Context

The app must know what each Claude Code session is doing and answer permission requests natively,
while the user keeps running `claude` normally inside tmux. Options considered: scraping terminal
output, wrapping the CLI, a long-running server daemon with a socket, a cloud relay, or Claude Code
hooks.

## Decision

- Ship a **Claude Code plugin** whose hooks call a small static binary, `~/.shuai/bin/shuai-agent`.
  Codex is connected through its `notify` program.
- Each hook invocation appends one JSON envelope to `~/.shuai/events.jsonl` (flock, sequence
  number, rotation) and exits. No daemon, no listening port.
- The app reads events by running `shuai-agent watch --since <seq>` on an **SSH exec channel** of
  its existing connection: replay, `caught_up` marker, live tail, heartbeats. Heartbeats also mark
  the app as present.
- Permission requests use a synchronous hook that waits for a response file written by
  `shuai-agent respond` (another exec), and returns immediately when no app is present or after a
  timeout below the hook limit, so Claude falls back to its own dialog.
- The app installs and removes all of this over SSH ("Enable/Remove AI integration").

## Consequences

- Nothing listens on the network and there is no relay: the attack surface is the user's existing
  SSH access.
- Claude is never blocked by shuai: hooks always exit 0 and degrade to Claude's normal behaviour.
- Reconnects are cheap: the cursor (`seq`) resumes the stream; the Rust tracker deduplicates.
- State depends on hook coverage; lost events are corrected by pane liveness and periodic
  `claude agents --json` reconciliation.
- Events (including prompts and tool input) are stored on the server under `~/.shuai` with 0600/0700
  permissions, next to Claude Code's own transcripts.
- Hook and event formats must stay backward compatible (lenient decoding, optional fields).
