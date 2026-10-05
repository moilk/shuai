# Interaction

## Notices

Transient in-app messages are `Notice` values held by `NoticeCenter` (ADR 0008). A notice has a
severity (info, success, attention, warning, error), a source (app, deep link, session, tmux,
terminal, agent), a scope (app-wide or one host), optional title, text, SF Symbol, optional action
(jump to an agent session, retry connect), a dedupe key and a lifetime.

- **Text**: untrusted. Control characters and bidi overrides/isolates are removed, newlines and
  tabs become spaces, whitespace is collapsed, the title is capped at 80 characters and the text at
  300 (an ellipsis marks truncation). Views render it with `Text(verbatim:)`.
- **Scope**: an app-scoped notice is eligible everywhere; a host-scoped notice only while that host
  is focused. Other hosts' notices wait and do not count as hidden.
- **Ordering**: severity descending, then newest first.
- **Max visible**: 3; 1 while permission cards are pending. Permission cards always render above
  notices. The overflow is shown as a hidden count.
- **Dedupe**: a notice posted with an existing key and different content replaces it in place and
  restarts its timer. Identical content increments a repeat count (shown as x N) and restarts the
  timer. Retracting by key removes it.
- **Duration**: `max(base, min(15 s, 2 s + 50 ms per character))` with base 5 s for info and
  success, 6 s attention, 8 s warning, 10 s error. A lifetime of `autoAfter(ms)` uses exactly that
  value; `sticky` never expires and is removed only by dismissal or retraction.
- **Timers**: the timer starts when a notice first becomes visible, not when it is posted. A
  notice that later stops being visible keeps its deadline. One timer task sleeps until the
  earliest deadline; dismissing or retracting re-arms or cancels it.
- **Capacity**: 20 notices; when full, the oldest of the lowest severity is dropped.
- **Reconcile**: a source that mirrors external state (agent banners) hands the center its
  current list; new ones are added, ones no longer present are retracted, and an id the user
  dismissed is not shown again.
- **Accessibility identifiers**: app, deep link, session and tmux notices use `session-notice`,
  terminal notices `notification-banner`, agent notices `agent-banner`.
