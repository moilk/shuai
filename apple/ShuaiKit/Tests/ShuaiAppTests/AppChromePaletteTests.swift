import Testing

@testable import ShuaiApp
@testable import ShuaiTerminal

@Suite struct AppChromePaletteTests {
    @Test func ristrettoChromeUsesItsOwnColors() {
        let p = AppChromePalette(theme: .monokaiProRistretto)
        #expect(p.accent == TerminalRGB(hex: 0xF38D70))
        #expect(p.surface == TerminalRGB(hex: 0x2C2525))
        #expect(p.text == TerminalRGB(hex: 0xFFF1F3))
        #expect(p.prefersDark)
    }

    @Test func lightThemeAsksForTheLightAppearance() {
        #expect(!AppChromePalette(theme: .claudeLight).prefersDark)
        #expect(AppChromePalette(theme: .claudeDark).prefersDark)
    }

    @Test func settingsThemeSelectsThePalette() {
        #expect(AppSettings.Theme.ristretto.chrome.accent == TerminalTheme.monokaiProRistretto.palette[4])
        #expect(AppSettings.Theme.light.chrome.surface == TerminalTheme.claudeLight.background)
    }

    /// Icons and highlights use the accent on the surface; text uses `text` on it.
    @Test(arguments: TerminalTheme.builtIn)
    func accentAndTextAreReadableOnTheSurface(theme: TerminalTheme) {
        let p = AppChromePalette(theme: theme)
        #expect(TerminalRGB.contrastRatio(p.accent, p.surface) >= 3.0, "\(theme.name) accent")
        #expect(TerminalRGB.contrastRatio(p.text, p.surface) >= 7.0, "\(theme.name) text")
    }

    @Test func semanticColorsComeFromTheAnsiPalette() {
        let t = TerminalTheme.monokaiProRistretto
        let p = AppChromePalette(theme: t)
        #expect(p.error == t.palette[1])
        #expect(p.success == t.palette[2])
        #expect(p.warning == t.palette[3])
        #expect(p.selection == t.selection)
    }

    @Test func elevatedSurfacesSitBetweenTheSurfaceAndTheText() {
        for theme in TerminalTheme.builtIn {
            let p = AppChromePalette(theme: theme)
            #expect(p.elevated != p.surface, "\(theme.name)")
            #expect(p.elevated.relativeLuminance != p.text.relativeLuminance, "\(theme.name)")
            #expect(p.separator != p.surface, "\(theme.name)")
        }
    }

    /// Secondary text and the semantic colors sit on both the surface and cards, so both count.
    @Test(arguments: TerminalTheme.builtIn)
    func secondaryAndSemanticColorsAreReadableOnSurfaceAndCards(theme: TerminalTheme) {
        let p = AppChromePalette(theme: theme)
        for (name, color, minimum) in [
            ("secondary", p.secondaryText, 4.5), ("error", p.error, 3.0),
            ("success", p.success, 3.0), ("warning", p.warning, 3.0), ("accent", p.accent, 3.0),
        ] {
            #expect(TerminalRGB.contrastRatio(color, p.surface) >= minimum, "\(theme.name) \(name) on surface")
            #expect(TerminalRGB.contrastRatio(color, p.elevated) >= minimum, "\(theme.name) \(name) on card")
        }
        #expect(TerminalRGB.contrastRatio(p.text, p.elevated) >= 7.0, "\(theme.name) text on card")
    }
}
