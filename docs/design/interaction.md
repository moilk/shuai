# Interaction

How the app presents state and feedback to the user. Presentation logic is pure Swift in `ShuaiApp`
(covered by `swift test`); views only render it.

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

### Sources

Each session posts through the `NoticePosting` it is given; none keeps notice state of its own.

| Source | Notice | Scope | Key |
|---|---|---|---|
| Terminal OSC 9/777 | info, titled `<host> · Terminal`; the remote's title and body only form the text | host | `osc:<host>` |
| tmux missing on the host | sticky warning, retracted on the next fresh connect | host | `tmux-missing:<host>` |
| Failed tmux action | error with the tmux message (home paths collapsed) | host | `tmux-error:<host>` |
| Agent needs input / done / failed | attention / success / error, titled `<host>: ...` like the banner it mirrors; tap jumps to the session; permission requests stay cards | app | `agent:<host>\|<session>` |

Agent notices mirror `AttentionBannerQueue` (one banner per session, none for the session being
viewed, removed when the session ends or the request is cleared) through reconcile on every live
change, with the banner id as the notice id. Dismissing a notice dismisses its banner; an expired
notice stays gone while its banner remains queued.

Keys are per host, so two hosts never replace each other and a flood of identical OSC messages
from one host collapses into one notice with a count.

The remote never chooses the notice title, so a terminal notice cannot pass for an agent notice,
and it ranks below real attention. A controller that is removed or replaced retracts its keys and
posts nothing afterwards. An identical repost less than a second after the previous one only
raises the count; it does not restart the timer.

## Connection states

`ConnectionPresentation.make(state, hostName:, target:)` maps a `SessionState` to what the UI shows.

Principle: only states without a usable live channel block the terminal. Reconnecting and
disconnected keep the last output readable, so they are a strip, not a card.

| State | Placement | Title | Detail | Actions | Identifier |
|---|---|---|---|---|---|
| idle, connected | none | | | | |
| connecting | card, progress | Connecting to {host}… | target | Cancel | `connecting-card` |
| authenticating | card, progress | Signing in to {host}… | target | Cancel | `connecting-card` |
| host key prompt | card | Verify {host}'s host key | | | `connecting-card` |
| reconnecting | strip, progress | Reconnecting to {host} | Attempt N · retrying in Ns · typing paused | Retry now, Cancel | `reconnect-overlay` |
| failed | card, dims terminal | Can't connect to {host} | sanitized error message | Retry; plus Edit host (auth failed) or Open keys (key missing) | `connection-error` |
| disconnected | strip | Disconnected | Session ended (exit status N), when known | Reconnect | `disconnected-card` |

- The countdown is derived from the retry deadline at render time (rounded up, never below zero) and
  is omitted when no retry is scheduled.
- The failed message comes from the server or the transport, so it is untrusted: control and bidi
  override characters are removed, whitespace is collapsed and the text is capped at 300 characters.
- Action identifiers: `retry-now`, `cancel-reconnect`, `cancel-connect`, `retry-connect`,
  `reconnect-session`, `edit-host`, `open-keys`.

### Placement and stack order

Cards sit centred over the terminal; the scrim (30 % black) appears only for the failed card, so
the other cards leave the terminal visible. The strip is a compact bar without a scrim and keeps the
terminal readable and scrollable. Its countdown ticks once a second, and only while a retry is
scheduled. From the top of the terminal area:

1. window tab strip (when tmux topology is shown)
2. connection strip (reconnecting, disconnected)
3. notices
4. permission cards, always on top

The window toolbar shows the status indicator (symbol, spoken as "{host}: {status label}",
identifier `connection-status`); the host list row uses the same symbol and label. Action buttons
have at least 44 pt hit targets, and text from the server or host profile is rendered verbatim.
Cancel while connecting disconnects; Cancel while reconnecting ends the reconnect loop.

### Status indicator

Each status has its own symbol and label, so state never relies on colour alone:

| Status | Symbol | Label |
|---|---|---|
| off | `circle.dashed` | Not connected |
| busy | `circle.dotted` | Connecting |
| connected | `checkmark.circle.fill` | Connected |
| warning | `arrow.triangle.2.circlepath` | Reconnecting |
| error | `xmark.octagon.fill` | Connection failed |

The accessibility label of every presentation, including the hidden ones, is "{host}: {status label}".
