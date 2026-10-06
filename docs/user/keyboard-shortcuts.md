# Keyboard shortcuts

With a hardware keyboard, shuai handles these chords itself while the terminal has focus; they are
**not** sent to the server. Everything else goes to the terminal (Ghostty's key encoder, including
the kitty keyboard protocol when the remote program requests it).

## tmux and navigation

Defaults from `ShortcutMap.defaults` (`apple/ShuaiKit/Sources/ShuaiApp/ShortcutMap.swift`):

| Shortcut | Action |
|---|---|
| ⌘1 … ⌘9 | Window 1-9 by position in the window list (not the tmux index, so `base-index` does not matter) |
| ⌘T | New window |
| ⌘⇧W | Close window (asks for confirmation) |
| ⌘⇧[ / ⌘⇧] | Previous / next window |
| ⌘D | Split right |
| ⌘⇧D | Split down |
| ⌘⌥← / ⌘⌥→ / ⌘⌥↑ / ⌘⌥↓ | Select pane left / right / up / down |
| ⌘⇧↩ | Zoom / unzoom pane |
| ⌘K | Quick switcher |
| ⌘⇧A | Next agent needing attention (across hosts) |

## App menus

Defined in `apple/App/Sources/ShuaiMain.swift`; these also work when the sidebar has focus.

| Shortcut | Menu | Action |
|---|---|---|
| ⌘N | File | New Host |
| ⌘, | App | Settings… |
| (none) | App | Keys… |
| ⌘K | Go | Quick Switcher |
| ⌘⇧A | Go | Next Agent Needing Attention |
| ⌘W | Session | Disconnect the selected host |
| ⌘R | Session | Reconnect the selected host |

The **tmux** menu lists New Window, Close Window, Previous/Next Window, Split Right/Down, Zoom Pane
and Window 1-9 for the selected host. The chords are the terminal shortcuts above (the menu items
themselves show none); the items are disabled unless that host has a live tmux.

The sidebar has Quick Switcher in its top bar and **New Host** and **Settings** (gear) in a bottom
bar. The software keyboard covers that bar while it is up; ⌘N, ⌘, and the menu bar do the same
without it. Keys… is in the app menu (and in Settings > Keys).

## Terminal

| Shortcut | Action |
|---|---|
| ⌘+ / ⌘− (or pinch) | Zoom the terminal font |
| ⌘C / ⌘V | Copy selection / paste (bracketed when the program enables it) |
| Option + key | Alt (Esc prefix) when Settings > Keyboard > "Option key sends Alt" is on (default) |

## Permission card

When a permission card is shown and its message field is not being edited:

| Shortcut | Action |
|---|---|
| ⌘↩ | Allow |
| ⌘⌫ | Deny |

## Customization

`ShortcutMap` can be encoded as JSON (`{"newWindow": "cmd+t", "selectPane.left": "cmd+opt+left"}`)
and an action `lastWindow` exists without a default binding, but there is no settings UI for custom
shortcuts yet (see the [roadmap](../roadmap.md)).
