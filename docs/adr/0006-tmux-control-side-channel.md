# ADR 0006: Render tmux in one terminal, observe it through a control-mode side channel

Status: Accepted

## Context

tmux is the persistence and window-management layer. The app wants native navigation: a live
session/window/pane tree, badges per pane, a quick switcher and hardware shortcuts. Options:

- **A.** Plain terminal only: no structure visible to the app.
- **B.** Full `tmux -CC` integration: every pane becomes a native view fed by `%output`, layouts
  re-implemented natively (as iTerm2 does).
- **C.** Render tmux normally in one PTY terminal and attach a second, notification-only control
  client (`tmux -C` with `no-output`) to learn the structure and send commands.

## Decision

Choose **C**. The PTY client runs `tmux new -A -s NAME`; `TmuxMonitor` runs
`tmux -C attach -t =NAME:` on an exec channel of the same SSH connection with
`refresh-client -f no-output`, refreshes the topology on notifications (debounced) and sends
commands that name the PTY client explicitly (`switch-client -c TTY`). tmux below 3.2 is polled.
Native `-CC` splits are deferred.

## Consequences

- tmux draws exactly what it draws on a laptop: status line, copy mode, plugins and layouts all work,
  and the same session can be shared with other clients.
- One terminal view, so far less rendering and input complexity than B.
- The app must identify its own PTY client among several (process-tree matching with a heuristic
  fallback) and handle tmux version differences (`-F` separator escaping in 3.4/3.5).
- Panes cannot be rearranged as native views; split views per pane remain a v2 option (native
  `-CC`).
