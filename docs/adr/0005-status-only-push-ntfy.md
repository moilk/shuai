# ADR 0005: Status-only background push through ntfy

Status: Accepted

## Context

iOS suspends the app soon after it leaves the screen, so the SSH connection and the agent stream
stop. Users still want to know when Claude needs approval or finished. APNs needs a server holding
an Apple push key, which means running a relay and handling user data. Prompts, commands and paths
are sensitive and must not leave the user's server.

## Decision

- `shuai-agent` sends pushes itself through **ntfy** (public ntfy.sh by default, self-hosted
  supported), shown by the ntfy iOS app. Opt-in; configured from the app into `~/.shuai/config.toml`.
- Pushes are **status only**: a fixed title per event class, the host name, the tmux
  `session › window index`, a `shuai://open?host=…&pane=…` link, a priority. Never prompts,
  commands, tool input, messages, paths or the working directory. Window names only on explicit
  opt-in (tmux names windows after the running command).
- Classification reads only the event type; a test asserts no event content reaches the request.
- Push only when no app is present; pair the permission request with Claude's matching notification
  and rate-limit other pushes per session.
- The topic is a random 128-bit secret stored in the Keychain; topic and token are never logged.

## Consequences

- No shuai backend and no Apple push key to operate.
- Users install a second app (ntfy) and must keep the topic private on a public server.
- Notifications cannot carry actions such as approve/deny; a tap opens the right pane instead.
- An APNs relay with Live Activities remains a v2 option.
