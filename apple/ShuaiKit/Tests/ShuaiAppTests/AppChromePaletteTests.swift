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
}
