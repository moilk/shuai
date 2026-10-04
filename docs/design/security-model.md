# Security model

## Assets

- SSH credentials: private keys, saved passwords, keyboard-interactive answers.
- The user's server: shell access, files, running agents.
- Agent content: prompts, commands, tool input and messages in `~/.shuai/events.jsonl`.
- The ntfy topic and token.

## Trust boundaries

| Party | Trusted for |
|---|---|
| The iPad and the app binary | everything (it holds the keys) |
| The SSH server, after host key verification | being the server the user meant; **not** for the content it sends |
| Network between iPad and server | nothing (SSH protects it) |
| ntfy server | nothing beyond delivering status-only messages |
| Other local users on the server | nothing (state files are 0600 / 0700) |

There is no shuai backend; no third party sees SSH traffic.

## Threats and mitigations

### Man in the middle

- TOFU with OpenSSH `known_hosts` semantics, matching done in Rust (`shuai-keys`).
- `TOFUVerifier` rejects a **changed** key unless the explicit changed-key handler accepts it; the
  unknown-host prompt can never approve a changed key. Accepting replaces the old entry.
- Passwords are sent, and "Ask each time" passwords requested, only after host key verification
  (`FfiAuth.passwordPrompt`).

### Hostile server output (terminal)

The server can send arbitrary bytes.

- The terminal engine (libghostty) parses everything; the app does not interpret escape sequences
  itself except what is listed here.
- OSC 52 clipboard writes are configured as `ask`; the user must approve each.
- OSC 9/777 notifications are shown as in-app banners (plain text).
- `DeviceReplyGuard` forwards engine replies to device queries (DA1, DA2, XTVERSION) only when
  matched with a recent unanswered query, so stale replies cannot be injected as typed input.
- Scrollback is capped (`scrollback-limit`), output queues are byte-bounded, and engine tests
  replay recordings repeatedly to check memory stays bounded.

### Hostile server output (tmux and agent channels)

- tmux names and values arrive escaped by tmux and are parsed strictly; malformed rows are
  rejected (`shuai-tmux` property and robustness tests).
- Agent events are untrusted JSON: lenient decoding into typed values, unknown events become
  `other`, lines over 1 MiB are dropped by the app's line splitter.
- Permission cards render tool input as plain text (`Text(verbatim:)`), length-capped
  (`PermissionPreview`): a huge or crafted `tool_input` cannot stall layout or execute anything.
- Commands sent back to the host are built in Rust with shell quoting; request ids are validated
  against `[A-Za-z0-9_-]{1,128}` before they reach a command line or a file name.

### Deep links

`shuai://open?host=<UUID>&pane=<%N>` can be opened by any app or web page. The parser accepts
exactly one `host` UUID and an optional `pane` matching `%[0-9]{1,9}`; everything else is rejected.
A link can only select an existing host and a pane; it never runs a command or creates a host.

### Server-side state

- `~/.shuai` is forced to 0700 and its files to 0600; a looser pre-existing `config.toml` or
  directory is tightened when read.
- Permission request ids carry 128 random bits, so another local user cannot guess a response
  file name (and cannot write into the 0700 directory anyway).
- Hooks never fail or block Claude: they always exit 0, bound their input, and fall back to
  Claude's own dialog on any doubt (no app present, timeout).

### Secrets handling

- Private keys and passwords live in the Keychain with `AfterFirstUnlockThisDeviceOnly`; iCloud
  Keychain sync is opt-in at the API level and not used.
- The ntfy topic and token live in the Keychain, never in UserDefaults.
- Generated FFI records that carry secrets (`KeyMaterial`, `FfiAuth`) have redacting
  descriptions, so they cannot leak through logging or string interpolation.
- `shuai-agent` never logs the topic or token: config parse errors report a line number only,
  HTTP errors are redacted, `doctor` prints `ntfy_configured` only, and the push job reaches the
  detached sender over stdin, not argv (argv is visible in `ps`).
- Pushes are status-only by construction (see [ADR 0005](../adr/0005-status-only-push-ntfy.md));
  `core/shuai-agent/tests/push.rs` asserts that no event content reaches the ntfy request.

### Test and debug code in release builds

- `SHUAI_FFI_TESTKIT=1` builds embed an SSH server with hard-coded credentials.
  `scripts/check-no-testkit.sh` fails if `start_test_ssh_server` is exported from any slice of the
  xcframework; it runs at the end of every normal `scripts/build-xcframework.sh` and in CI.
- DEBUG launch arguments (`-debugAutoAcceptHostKey` would disable TOFU, `-debugHostFile`,
  `-debugByteTap` logs keystrokes, ...) are compiled only under `#if DEBUG`.
  `scripts/check-no-debug-launch.sh` builds Release and fails if their strings are present.
- Release builds fail without the bundled agent binaries, so a release can never silently ship
  without them.

## Out of scope

- A compromised server or server account: it can run anything as the user, including Claude.
- A compromised or jailbroken iPad.
- Confidentiality against the ntfy operator of the fact that *some* status event happened.
