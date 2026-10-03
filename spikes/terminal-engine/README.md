# terminal-engine spike (M1)

Throwaway iPad app comparing libghostty (Lakr233/libghostty-spm) and SwiftTerm behind a
minimal `TerminalEngine` protocol. See `docs/adr/0001-terminal-engine.md`.

Build/run (needs Metal Toolchain for SwiftTerm: `xcodebuild -downloadComponent MetalToolchain`):

    cd App && xcodegen generate
    xcodebuild -scheme EngineSpike -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' \
      -derivedDataPath build -skipPackagePluginValidation -skipMacroValidation build
    xcrun simctl install booted build/Build/Products/Debug-iphonesimulator/EngineSpike.app
    ../run.sh ghostty dump 1      # headless-ish run: <engine> <dump|bench|both> [1 = stop before alt-screen exit]

- `expected/tmux-*.txt`: reference screens from `tmux 3.6a` (120x40) replaying the fixture.
- `results/`: engine screen dumps; `screens/`: simulator screenshots.
