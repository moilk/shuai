# Background notifications (ntfy)

iOS does not let an app keep an SSH connection open in the background. To hear about agents while
shuai is not on screen, the `shuai-agent` on your server can push notifications through
[ntfy](https://ntfy.sh), which the free ntfy iOS app displays. Pushes carry **status only**.

## Set up

1. In shuai: Settings > Background notifications > turn on **Push notifications (ntfy)**. The
   server defaults to `https://ntfy.sh` and a random private topic is generated
   (`shuai-` + 26 base32 characters, 128 random bits). Topic and access token are stored in the
   Keychain.
2. Install the official **ntfy** app from the App Store, then tap **Open in ntfy app** in shuai to
   subscribe to the topic (or subscribe manually with **Copy topic**).
3. Tap **Send test notification**.
4. Get the settings onto your hosts. They are written to `~/.shuai/config.toml` by **Enable AI
   integration…**, automatically on connect when they changed, by **Sync to connected hosts** in
   Settings, and by **Sync notification settings** in a host's menu. A new topic or toggling push
   reaches connected hosts immediately.

Optional settings in the same section:

- **Server**: your own ntfy server, plus an access token if it requires one. An `http://` server
  shows a cleartext warning.
- **New topic**: rotates the topic (resubscribe in the ntfy app afterwards).
- **Include tmux window names**: off by default, see below.

## When a push is sent

Only when ntfy is configured on the host **and no shuai app is watching it** (no `watch`
heartbeat within the last 30 seconds):

| Event | Title | Priority |
|---|---|---|
| Permission request | Claude needs approval | high |
| Claude waiting for input (idle prompt) | Claude is waiting for input | default |
| Claude finished a turn (main agent, not subagents) | Claude finished | default |
| Claude stopped with an API error | Claude stopped with an error | default |
| Codex finished a turn | Codex finished | default |

De-duplication: the permission request and Claude's matching "needs permission" notification
are merged into one push within 60 seconds. Other pushes are limited to one per session every 10
seconds; approvals are never rate limited.

## What a push contains

- Title: one of the fixed strings above.
- Body: the host's name in shuai, plus the tmux `session › window index` of the agent's pane, e.g.
  `devbox · main › 2`.
- Click URL: `shuai://open?host=<host id>&pane=<%N>`.

It never contains prompts, commands, tool input, assistant messages, file paths or the working
directory. The server-side code reads only the event type to build a push, and a test asserts that
no event content reaches the HTTP request.

**Window names are off by default** because tmux's automatic rename sets a window's name to the
command running in it (`vim secrets.env`, `ssh prod-db`). Turn on **Include tmux window names** if
you want `main › 2: claude` instead.

**Keep the topic private.** On the public ntfy.sh server anyone who knows a topic can read its
messages. Use the generated random topic, rotate it if it leaks, or run your own server with an
access token.

## Deep links

Tapping a notification opens `shuai://open?host=<id>&pane=<%N>`: shuai selects that host,
connects if needed and shows the pane. The link is parsed strictly (`host` must be a single host id
(UUID) and `pane`, if present, must look like `%123`); anything else is rejected rather than guessed. Local
notification taps use the same route.
