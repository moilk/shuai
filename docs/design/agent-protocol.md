# Agent protocol

`shuai-agent` is a small static Rust binary installed at `~/.shuai/bin/shuai-agent`. Claude Code
hooks (and Codex `notify`) call it to record events; the app calls it over SSH exec channels to
follow events and answer permission requests. There is no daemon and no listening socket: every
invocation is a short-lived process, except `watch`, which lives as long as the app's exec
channel. Rationale: [ADR 0003](../adr/0003-server-agent-hooks-jsonl.md).

Source: `core/shuai-agent` (binary), `core/shuai-proto` (wire types), `plugin/` (hooks).

## Hook events

The plugin (`plugin/hooks/hooks.json`) registers these Claude Code hooks, each running
`[ -x "$HOME/.shuai/bin/shuai-agent" ] || exit 0; exec "$HOME/.shuai/bin/shuai-agent" hook <Event>`
(a silent no-op when the binary is missing):

| Hook | Mode | Used for |
|---|---|---|
| `SessionStart`, `SessionEnd` | async, 15 s | session lifecycle, title, model |
| `UserPromptSubmit` | async, 15 s | working state, last prompt |
| `PreToolUse`, `PostToolUse` | async, 15 s | current tool; clearing a pending permission |
| `Notification` | async, 15 s | `permission_prompt`, `idle_prompt` (needs input) |
| `Stop`, `SubagentStop` | async, 15 s | done; subagent count |
| `StopFailure` | async, 15 s | failed |
| `PermissionRequest` | **sync**, timeout 120 s, `--timeout 110` | native permission cards |

`PermissionDenied` is understood by the parser but not registered. Codex calls
`shuai-agent codex-notify '<json>'` for `agent-turn-complete`.

Hook invariants:

- A hook **always exits 0** and never writes to stdout except a permission decision; errors go to
  `~/.shuai/agent.log`. Bad arguments, invalid JSON and panics are logged, never returned to Claude.
- Stdin is read up to 32 MiB. `PostToolUse.tool_response` is dropped. In payloads over 100 kB every
  string longer than 8192 characters is clipped.
- `$TMUX_PANE` and the socket from `$TMUX` are recorded so events map to tmux panes.

## Event log format

Events are appended as JSON Lines to `~/.shuai/events.jsonl`, one `Envelope` per line, under an
exclusive `flock` (`events.lock`, bounded 5 s wait) so `seq` is strictly increasing in file order:

```json
{"v":1,"seq":42,"ts_ms":1791018660469,"host":"devbox","source":"claude",
 "tmux":{"pane":"%3","socket":"/tmp/tmux-1000/default"},"pid":578230,
 "event":{"type":"permission_request","session_id":"…","cwd":"/home/dev/proj",
          "request_id":"2604cfd0b70257a07ee252c762c243d8","tool_name":"Bash",
          "tool_input":{"command":"touch ok.txt"},"raw":{…}}}
```

| Field | Meaning |
|---|---|
| `v` | `PROTOCOL_VERSION` (currently 1) |
| `seq` | Per-host counter (file `seq`; recovered from the log if lost) |
| `ts_ms` | Unix time in ms |
| `host` | `$SHUAI_HOSTNAME` or `uname -n` |
| `source` | `claude` or `codex` |
| `tmux` | `{pane, socket?}` when the hook ran inside tmux |
| `pid` | Parent process id of the hook (the process that ran it) |
| `event` | `AgentEvent`, tagged by `type` |

`AgentEvent` types: `session_start`, `session_end`, `user_prompt_submit`, `pre_tool_use`,
`post_tool_use`, `permission_request`, `permission_denied`, `permission_resolved`, `notification`,
`stop`, `subagent_stop`, `stop_failure`, `agent_turn_complete` (Codex) and `other`. Hook events keep
the common context (`session_id`, `prompt_id`, `transcript_path`, `cwd`, `permission_mode`,
`agent_id`, `agent_type`) flattened, typed fields per event, and the original payload in `raw`.
`permission_resolved` is written by the agent itself with `request_id`, `outcome`
(`allowed` / `denied` / `timeout` / `not_present`) and `session_id`.

Compatibility: decoding is lenient. An unknown or malformed `event` becomes `other` instead of
failing the line; malformed lines are skipped. New fields must be optional.

The log rotates to `events.jsonl.1` when it would exceed 5 MiB (`SHUAI_MAX_LOG_BYTES`); one rotated
file is kept.

## CLI

| Command | Purpose |
|---|---|
| `shuai-agent hook <Event> [--timeout SECS]` | Hook entry point; reads the hook JSON on stdin. `--timeout` (default 110) applies to `PermissionRequest`. |
| `shuai-agent watch [--since SEQ] [--heartbeat-secs SECS]` | Stream events as JSONL (see below). Defaults: `--since 0`, heartbeat every 5 s. |
| `shuai-agent respond <REQUEST_ID> allow\|deny [--message MSG]` | Answer a pending permission request. The app passes `--message=<quoted>`. |
| `shuai-agent notify --title T --body B [--click URL] [--priority P] [--tags T]` | Send one ntfy push with the configured server/topic (manual testing). |
| `shuai-agent codex-notify '<json>'` | Codex `notify` program entry. |
| `shuai-agent doctor` | Print an environment report as JSON. |
| `shuai-agent push-send` | Hidden, internal: send one push described by a JSON job on stdin. |
| `shuai-agent --version` | Version. |

### `watch`

1. Prints `{"type":"heartbeat"}` and touches the presence file.
2. Replays every envelope with `seq > since` from `events.jsonl.1` and `events.jsonl`. A `since`
   larger than the current counter (the state dir was wiped) replays everything.
3. Prints `{"type":"caught_up"}`; everything after it is live.
4. Follows the file (polling every 50 ms, backing off to 200 ms when idle; survives rotation) and
   prints a heartbeat every `--heartbeat-secs`.

It exits quietly when stdout closes. The app reconnects with `--since <highest seq seen>`, and the
Rust tracker deduplicates replays and detects a restarted counter.

### `doctor`

Keys: `version`, `protocol`, `os`, `arch`, `binary`, `state_dir`, `state_dir_writable`, `last_seq`,
`app_present`, `claude_path`, `plugin_installed`, `tmux_version`, `tmux_allow_passthrough`,
`ntfy_configured`. Secrets are never printed.

## Presence

The app is "present" on a host while the `presence` file was touched within the last 30 seconds
(`SHUAI_PRESENCE_TTL_SECS`); every `watch` heartbeat touches it. Presence decides whether a
permission request waits for the app and whether a push is sent.

## Permission round trip

1. The `PermissionRequest` hook assigns a 128-bit random `request_id` (hex) and records the event.
2. Not present: it records `permission_resolved{not_present}`, may push, and exits with no output.
   Claude shows its own dialog.
3. Present: it polls `responses/<request_id>.json` every 50 ms (`SHUAI_POLL_MS`).
4. The app runs `shuai-agent respond <id> allow|deny [--message=...]`, which validates the id
   (`[A-Za-z0-9_-]{1,128}`) and writes the response atomically (temp file + rename, mode 0600).
   Unconsumed responses older than one hour are pruned.
5. The hook prints
   `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow|deny","message":"…"}}}`
   and records `permission_resolved{allowed|denied}`.
6. If presence lapses while waiting the result is `not_present`; after `--timeout` (110 s, below
   the hook's 120 s limit) it is `timeout`. Both exit without output, so Claude falls back to its
   own dialog.

A request answered in the terminal produces a later `PostToolUse` or `permission_resolved`, and
the app clears the card.

## State directory

`$SHUAI_HOME` (default `~/.shuai`) is created 0700; files are created 0600.

| Path | Content |
|---|---|
| `bin/shuai-agent` | The binary (0755) |
| `events.jsonl`, `events.jsonl.1` | Event log and one rotated file |
| `events.lock`, `seq` | Append lock and sequence counter |
| `presence` | Touched by `watch` heartbeats |
| `responses/` | Permission answers `<request_id>.json` |
| `config.toml` | Written by the app (below) |
| `push.json`, `push.lock` | Push de-duplication / rate-limit state |
| `agent.log`, `agent.log.1` | Diagnostics (rotated at 512 KiB) |
| `plugin-marketplace/` | Local plugin marketplace, only when installed offline |

## `config.toml`

Written by the app (atomically: a 0600 temp file under umask 077, then `mv` + `chmod 600`). When the
agent reads it, it tightens a looser file or directory to 0600/0700; parse errors are logged by
line number only.

```toml
# Written by the Shuai app. Changes are overwritten.
host_id = "11111111-2222-3333-4444-555555555555"   # HostProfile UUID, used in shuai:// links
host_name = "devbox"                                # shown in push bodies

[ntfy]
server = "https://ntfy.sh"
topic = "shuai-…"
token = "…"            # optional
window_names = false   # include tmux window names in pushes (opt-in)
```

Without `host_id` the hostname is used; without `[ntfy]` no push is sent.

## Environment variables

| Variable | Default | Effect |
|---|---|---|
| `SHUAI_HOME` | `~/.shuai` | State directory |
| `SHUAI_HOSTNAME` | `uname -n` | `host` in envelopes |
| `SHUAI_MAX_LOG_BYTES` | 5 MiB | Rotation size |
| `SHUAI_PRESENCE_TTL_SECS` | 30 | Presence window |
| `SHUAI_PUSH_MIN_INTERVAL_SECS` | 10 | Minimum gap between non-approval pushes per session |
| `SHUAI_POLL_MS` | 50 | Poll interval of `watch` and permission waits |

## Versioning

`PROTOCOL_VERSION` (in `shuai-proto`) is bumped only for incompatible wire changes. The app reads the
installed agent's `--version`: the host row asks for an update when it is older than the agent
bundled with the app, and the installer uploads the bundled binary whenever the versions differ.
See [Release](../development/release.md).
