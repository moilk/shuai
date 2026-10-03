# ADR 0001: Terminal engine (libghostty vs SwiftTerm)

Status: Proposed (pending manual IME test on real iPad) · Date: 2026-10-03 · Milestone: M1 spike

## Context

shuai is an iPad AI-coding SSH terminal (Rust core + native Swift UI, Android later). The plan
(`docs/plan`) names libghostty as the primary engine and SwiftTerm as the iPad fallback, behind a Swift
`TerminalEngine` protocol. Workload: Claude Code TUIs over SSH/tmux/mosh, heavy CJK + emoji, box drawing,
synchronized output, hardware + software keyboards, **Chinese pinyin IME** (the hard requirement on iPad).

M1 goal: pick the engine with evidence. Spike code: `spikes/terminal-engine/` (iPad app, iOS 18, XcodeGen,
segmented control Ghostty/SwiftTerm, both behind `TerminalEngine { feed, resize(cols:rows:), onInput }`).

## Options

A. **libghostty** via Swift package `Lakr233/libghostty-spm` (MIT; prebuilt `GhosttyKit.xcframework` binaryTarget
   + `GhosttyTerminal` Swift wrapper with UIKit `UITerminalView`, `InMemoryTerminalSession`). Metal renderer,
   Ghostty's Zig VT core. Pinned to a Ghostty tip commit (`upstream.0538f7535be0`).
B. **SwiftTerm** `migueldeicaza/SwiftTerm` 1.20.0 (MIT), pure Swift, UIKit `TerminalView` (UIScrollView),
   Metal renderer in recent versions, long history (Termius/Secure Shellfish/La Terminal lineage).
C. libghostty-vt only (VT parser/state, no renderer) + own renderer: rejected for M3 scope; revisit later.

Upstream status: `ghostty-org/ghostty` has `include/ghostty/vt/*.h` (libghostty-vt C API, "stable behaviour,
signatures in flux") but **no official Swift package yet**; Mitchell Hashimoto announced a Swift Metal renderer +
libghostty-vt bindings as "coming soon" on 2026-07-02 (https://x.com/mitchellh/status/2072724957902381319);
`ghostty-org` org repos list (2026-10-03): ghostty, ghostling (C example), zig-gobject, website. So community
wrappers are the only option today. `AkinoKaede/libghostty-spm` is a 0-star fork of Lakr233's, so Lakr233 is the
reference wrapper (111 stars, 305 commits, pushed 2026-10-02, tags 1.6.2026100x almost daily).

## Evidence

| Criterion | libghostty (Lakr233 spm 1.6.20261003) | SwiftTerm 1.20.0 |
|---|---|---|
| Correctness vs tmux 3.6a, fixture at 120x40, screen before alt-screen exit (40 rows) | **identical** (0 diffs after right-trim) | identical (0 diffs after NUL normalisation, see notes) |
| Same, whole fixture incl. exit to primary screen | identical | identical |
| CJK width (2-cell), Chinese punctuation, mixed lines | correct, glyph advance natural (screens/ghostty-*.png) | correct grid, but CJK glyphs drawn with wide letter-spacing, looks sparse (screens/swiftterm-*.png) |
| Emoji 🤝 ✅ (VS/ZWJ not in fixture) | correct, colour emoji, 2 cells | correct, colour emoji, 2 cells; `getLine().translateToString` drops non-BMP unless `characterProvider: getCharacter(for:)` is passed (dump API quirk, rendering fine) |
| Box drawing / diff-block backgrounds / table | pixel-aligned, continuous lines | aligned, background blocks have small inset gaps |
| DEC 2026 sync output | N/A in fixture (0 occurrences of `?2026h/l` in the recording: Claude Code did not emit it in this session); not verified, test with synthetic stream in M3 | same |
| Replay throughput, N=50 x 46,758 B (debug, sim) | feed 0.1 ms (async), parsed in 0.11 s = ~21 MB/s | 1.62 s sync on main thread = ~1.4 MB/s |
| Memory (phys_footprint, sim) | 18.5 -> 19.0 MB after replay, 20.7 after 50x | 18.5 -> 21.3 MB, 28.1 after 50x |
| Binary size (Release, arm64 device, both engines linked) | libghostty.a ios-arm64 slice 19.5 MB (xcframework 189 MB across all slices, download once) | pure Swift, + 1 metallib resource |
| Linked app executable, both engines, Release | 12.4 MB total (per-engine split not measured) | |
| Build complexity | prebuilt xcframework (SPM binaryTarget, zip from GitHub release); **no Zig needed** for consumers; Zig only to rebuild (`build.sh`) | SPM source; Swift tools 6.2; needs **Metal Toolchain** (`xcodebuild -downloadComponent MetalToolchain`, 839 MB) and `-skipPackagePluginValidation` for its build-info plugin in CLI/CI |
| Maintenance | very active, but single maintainer wrapper tracking Ghostty tip; binary pinned to a non-release commit | active (v1.20.0 2026-08-18, pushed 2026-10-02), 1.7k stars, mature |
| License | MIT (Ghostty MIT, wrapper MIT, themes MIT) | MIT |
| Platforms | iOS 15+/macOS/visionOS; **Android possible via libghostty-vt** | Apple (iOS/macOS) only. Package also builds on Linux/Windows/wasm for the headless core, but no Android UI/view |

Screenshots (iPad Pro 13" M5 sim, portrait, 120x40, fixture replayed instantly):
`spikes/terminal-engine/screens/{ghostty,swiftterm}-{pre-exit,full-replay}.png`. Expected screens from tmux:
`spikes/terminal-engine/expected/`. Engine dumps: `spikes/terminal-engine/results/`.

Notes on mismatches: none of substance. Both agree with tmux on CJK/emoji/box-drawing cell layout. Differences
were harness artefacts: SwiftTerm uses NUL for blank cells and for the right half of wide chars (normalised);
trailing-newline of the dump. Visual difference: SwiftTerm CJK letter-spacing and a Ghostty default theme/colour
palette difference (cosmetic, themeable). Ghostty replies to kitty-keyboard query `CSI ? u` (`ESC[?0u` seen on
`onInput`), confirming that query/response sequences must be routed to the remote, not locally echoed.

### IME (source review; UITextInput + marked text)

Both iOS views implement `UITextInput` with marked text, so pinyin composition is at least wired in both.

libghostty `UITerminalView` (`Sources/GhosttyTerminal/Platform/UIKit/UITerminalView+UITextInput.swift` in
Lakr233/libghostty-spm): `extension UITerminalView: UITextInput, UITextInputTraits` (l.15), `setMarkedText`
(l.195) / `unmarkText` (l.205) / `markedTextRange` (l.212) delegate to `TerminalTextInputHandler@UIKit.swift`
(`setMarkedText` l.141, `unmarkText` l.188), which call `view.surface?.preedit(text)` so the **preedit is
rendered inline by Ghostty at the cursor**, and on commit send the text as key events. Geometry:
`firstRect(for:)` l.337 and `caretRect(for:)` l.344 return real cell-based rects (`caretRectForPosition`
l.435, `markedTextRect`), so the candidate popup anchors at the cursor. `selectionRects` returns `[]`.
Also handles sticky modifiers + inputDelegate will/did-change notifications.

SwiftTerm `TerminalView` (`Sources/SwiftTerm/iOS/iOSTextInput.swift` in SwiftTerm): `extension TerminalView:
UITextInput` (l.72), `setMarkedText` (l.251), `unmarkText` (l.297) maintain a shadow `textInputStorage` +
`_markedTextRange` (iOSTerminalView.swift l.356-378) and flush to the terminal on unmark; includes Korean
resyllabification workarounds. But `firstRect(for:)` (l.365) and `caretRect(for:)` (l.369) simply **return
`bounds`**, so the candidate/pinyin popup is not anchored to the cursor, and marked text is not drawn inline
in the terminal grid (it lives in the shadow buffer). Works functionally, UX weaker for Chinese IME.

Conclusion from source: libghostty wrapper is clearly ahead for Chinese IME UX; real behaviour (hardware
keyboard + Pinyin/Wubi/handwriting, Magic Keyboard, Stage Manager) must be confirmed on a device.

### Android feasibility

- libghostty-vt (zero-dependency VT core, C API) cross-compiles for `aarch64-linux-android`/x86_64. Ghostty
  discussion #10902 "ci: Add lib-vt Android support" (https://github.com/ghostty-org/ghostty/discussions/10902):
  Zig lacks bionic libc support so a Zig-linked `.so` can lack `DT_NEEDED libc.so` (dlopen fails on
  `__tls_get_x`); recommended workaround is linking with the Android NDK, plus `link_z_max_page_size = 16384`.
- Existing projects: `SagerNet/libghostty-android` (MIT, "libghostty-vt bindings and terminal components for
  Android", Kotlin + Compose, `io.github.sagernet:libghostty-android:0.1.0-alpha01`, last push 2026-09-09, IME
  input aligned with Termux); `nev3rfail/ghostty-android`; `sixtythreelabs/expo-libghostty` ships libghostty-vt
  arm64-v8a/x86_64 Android artifacts.
- Not verified locally (no NDK build attempted in this spike). The full libghostty (renderer, Metal) is not
  portable to Android; only libghostty-vt is. Android would therefore use libghostty-vt + a Compose renderer.
- SwiftTerm: Apple platforms only for the view layer; no Android path.

## Recommendation

Use **libghostty (Lakr233/libghostty-spm) as the primary iPad engine**, keep SwiftTerm as the drop-in
fallback behind `TerminalEngine`. Rationale: identical screen correctness to tmux on the real Claude Code
fixture; far faster parse path with off-main-thread parsing and built-in backpressure; much better IME
geometry and inline preedit; consistent engine across iOS and (via libghostty-vt) Android; no Zig for
consumers. Prerequisite gate: the user's real-device IME test below must pass; if Pinyin composition is broken in
the Ghostty view, fall back to SwiftTerm (and fix `caretRect`/`firstRect` upstream) for v1.

## Risks

- Single-maintainer community wrapper pinned to a Ghostty tip commit; API churn (v2.0.0 renamed APIs). Mitigate:
  pin an exact version, vendor/fork the repo, keep `TerminalEngine` protocol thin; watch for official
  ghostty-org Swift package (announced 2026-07-02) and migrate.
- libghostty embedded C API is not declared stable; wrapper patches Ghostty (`Patches/`).
- 19.5 MB static lib (per device slice) increases app size; Metal renderer on iOS less battle-tested than
  SwiftTerm in the wild.
- Wrapper bundles its own font/theme handling; CJK fallback fonts and font-size units differ (font-size 10 in the
  Ghostty config ≈ 7.7 pt cell width vs SwiftTerm 14 pt ≈ 8.4 pt; calibrate).
- DEC 2026, mouse, bracketed paste, OSC 52/9/777, kitty keyboard not covered by this fixture/spike; test in M3.
- SwiftTerm fallback requires Metal Toolchain in CI and has a main-thread-bound feed path (1.4 MB/s in this
  sim test) plus CJK letter-spacing.
- Not measured: battery, frame times/FPS, real-device behaviour, release-build throughput.

## Pending manual IME test (real iPad, user)

Install the spike on device (open `spikes/terminal-engine/App`, set your team, run). For each engine
(segmented control), with both the **software keyboard** and a **hardware keyboard** (Magic Keyboard / Smart
Keyboard) and in the bottom-left the terminal view focused (tap it), after replaying the fixture:

1. Switch to Pinyin (Simplified). Type `nihao`: the preedit (underlined `ni hao`) must appear at the cursor
   or at least near it; candidate bar/popup must not cover or sit at the screen corner.
2. Select candidate with space / number key / tap: committed `你好` appears once; the status line shows the
   `onInput` UTF-8 bytes `e4 bd a0 e5 a5 bd` and the terminal echoes it.
3. Backspace during composition removes pinyin letters, not previously committed text. Esc cancels.
4. Type a long sentence (`woxihuanshiyongzhongduan` etc.), commit with Enter: Enter must commit, not send `\r`
   mid-composition (check `onInput` has no stray `0d`).
5. Hardware keyboard: Ctrl-C, arrows, Tab, Esc, Shift+arrows still produce correct bytes while IME is active;
   Caps-lock/shift toggles Chinese/English without lost characters.
6. Handwriting (Apple Pencil Scribble) and Wubi/Shuangpin if you use them; emoji picker (Globe) inserts 😀 once.
7. Dictation and paste of Chinese text (`paste` should arrive bracketed if enabled).
8. Stage Manager window resize / rotate: grid stays 120 columns sensible, no crash, text not garbled.
9. Record: pass/fail per engine, plus any dropped/duplicated characters. Attach screen recording if failing.

## Consequences

If accepted: M3 builds `TerminalView` on libghostty with the `TerminalEngine` protocol (extended with
paste/key encoding, selection, theming, scroll), keeps a SwiftTerm adapter compiled behind a flag until the
Ghostty path has passed real-device IME and soak tests, and tracks the official Ghostty Swift package.
