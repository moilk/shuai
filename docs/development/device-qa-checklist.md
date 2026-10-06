# Device QA checklist

Manual checks on a real iPad: what CI and the simulator cannot cover (IME, hardware keyboard,
Stage Manager, background behaviour, push). Run it before a release and after changes to the
terminal, keyboard handling, reconnect or notifications.

Prepare: a Linux server with tmux and Claude Code, a hardware keyboard (Magic Keyboard or similar),
the ntfy app. Install with [Installation](../user/installation.md), then connect and attach to tmux
([Getting started](../user/getting-started.md)).

For byte-level evidence install a **Debug** build with the launch argument `-debugByteTap`: every
channel write (W) and read (R) is logged via NSLog with timestamp, length and hex (visible in Xcode's
Devices and Simulators console). The log contains your keystrokes; scrub it before sharing.

## A. Chinese pinyin IME

Focus the terminal (tap it). Run every item with the **software keyboard** and with a **hardware
keyboard**, using Pinyin - Simplified.

- [ ] **A1 Candidate position**: type `nihao`. The underlined preedit appears inline at (or right
  next to) the cursor; the candidate bar does not cover the cursor and is not stuck in a corner.
- [ ] **A2 Commit**: choose a candidate with space, a number key or a tap. "ni hao" (U+4F60 U+597D) is committed once
  and echoed; the remote receives UTF-8 `e4 bd a0 e5 a5 bd`.
- [ ] **A3 Backspace while composing**: deletes pinyin letters, not previously committed text. Esc
  cancels the composition.
- [ ] **A4 Enter while composing**: type a long phrase (`woxihuanshiyongzhongduan`) and press
  Enter. Enter commits the text and sends no stray `0d` mid-composition.
- [ ] **A5 Control keys during IME** (hardware keyboard): Ctrl-C, arrows, Tab, Esc, Shift+arrows
  produce the right bytes; Caps Lock / Shift switching between Chinese and English loses no
  characters.
- [ ] **A6 Other input**: Apple Pencil Scribble, Wubi/Shuangpin if used, emoji picker (Globe) inserts
  one emoji once.
- [ ] **A7 Dictation and paste**: dictated text and pasted Chinese text arrive intact; programs with
  bracketed paste (vim, Claude) receive it bracketed.

## B. Hardware keyboard

- [ ] **B1 Shortcuts**: with the terminal focused, every chord in
  [Keyboard shortcuts](../user/keyboard-shortcuts.md) performs its action and the remote receives
  nothing for it (check with `cat -v` on the server or `-debugByteTap`). Each chord acts once (one
  new window per ⌘T), and the menu bar's tmux menu items work and are disabled without a live tmux.
- [ ] **B2 Option as Alt**: with "Option key sends Alt" on, Option+B / Option+F move by word in a
  readline shell and Option+letter works in vim; with it off (new session) Option types special
  characters.
- [ ] **B3 Copy and paste**: select text, ⌘C, then ⌘V: copied correctly, pasted exactly once.
- [ ] **B4 Zoom**: pinch and ⌘+ / ⌘−: font size changes smoothly, the grid is recomputed and tmux
  redraws without artefacts.
- [ ] **B5 Bar switching**: the docked bar sits above the software keyboard; attaching a hardware
  keyboard switches to the compact floating bar and back on detach, without flicker, focus loss or
  covering the terminal.

## C. Windowing and lifecycle

- [ ] **C1 Stage Manager and rotation**: resizing and rotating keep a sensible grid, tmux redraws, no
  garbled text, no crash.
- [ ] **C2 Background and return**: go to the Home Screen or lock for 1-2 minutes, then return. The
  app reconnects and reattaches to the same tmux session; a running Claude is still there and the
  screen is correct.
- [ ] **C3 Network loss**: airplane mode for 20 seconds, then off. The app shows reconnecting and
  recovers automatically.

- [ ] **C4 Airplane mode mid-session**: with output on screen, enable airplane mode. A strip under the
  window tabs shows "Reconnecting" with attempt, countdown and "typing paused"; the old output stays
  readable and scrollable. **Retry now** and **Cancel** work (Cancel ends the loop).
- [ ] **C5 Connect failures**: a wrong password shows a card with **Edit host**; a missing key shows
  **Open keys**; both offer **Retry**. Running `exit 3` shows a "Session ended (exit status 3)" strip
  with **Reconnect**.
- [ ] **C6 Narrow widths**: in Slide Over and a narrow split, the strip, notices and permission cards
  stay inside the view and tappable.

## D. Claude integration and notifications

Prerequisite: **Enable AI integration…** done for the host, `claude` running in tmux.

- [ ] **D1 Allow**: ask Claude to do something that needs permission (create a file). A card appears
  top right; Allow (or ⌘↩) lets Claude continue.
- [ ] **D2 Deny**: same, Deny with a message. Claude receives the denial and does not run the action.
- [ ] **D3 App offline**: quit shuai (swipe it away), then trigger a permission request. Claude shows
  its own dialog in the terminal immediately.
- [ ] **D4 Badges and jumps**: sidebar badges follow working / waiting / done; ⌘K lists the waiting
  session first; ⌘⇧A jumps to it.
- [ ] **D5 Push**: enable push, subscribe in ntfy, "Send test notification" arrives. Background or
  lock shuai, trigger a permission request: "Claude needs approval" arrives within seconds; the body
  shows only host and `session › window index` (no window name by default).
- [ ] **D5b Push topic**: on Settings > Background push (ntfy) the topic is masked
  (`shuai-••••…wxyz`); Show and Hide toggle it; backgrounding the app hides a revealed topic. Copy
  topic, then paste in the ntfy app within two minutes (works) and again after two minutes on this
  iPad (pasteboard is empty of it; a copy pasted on another device through Universal Clipboard is
  not removed). VoiceOver reads "Topic hidden, ends in ..." while masked. At the largest Dynamic
  Type size every row on the page stays readable and tappable.
- [ ] **D6 Deep link**: tapping that notification opens shuai, connects the host and selects the
  right pane.

## E. Notices and accessibility

- [ ] **E1 No tmux**: on a host without tmux, the warning notice is sticky and survives switching
  hosts and back.
- [ ] **E2 Repeated OSC 9**: `for i in 1 2 3; do printf '\e]9;hi\a'; done` gives one "<host> · Terminal"
  notice with ×N.
- [ ] **E3 Hostile OSC body**: a very long body, bidi overrides and ANSI colour codes in an OSC 9
  message show capped, clean text.
- [ ] **E4 Layering**: with a permission card pending, the card is never covered, and the notices and
  the connection strip stay tappable beside it.
- [ ] **E5 Agent banner**: when Claude finishes or waits in another session, a banner appears; tapping
  it jumps to that session (no UI test covers this).
- [ ] **E6 VoiceOver**: the status indicator reads "<host>: Reconnecting" while reconnecting; a notice
  reads its severity first (for example "Warning. ...").
- [ ] **E7 Dynamic Type**: at the largest sizes the strip and cards stay legible, wrap instead of
  clipping, and keep full-height buttons.

## F. Sidebar bottom bar

- [ ] **F1 Software keyboard**: with the terminal focused and the software keyboard up, the bottom
  bar (New Host, Settings) is covered; dismissing the keyboard (or tapping a sidebar row) brings it
  back. ⌘N and ⌘, work with a hardware keyboard.
- [ ] **F2 Portrait overlay sidebar**: in portrait the sidebar is an overlay; the bottom bar sits at
  its bottom, above the home indicator, and New Host and Settings open their sheets.
- [ ] **F3 Narrowest Stage Manager width**: both bottom-bar items stay visible and tappable (New Host
  does not truncate into the gear).
- [ ] **F4 VoiceOver order**: Sidebar toggle, Quick Switcher, then the rows, then "New Host" and
  "Settings" last. At the largest Dynamic Type, New Host is icon-only and still read as "Add Host".
- [ ] **F5 Full Keyboard Access**: Tab reaches Quick Switcher, the rows, New Host and Settings; Space
  activates them.

## Reporting

For every failure record: iPad model and iPadOS version, keyboard (software / model), input method,
steps, expected vs actual (quote dropped or duplicated characters exactly). Screen recordings help a
lot, especially for IME and shortcut issues. File issues at
<https://github.com/moilk/shuai/issues>.
