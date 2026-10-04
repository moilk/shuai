# ADR 0004: MIT license; SSH + tmux + reconnect instead of mosh in v1

Status: Accepted

## Context

shuai is open source and should be easy to reuse, fork and ship through the App Store. Mobile
connections drop often, which mosh addresses, but mosh is GPL-3.0 and so are its existing ports;
linking it would make the whole app GPL and complicate App Store distribution.

## Decision

- License everything (app, core, agent, plugin) under **MIT**. Dependencies must be compatible
  (MIT, Apache-2.0, BSD, ISC and similar); no GPL code is linked.
- No mosh in v1. Session persistence comes from **tmux** on the server (`tmux new -A`) plus
  **automatic reconnect** in the app (`ReconnectPolicy`: backoff, network-path and foreground
  triggers, reattach with a forced redraw).
- A clean-room, MIT-licensed mosh-compatible implementation in Rust stays on the roadmap.

## Consequences

- Programs on the server survive any disconnect; the user sees a short reconnect instead of a
  roaming session. Typing latency on poor links is that of plain SSH.
- Licensing stays simple for contributors and redistributors.
- tmux is effectively required for a good experience; without it shuai falls back to a plain shell.
