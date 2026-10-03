import Testing
@testable import ShuaiTerminal

@Suite("TerminalTheme")
struct TerminalThemeTests {
    @Test func hexParsingAndFormatting() {
        #expect(TerminalRGB(hex: 0x1E1E2E) == TerminalRGB(r: 0x1E, g: 0x1E, b: 0x2E))
        #expect(TerminalRGB(hex: 0xABCDEF).hexString == "#ABCDEF")
    }

    @Test func wcagContrastReferenceValues() {
        let black = TerminalRGB(hex: 0x000000), white = TerminalRGB(hex: 0xFFFFFF)
        #expect(abs(TerminalRGB.contrastRatio(black, white) - 21) < 0.001)
        #expect(abs(TerminalRGB.contrastRatio(white, white) - 1) < 0.001)
        // Symmetric.
        #expect(TerminalRGB.contrastRatio(white, black) == TerminalRGB.contrastRatio(black, white))
        // #777777 on white is the classic 4.48:1.
        #expect(abs(TerminalRGB.contrastRatio(TerminalRGB(hex: 0x777777), white) - 4.48) < 0.01)
    }

    @Test func builtInsAreWellFormed() {
        #expect(TerminalTheme.builtIn.count >= 2)
        for t in TerminalTheme.builtIn {
            #expect(t.palette.count == 16, "\(t.name)")
        }
        #expect(Set(TerminalTheme.builtIn.map(\.name)).count == TerminalTheme.builtIn.count)
    }

    @Test func defaultIsDarkRegardlessOfSystemAppearance() {
        #expect(TerminalTheme.default == .claudeDark)
        #expect(TerminalTheme.default.isDark)
        #expect(TerminalTheme.claudeDark.background.relativeLuminance < 0.05)
        #expect(!TerminalTheme.claudeLight.isDark)
        #expect(TerminalTheme.claudeLight.background.relativeLuminance > 0.8)
    }

    /// Colors 1-6 and 9-14 (red..cyan, normal + bright) carry meaning in Claude Code (diffs, inline code,
    /// links, warnings) and must be readable: WCAG ratio >= 3.0 against the background.
    /// 7 and 15 ("white") and 8 ("bright black", Claude's dim grey) are text colors too, so they are held
    /// to the same bar. Only color 0 ("black") is exempt from 3.0: it is the foreground of colored
    /// status/selection backgrounds and is expected to sit near the background; it must still be
    /// distinguishable (>= 1.5).
    @Test(arguments: TerminalTheme.builtIn)
    func paletteIsReadableOnBackground(theme: TerminalTheme) {
        for index in 1 ..< 16 {
            let ratio = TerminalRGB.contrastRatio(theme.palette[index], theme.background)
            #expect(ratio >= 3.0, "\(theme.name) color \(index) \(theme.palette[index].hexString) contrast \(ratio)")
        }
        #expect(TerminalRGB.contrastRatio(theme.palette[0], theme.background) >= 1.5, "\(theme.name) black")
    }

    @Test(arguments: TerminalTheme.builtIn)
    func foregroundAndCursorAreStronglyReadable(theme: TerminalTheme) {
        #expect(TerminalRGB.contrastRatio(theme.foreground, theme.background) >= 7.0, "\(theme.name) fg")
        #expect(TerminalRGB.contrastRatio(theme.cursor, theme.background) >= 3.0, "\(theme.name) cursor")
        // Selected text keeps the foreground color over the selection background.
        #expect(TerminalRGB.contrastRatio(theme.foreground, theme.selection) >= 4.5, "\(theme.name) selection")
    }

    /// Claude Code's inline code / links are ANSI blue (4) and bright blue (12); the original bug was a
    /// light-blue on light background. Require a comfortable ratio for those.
    @Test(arguments: TerminalTheme.builtIn)
    func bluesAreComfortable(theme: TerminalTheme) {
        #expect(TerminalRGB.contrastRatio(theme.palette[4], theme.background) >= 4.5, "\(theme.name) blue")
        #expect(TerminalRGB.contrastRatio(theme.palette[12], theme.background) >= 4.5, "\(theme.name) bright blue")
    }
}
