# ADR 0001: Terminal engine

Status: Accepted

## Context

shuai renders Claude Code TUIs over SSH and tmux: heavy CJK and emoji, box drawing, synchronized
output, hardware and software keyboards, and Chinese pinyin input, which must work well on iPad.
The engine must sit behind a thin Swift protocol and should not rule out an Android app sharing the
same core.

## Options

- **A. libghostty** through the community Swift package `Lakr233/libghostty-spm` (MIT): Ghostty's
  Zig VT core and Metal renderer as a prebuilt xcframework plus a UIKit `UITerminalView`.
- **B. SwiftTerm** (MIT): pure Swift, mature, UIKit view.
- **C. libghostty-vt + own renderer**: VT state only, rendering written in-house.

Evaluation replayed a real Claude Code session recording (`fixtures/recordings/`, 120x40, CJK) in
both A and B on an iPad simulator and compared against tmux's own rendering:

| Criterion | libghostty | SwiftTerm |
|---|---|---|
| Screen correctness vs tmux | identical | identical |
| CJK rendering | natural glyph advance | correct grid, visibly wide letter-spacing |
| Box drawing / backgrounds | pixel-aligned | small gaps |
| Parse throughput (debug, sim) | about 21 MB/s, off the main thread | about 1.4 MB/s, on the main thread |
| IME | inline preedit at the cursor; candidate window anchored to the cursor rect | marked text in a shadow buffer; `caretRect`/`firstRect` return the view bounds |
| Build | prebuilt binary target, no Zig for consumers | source build; needs the Metal Toolchain in CI |
| Android path | libghostty-vt cross-compiles for Android | none |

Option C was rejected for v1 scope.

## Decision

Use **libghostty via `Lakr233/libghostty-spm`, pinned `exact: 1.6.20261003`**, behind the
platform-neutral `TerminalEngine` protocol (`ShuaiTerminal`). SwiftTerm is not shipped; the
protocol keeps a swap possible.

## Consequences

- Best IME and CJK experience and fast, off-main-thread parsing.
- Dependency on a single-maintainer wrapper that tracks Ghostty's development branch, with an
  embedded C API that is not declared stable. Mitigation: exact version pin, deliberate upgrades,
  a thin `TerminalEngine` boundary, and migration to an official Ghostty Swift package once one
  exists.
- The static library adds roughly 20 MB per device slice.
- Behaviour the simulator cannot prove (pinyin and other IMEs with software and hardware keyboards,
  Stage Manager) is verified with the [device QA checklist](../development/device-qa-checklist.md).
- iOS-specific choices around the engine: engine replies are routed to the remote through
  `onInput`; Option-as-Alt is implemented by the app (`OptionAsAlt`) rather than Ghostty's macOS
  option; OSC 52 writes require user confirmation.
- An Android app would use libghostty-vt with a Compose renderer.
