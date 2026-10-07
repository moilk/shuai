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

The window toolbar shows the status indicator (symbol plus a small down arrow that marks it as a
menu, so an error symbol (a red cross) does not read as a close button; spoken as
"{host}: {status label}" with the hint "Opens the connection menu", identifier
`connection-status`, at least 36 pt) as the label of a menu; the host list row uses the same symbol and label. The menu starts with a non-interactive
header (host name and status label), then Disconnect (`disconnect-button`, destructive) while
connected, otherwise Reconnect (`connect-button`). There is no separate disconnect button, so no
single tap disconnects; ⌘W and ⌘R in the Session menu stay. Connection action
buttons are at least 44 pt tall, the minimum is part of the button label so the whole height is
tappable, and text from the server or host profile is rendered verbatim. Cancel while connecting (or
at the host key prompt) disconnects; Cancel while reconnecting ends the reconnect loop.

### Window tab strip

Shown above the terminal while the sidebar is collapsed and a tmux topology exists. From the
leading edge: the session menu (`window-tab-session-menu`, spoken "Session: {name}", symbol
`rectangle.stack`), one tab per window of the viewed session (`window-tab-{id}`, value exactly
`active` or empty, label `{index}: {name}[, zoomed][, {badge}]`) and a new-window button
(`window-tab-new`). The strip itself is `window-tab-strip`.

- Tabs and both buttons are at least 44 pt; the minimum and the content shape belong to the button
  label so the whole area is tappable. The strip has no fixed height: paddings and spacing scale
  with Dynamic Type.
- The session menu lists the host's sessions from the topology, marks the viewed one and switches
  with the same action as the sidebar's **Switch to Session**; it also offers **New Window** in the
  viewed session.
- A tab's context menu is the sidebar's window menu (`TmuxWindowMenu`: Rename, New Window, Split,
  Close; closing asks first); the rename alert is shared too (`windowRenameAlert`).
- Badges keep their symbol, and zoom and badge are part of the spoken label, so nothing is
  colour-only. The rows come from `TabStripModel` (pure, tested in `ShuaiApp`).

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

## Modals

One `ModalRoute` is open at a time (`AppModel.modal`, decided by the pure `ModalRouter`) and
`RootView` shows it through a single `.sheet(item:)`: new or edited host, Settings, Keys, the quick
switcher and the AI-integration sheet. Opening a sheet resigns the terminal first responder.

- Nothing open: the request presents. The same route again is a no-op.
- The quick switcher yields: any other request replaces it.
- Every other open modal wins: a request for a different route is ignored, so menu chords (New Host
  ⌘N, Settings ⌘,, Quick Switcher ⌘K) never stack sheets. A modal with unsaved input is never
  replaced (`currentIsDirty`). The open host editor reports its dirtiness through
  `AppModel.editorIsDirty`, which `AppModel` reads only for the new and edit host routes and clears
  when the modal is dismissed.
- A late dismissal of a route that has already been replaced does not close its successor.

Keys is not a second sheet. Inside the host editor ("Generate a key" while the library is empty, `editor-open-keys`) and Settings
("Keys", `settings-keys-link`) it is a page pushed in the sheet's navigation stack, so Back returns
with the editor's input and Settings intact; there is no Done on the pushed page. A standalone
request (the app menu's Keys…, the connection card's Open keys) presents Keys as its own sheet with Done.

## Toolbar and menus

The sidebar uses the system bars (no custom floating buttons):

- **Top.** The system sidebar toggle, the brand "shuai" as a leading toolbar item (`title2` bold,
  scales with Dynamic Type, header trait, identifier `sidebar-title`; the system's centred title is
  empty) and one trailing item, Quick Switcher (`quick-switcher-button`, magnifying glass). On
  iOS 26 the brand has no glass background.
- **Bottom bar** (`.bottomBar` toolbar on the sidebar column): nothing on the leading side; New Host
  (`add-host-button`, plus, spoken "New Host") and Settings (`settings-button`, gear, spoken
  "Settings") are icon-only and sit together at the trailing side after a flexible space. System
  icon-only bottom-bar buttons report 36 pt (a 44 pt frame makes them report as not hittable), so
  the UI tests assert at least 36 pt and hittable for both; the accessibility label keeps the text
  for VoiceOver at every text size. Settings opens the Settings sheet directly; there is no menu.
- **Keys** is not in the sidebar. It is reached through Settings > SSH > Keys, the app menu's Keys…,
  the host editor's Open/Generate a key and the connection card's Open keys.

All items go through `AppModel.request`, so they obey the modal rules above. Trade-off: while the
software keyboard is up (the terminal is focused) it covers the sidebar's bottom bar. Hardware
keyboard users use ⌘N, ⌘, and the menu bar; with the software keyboard, dismiss it (or tap a sidebar
row) to reach the bar.

The menu bar mirrors the same actions and the keyboard shortcuts for discoverability:

- App menu: Settings… (⌘,) and Keys… (no chord). File: New Host (⌘N). Go: Quick Switcher, Next
  Agent Needing Attention.
- A **tmux** menu lists New Window, Close Window, Previous/Next Window, Split Right/Down, Zoom Pane
  and Window 1-9 (`TmuxMenuState`, derived from `ShortcutMap`). Items call
  `AppModel.handleShortcut` for the selected host and are disabled unless that host's tmux is live
  or polling. The items carry no keyboard shortcut of their own: the terminal's priority key commands
  own the chords and tmux commands are not idempotent, so a second delivery path could run an
  action twice.
- New Host, Settings…, Keys… and Quick Switcher are disabled while a modal that cannot be replaced
  is open (`ModalRouter.canPresent`).

## Editor

The host editor's logic is the pure `HostEditorDraft` (every field as text, no password),
`HostEditorValidation`, `HostEditorDirty`, `HostEditorSaveError` and the save flow
`HostEditorSave`; the view only renders them. The view keeps the host id, the initial snapshot and
the save progress in `@State`, because the sheet content is rebuilt whenever the app model changes.

- A field's error shows once the field lost focus or Save was tapped, and hides as soon as the field
  is valid. It renders as an `exclamationmark.circle.fill` label with the message text.
- Save is never disabled. With errors it focuses the first invalid field in form order (the key
  choice, which takes no text focus, is scrolled into view) and posts a VoiceOver announcement
  shortly after, so the focus speech does not cut it off.
- Cancel with unsaved changes (any edited field, or a typed password) asks "Discard Changes" /
  "Keep Editing". Swipe-to-dismiss is disabled while dirty rather than prompting. The key choice
  only counts as a change for key auth.
- The password lives only in view state and is written only to the Keychain. It is cleared when the
  editor closes (Save, Discard, or the sheet's navigation stack disappearing). The lifecycle hook is
  on the `NavigationStack` itself, which does not disappear when a page is pushed, so a pushed Keys
  page covers the form without clearing the password or the dirty state (UI test
  `testPushingKeysKeepsThePasswordAndDirtyState`).
- When an earlier Save stored a new host but not its password, the discard dialog says so ("The host
  is already saved, but its password is not stored…"); the stored host stays and is selected when
  nothing else is.
- The editor's save state is in `@State`, so a rebuilt sheet content keeps the host id; no automated
  test rebuilds the view, only the pure save flow is tested.
- Save errors use fixed copy and never include an underlying error's description. "Host saved, but
  the password could not be stored" is shown only when the host write of that same attempt
  succeeded; a retry updates the same host.
- A new host defaults to SSH key auth when the library has keys (preselected when there is one),
  otherwise Ask each time. A key generated from the pushed Keys page is selected when none was chosen.

  otherwise Ask each time. A key generated from the pushed Keys page is selected when the method is
  SSH key and no key was chosen. "Generate a key" appears under the SSH key method when the library
  is empty.

## Sidebar

`HostListView` renders `SidebarModel.rows` (pure, in `ShuaiApp/Sidebar/`): one `List(selection:)`
of host, loading, session, window and pane rows. Only host rows are tagged for selection; tmux rows
are plain buttons. Indentation is `row.depth` times a
`@ScaledMetric` step, capped at two levels at accessibility text sizes.

- **Current location.** Hosts use the list's system selection. The one current location in the tmux
  tree is secondary: the viewed session row has a light accent tint, a filled icon and `.isSelected`;
  the active window and its active pane get the accent colour, weight, `.isSelected` and the
  accessibility value `active` only inside the viewed session (`isCurrent` on `WindowRowModel` and
  `PaneRowModel`). Other sessions' active windows look like any other window, however many sessions
  are expanded.
- **Defaults.** Hosts and the viewed session are expanded, other sessions collapsed. Collapsing
  never changes selection, and an agent needing attention never expands anything.
- **Persistence.** `SidebarExpansionStore` keeps only the exceptions to the defaults, keyed by host
  UUID and session name (never tmux `$N`/`@N`/`%N` ids, which are reused after a server restart), in
  UserDefaults, capped at 256 entries. Deleting a host forgets its entries; launch prunes entries of
  hosts that no longer exist. UI tests use an isolated suite per launch.
- **Host row.** One element (`host-row-<name>`) holds status symbol, name and target, so its tap
  and long-press area is at least 44 pt tall; its label comes from the model. Beside it: the host
  aggregate badge (`host-aggregate-badge`, the most urgent pane badge, visible while collapsed), the
  waiting count (hand symbol plus number) and a 44 x 44 chevron (`host-toggle-<name>`,
  `tmux-session-toggle-<name>` for sessions) that is also exposed as an Expand/Collapse
  accessibility action.
- **Menus.** The host menu keeps Edit and Delete and groups the AI items in an "AI integration"
  section; while the host is not connected they are disabled and say "Connect to this host first".
  Session rows offer Switch to Session and New Window; window and pane menus live in the shared
  `TmuxWindowMenu`/`TmuxPaneMenu`. New Window always targets the row's own session
  (`TmuxActions.newWindow(inSession:)`, which accepts only a known `$N` id).
- **Accessibility text.** Window rows keep the accessibility value `active`/empty (`active` only for the current window); the richer text
  (index, name, pane count, zoom, badge) is the label. The pane dot is decorative and hidden.

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

## Chrome policy

`ChromePolicy.decide(ChromeInputs)` in `ShuaiApp` is the single decision for which chrome surrounds
the terminal; views feed it the inputs and apply the result. Contract:

- Window tab strip: shown iff the host has a tmux topology, the sidebar is collapsed or full screen is
  on, and either the tab strip mode is Always or the viewed session has more than one window or the
  host has more than one session. Automatic therefore hides it only for one window in one session.
- Navigation bar: shown iff not full screen. Status bar and home indicator: hidden iff full screen.
- Full-screen handle: shown iff full screen; prominent when the connection is not connected or a
  permission request is pending for the host, quiet otherwise.
- Accessory bar: hidden iff "hardware keyboard bar" is Hide, a hardware keyboard is attached and no
  software keyboard is visible. Otherwise the placement is `AccessoryBarPlacement.decide` (docked or
  floating) with the same inputs, so a software keyboard always keeps its docked bar.

`FullScreenState` remembers the sidebar column visibility on entering full screen (which collapses to
detail only) and restores it on leaving, unless the user changed the columns in between.

Full screen is toggled by `AppModel.setFullScreen`, which applies the sidebar change and the setting in
one state change so the terminal resizes once. It applies only while a host's terminal is shown, and
is not restored at launch. Entry points: ⌃⌘F (`ShortcutAction.toggleFullScreen`, delivered by the
terminal's key command only; the View menu item has no chord, because a second delivery path would
toggle straight back) and the View menu. Leave through the handle's menu, the chord, the View menu or
the VoiceOver escape gesture. The handle (`FullScreenHandle`) is a 44 pt status symbol that opens a
menu: host and status, Disconnect or Reconnect, Show Sidebar, Quick Switcher, Exit Full Screen. It is an
overlay at the top trailing edge, or the trailing end of the tab strip when that is shown, so it never
resizes the terminal.

Persisted settings (`AppSettings`): `tabStrip` (`automatic` default, `always`), `hardwareKeyboardBar`
(`show` default, `hide`), `fullScreen` (`false`, reset at launch); unknown stored values fall back to the
defaults. Apart from the tab strip becoming automatic, the defaults keep the previous behaviour.
