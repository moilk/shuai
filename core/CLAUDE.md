# core/ (Rust workspace)

Edition 2024, resolver 3, one shared workspace version. Run from `core/`:
`cargo fmt --all --check && cargo clippy --workspace --all-targets -- -D warnings && cargo test --workspace`.

## Crate rules

- `shuai-proto`, `shuai-keys`, `shuai-tmux`, `shuai-agentkit` are sans-io: no clock, network or
  filesystem access; time and I/O results are passed in. Keep them that way.
- `shuai-ssh` is the only crate that talks to the network (russh). `ssh-key` is pinned to the exact
  version russh re-exports; bump both together.
- `shuai-agent` is a server binary (static musl): no panics escaping a hook, bounded reads, every
  file it creates is 0600 under a 0700 `$SHUAI_HOME`.
- `shuai-testkit` is dev-only; it reaches `shuai-ffi` only behind the `testkit` feature.

## FFI (`shuai-ffi`)

- Coarse API only: `SshConnection`, `ShellStream`, `ExecStream`, `TmuxController`, `ReconnectPolicy`,
  agent tracker. Never per-byte or per-cell calls; terminal bytes bypass Rust-side parsing.
- Plain data = `uniffi::Record`/`Enum` (named enum fields, tmux ids as strings `$0` `@1` `%2`);
  anything stateful or owning I/O = `uniffi::Object`. Types with a nicer Swift wrapper are
  `Ffi`-prefixed.
- Errors: one flat enum per domain (`FfiKeyError`, `FfiSshError`, `FfiTmuxError`, `FfiAgentError`),
  mapped 1:1 from the pure crates. No panics across the boundary.
- Async: `#[uniffi::export(async_runtime = "tokio")]`. Foreign traits use
  `#[uniffi::export(with_foreign)]` + `#[async_trait::async_trait]`; `HostKeyVerifierCallback`,
  `KbdPrompterCallback`, `PasswordPromptCallback` are async, `SignerCallback` is sync.
- Keys cross as unencrypted OpenSSH PEM; `import_key` normalises every supported format to it.
- `SshConnection.upload` streams to `cat > PATH && chmod -- MODE PATH` over exec (no SFTP yet),
  writing stdin while reading events; keep the API when SFTP replaces it.
- Every open stream must be drained until `Closed` (see `shuai-ssh/src/lib.rs` docs).

## Protocol and agent

- Wire types live in `shuai-proto`; decoding stays lenient (unknown event -> `Other`, new fields
  optional). Bump `PROTOCOL_VERSION` only for incompatible changes.
- Remote command lines are built in `shuai-agentkit` (`remote.rs`, `install.rs`) with `sh_quote`;
  request ids are validated with `is_valid_request_id` before use.
- Pushes (`shuai-agent/src/ntfy.rs`) classify by event type only; `tests/push.rs` must keep proving
  no event content reaches the request. Topic/token never in logs or argv.
- `plugin/.claude-plugin/plugin.json` version must equal the workspace version (`tests/plugin.rs`).

## tmux

- Split `-F` output with `shuai_tmux::parse::split_fields`, never `split(FIELD_SEP)`: tmux 3.4/3.5
  print the separator as `\037`.
- Version-dependent behaviour goes through `version::Capabilities`.
- Real-tmux tests use private sockets and clean up; target a build with
  `SHUAI_TMUX_BIN=/path/to/tmux cargo test -p shuai-tmux --test real_tmux`.

## Tests

- Integration tests in `<crate>/tests/`, fixtures in `<crate>/tests/fixtures/` (no personal data).
- SSH tests use `shuai-testkit` (`alice`/`secret`, `kbd`/`123456`, scripted exec commands).
- Manual ignored tests (`real_sshd_smoke`, `probe_over_ssh`) read hosts from env vars only.

More: `docs/design/architecture.md`, `docs/design/agent-protocol.md`, `docs/design/tmux-integration.md`.
