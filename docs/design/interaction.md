# Interaction design

How the app presents state and feedback to the user. Presentation logic is pure Swift in `ShuaiApp`
(covered by `swift test`); views only render it.

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
