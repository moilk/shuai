# ADR 0002: Rust core with UniFFI bindings

Status: Accepted

## Context

shuai needs SSH, key handling, tmux control-mode parsing, agent-state tracking and install planning.
The iPad app comes first, but an Android app is planned, and the server-side agent shares wire types
with the app. Logic duplicated in Swift and Kotlin would drift, and UI-bound code is slow to test.

## Decision

- Implement all protocol and state logic in a Rust workspace (`core/`): sans-io crates where
  possible (`shuai-proto`, `shuai-keys`, `shuai-tmux`, `shuai-agentkit`), russh for SSH
  (`shuai-ssh`).
- Export it through **UniFFI** from one crate, `shuai-ffi`, built as a static xcframework for iOS,
  the iOS simulator and macOS (`scripts/build-xcframework.sh`). Kotlin bindings for Android come
  from the same crate later.
- Keep the boundary coarse: session/stream-level objects, records for data, flat error enums,
  foreign callback traits for platform services (host key prompt, signer, password prompt).
- Native UI per platform (SwiftUI/UIKit on iPad), no cross-platform UI toolkit.

## Consequences

- Most logic is tested with `cargo test`, fast and without simulators; Swift wrappers stay thin.
- `shuai-agent` and the app share `shuai-proto`, so the wire format cannot diverge.
- An Android app needs a UI and platform adapters only.
- Build complexity: Rust targets plus a generated xcframework and bindings before any Swift build;
  the generated Swift code is compiled in Swift 5 language mode.
- Per-byte or per-cell FFI calls are ruled out; terminal bytes go straight to the platform engine.
