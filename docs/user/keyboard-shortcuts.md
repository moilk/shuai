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
| ⌘K | Go | Quick Switcher |
| ⌘⇧A | Go | Next Agent Needing Attention |
| ⌘W | Session | Disconnect the selected host |
| ⌘R | Session | Reconnect the selected host |

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
