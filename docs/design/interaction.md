# Interaction

How the app presents state and feedback to the user. Presentation logic is pure Swift in `ShuaiApp`
(covered by `swift test`); views only render it.

## Notices

Transient in-app messages are `Notice` values held by `NoticeCenter` (ADR 0008). A notice has a
severity (info, success, attention, warning, error), a source (app, deep link, session, tmux,
terminal, agent), a scope (app-wide or one host), optional title, text, SF Symbol, optional action
(jump to an agent session, retry connect), a dedupe key and a lifetime.

- **Text**: untrusted. Complete ANSI escape sequences (CSI and OSC, found within the scan budget)
  are removed whole, so a colour code leaves no residue; a lone ESC is dropped. Control, format (bidi overrides and isolates, zero-width, tag) and
  blank-filler characters are removed (ZWJ and ZWNJ stay), newlines and tabs become spaces,
  whitespace is collapsed, at most 4 scalars are kept per grapheme cluster, the title is capped at
  80 characters and the text at 300 (an ellipsis marks truncation). Sanitizing is a single pass
  that stops reading once the cap is exceeded. A notice whose text is empty after sanitizing is
  ignored. Views render text with `Text(verbatim:)`.
- **Scope**: an app-scoped notice is eligible everywhere; a host-scoped notice only while that host
  is focused. Other hosts' notices wait and do not count as hidden.
- **Ordering**: severity descending, then newest first.
- **Max visible**: 3; 1 while pending permission cards are reported to the queue. The queue
  exposes the overflow as `hiddenCount`. Permission cards are drawn on top of the notice stack in
  its own column (see Placement and layering).
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
  longer present are retracted, held ones take the new content in place (same id, same timer),
  and ids that were dismissed or have expired are not posted again (a bounded memory of 64 ids; an
  id the source still reports is refreshed in that memory, so it cannot roll out while reported).
  Keys within one list must be unique.
- **Accessibility identifiers**: app, deep link, session and tmux notices use `session-notice`,
  terminal notices `notification-banner`, agent notices `agent-banner`.

### Sources

Each session posts through the `NoticePosting` it is given; none keeps notice state of its own.

| Source | Notice | Scope | Key |
|---|---|---|---|
| Terminal OSC 9/777 | info, titled `<host> · Terminal`; the remote's title and body only form the text | host | `osc:<host>` |
| tmux missing on the host | sticky warning, retracted on the next fresh connect | host | `tmux-missing:<host>` |
| Failed tmux action | error with the tmux message (home paths collapsed) | host | `tmux-error:<host>` |
| Agent needs input / done / failed | attention / success / error, titled `<host>: ...` like the banner it mirrors; tap jumps to the session; permission requests stay cards | app | `agent:<host length>:<host>\|<session>` |

Agent notices mirror `AttentionBannerQueue` (one banner per session, none for the session being
viewed, removed when the session ends or the request is cleared) through reconcile on every live
change, with the banner id as the notice id. Dismissing or expiring a notice dismisses its banner,
so it does not come back.

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
| host key prompt | card | Verify {host}'s host key | | Cancel | `connecting-card` |
| reconnecting | strip, progress | Reconnecting to {host} | Attempt N · retrying in Ns · typing paused | Retry now, Cancel | `reconnect-overlay` |
| failed | card, dims terminal | Can't connect to {host} | sanitized error message | Retry; plus Edit host (auth failed) or Open keys (key missing) | `connection-error` |
| disconnected | strip | Disconnected | Session ended (exit status N), when known | Reconnect | `disconnected-card` |

- The countdown is derived from the retry deadline at render time (rounded up, never below zero) and
  is omitted when no retry is scheduled.
- The failed message comes from the server or the transport, so it is untrusted: control and bidi
  override characters and ANSI escape sequences are removed, whitespace is collapsed and the text is
  capped at 300 characters (ellipsis included).
- Action identifiers: `retry-now`, `cancel-reconnect`, `cancel-connect`, `retry-connect`,
  `reconnect-session`, `edit-host`, `open-keys`.

### Placement and layering

Cards sit centred over the terminal; the scrim (30 % black) appears only for the failed card, so
the other cards leave the terminal visible. The strip is a compact bar without a scrim and keeps the
terminal readable and scrollable. Its countdown ticks once a second, and only while a retry is
scheduled.

Vertical order from the top of the terminal area: window tab strip (when tmux topology is shown),
connection strip (reconnecting, disconnected), notices.

Layering is separate: permission cards are drawn on top of the strip and the notices, in a trailing
column of up to 380 pt. While cards are pending, the strip and the notices reserve that column plus
a 10 pt gap, so their buttons stay tappable. When fewer than 280 pt would remain for them
(`NoticeLayout`), they take the full width at the bottom of the terminal area instead.

The window toolbar shows the status indicator (symbol, spoken as "{host}: {status label}",
identifier `connection-status`); the host list row uses the same symbol and label. Connection action
buttons are at least 44 pt tall, the minimum is part of the button label so the whole height is
tappable, and text from the server or host profile is rendered verbatim. Cancel while connecting (or
at the host key prompt) disconnects; Cancel while reconnecting ends the reconnect loop.

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

## Accessibility

- **44 pt targets.** Every tappable control is at least 44 x 44 pt. The minimum is set inside the
  button's label (`.frame(minWidth:minHeight:)` plus `.contentShape(Rectangle())`); a frame outside
  the `Button` enlarges the layout but not the tappable area. This covers the notice dismiss
  button, the Quick Switcher close button and the connection actions.
- **Scaled metrics.** Paddings, spacings and minimum target sizes in the notice rows, connection
  views, Quick Switcher and the AI install sheet are `@ScaledMetric(relativeTo: .body)`, so they grow
  with the text size.
- **Accessibility sizes.** At `dynamicTypeSize.isAccessibilitySize` the connection strip stacks
  vertically (icon and text, then the actions) and the card's actions stack, so text and buttons
  never overlap or truncate. Probe rows in the install sheet drop the one-line limit and wrap.
- **Status icons are spoken.** Install step icons carry `StepStatus.accessibilityLabel` ("Done",
  "Failed", "Needs your decision", "Running", "Pending", "Planned", "Skipped"), never the failure
  message. Each step row is one accessibility element.
- **Audit.** A UI test runs `performAccessibilityAudit` (Dynamic Type, hit region, element
  description) on the connection strip; the terminal surface is excluded.

## Modals

One `ModalRoute` is open at a time (`AppModel.modal`, decided by the pure `ModalRouter`) and
`RootView` shows it through a single `.sheet(item:)`: new or edited host, Settings, Keys, the quick
switcher and the AI-integration sheet. Opening a sheet resigns the terminal first responder.

- Nothing open: the request presents. The same route again is a no-op.
- The quick switcher yields: any other request replaces it.
- Every other open modal wins: a request for a different route is ignored, so menu chords (New Host
  ⌘N, Settings ⌘,, Quick Switcher ⌘K) never stack sheets. A modal with unsaved input is never
  replaced (`currentIsDirty`; the host editor does not report dirtiness yet).
- A late dismissal of a route that has already been replaced does not close its successor.

Keys is not a second sheet. Inside the host editor ("Open Keys", `editor-open-keys`) and Settings
("Keys", `settings-keys-link`) it is a page pushed in the sheet's navigation stack, so Back returns
with the editor's input and Settings intact; there is no Done on the pushed page. A standalone
request (toolbar, the connection card's Open keys) presents Keys as its own sheet with Done.

## Accessory bar accessibility

Each accessory key is spoken with a worded label from `AccessoryButton.spokenLabel` ("Escape",
"Up arrow", "Vertical bar", "Claude: Yes", "Interrupt, Escape"), so no label is a bare symbol and
the Claude strip's Esc differs from the standard one. Identifiers are `accessory-<key>` (Claude
strip `accessory-claude-<key>`). Ctrl and Alt expose their state as the accessibility value (Off,
On for the next key, Locked) and carry the selected trait when armed; a one-shot modifier also gets
a 2 pt border besides its fill, and a locked one the lock glyph, so state never relies on colour.

### Accessory bar Dynamic Type

Sizes come from `AccessoryBarMetrics` (pure, unit-tested). The key font is the 15 pt medium
monospaced face scaled with `UIFontMetrics(forTextStyle: .body)` and capped at 22 pt. A row is at
least 44 pt tall; that minimum scales with the (capped) text size, because a font capped at 22 pt
never outgrows 44 pt by itself. The docked bar is two rows plus a 4 pt gap and 4 pt insets (100 pt
at the default size, 88 pt before 44 pt rows); the floating bar is one row plus the insets. Key
minimum width scales the same way. Rows scroll horizontally when the keys no longer fit. On a
content-size change the bar rebuilds its button fonts, updates its height and the terminal view
reloads its input views, so the keyboard guide (and with it the terminal's bottom edge) picks up the
new height while the keyboard is up. Key order, mappings and sent bytes do not depend on the size.
