# Interaction

## Notices

Transient in-app messages are `Notice` values held by `NoticeCenter` (ADR 0008). A notice has a
severity (info, success, attention, warning, error), a source (app, deep link, session, tmux,
terminal, agent), a scope (app-wide or one host), optional title, text, SF Symbol, optional action
(jump to an agent session, retry connect), a dedupe key and a lifetime.

- **Text**: untrusted. Control, format (bidi overrides and isolates, zero-width, tag) and
  blank-filler characters are removed (ZWJ and ZWNJ stay), newlines and tabs become spaces,
  whitespace is collapsed, at most 4 scalars are kept per grapheme cluster, the title is capped at
  80 characters and the text at 300 (an ellipsis marks truncation). Sanitizing is a single pass
  that stops reading once the cap is exceeded. A notice whose text is empty after sanitizing is
  ignored. Views render text with `Text(verbatim:)`.
- **Scope**: an app-scoped notice is eligible everywhere; a host-scoped notice only while that host
  is focused. Other hosts' notices wait and do not count as hidden.
- **Ordering**: severity descending, then newest first.
- **Max visible**: 3; 1 while pending permission cards are reported to the queue. The queue
  exposes the overflow as `hiddenCount`. Views place permission cards above the notice stack.
- **Dedupe**: on (key, scope), a notice posted with an existing key and different content replaces
  it in place (keeping its id) and restarts its timer. Identical content increments the notice's
  `count` and restarts the timer. Retracting by key removes it.
- **Duration**: `max(base, min(15 s, 2 s + 50 ms per character))` with base 5 s for info and
  success, 6 s attention, 8 s warning, 10 s error. A lifetime of `autoAfter(ms)` uses exactly that
  value; `sticky` never expires and is removed only by dismissal or retraction.
- **Timers**: the timer starts when a notice first becomes visible, not when it is posted. A
  notice that later stops being visible keeps its deadline. One timer task sleeps until the
  earliest deadline; dismissing or retracting re-arms or cancels it.
  Deadlines saturate instead of overflowing, and the center clamps each sleep to 24 hours and
  re-arms for the remainder.
- **Capacity**: 20 notices; when full, the lowest-ranked is dropped: non-sticky before sticky,
  then lowest severity, then oldest.
- **Reconcile**: a source that mirrors external state (agent banners) hands the center its
  current list; notices are matched by id and bypass key dedupe, new ones are added, ones no
  longer present are retracted, and ids that were dismissed or have expired are not posted again
  (a bounded memory of 64 ids). Keys within one list must be unique.
- **Accessibility identifiers**: app, deep link, session and tmux notices use `session-notice`,
  terminal notices `notification-banner`, agent notices `agent-banner`.
