# ADR 0008: One notice center for transient in-app messages

Status: Accepted

## Context

Transient messages (deep-link failures, push sync results, tmux errors, terminal notifications,
agent banners) come from several sources. They need one consistent policy for priority, dedupe,
duration and placement relative to permission cards, and their text is often untrusted (OSC 9/777,
tmux errors, remote stderr).

## Decision

- All transient in-app messages go through `NoticeCenter` (`ShuaiApp/Notices`). Sources post a
  `Notice` or retract it by key; they never keep their own message state or timers.
- `NoticeQueue` is a pure value type holding the rules (ordering, visibility limits, dedupe,
  deadlines); `NoticeCenter` is a thin `@MainActor @Observable` wrapper with injected clock and
  sleep that owns the single expiry timer. Views own no timers.
- Notice text is sanitized and length-capped in `Notice.init` (control characters and bidi
  overrides removed, whitespace collapsed) and rendered with `Text(verbatim:)`.
- `AttentionBannerQueue` remains a domain source of agent attention; it is mapped into the center
  with `reconcile(source:with:)` instead of being rendered directly.
- Rules are specified in [interaction](../design/interaction.md#notices).

## Alternatives considered

- **Per-source state with view timers**: untestable timing, no cross-source priority, notices can
  cover permission cards.
- **Fold agent banners into the center's own state**: loses the agent-specific queue logic and its
  tests; mapping keeps it a domain concern.

## Consequences

- Timing, ordering and dedupe are covered by pure tests with a fake clock.
- A new source needs only a `Notice` mapping, not new UI.
- Mutations that can change what is visible take the current time so the queue itself needs no clock.
