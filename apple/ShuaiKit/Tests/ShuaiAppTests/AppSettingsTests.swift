import Foundation
import Testing
@testable import ShuaiApp

@MainActor
private func suite() -> UserDefaults {
    let name = "shuai.tests.\(UUID().uuidString)"
    let d = UserDefaults(suiteName: name)!
    d.removePersistentDomain(forName: name)
    return d
}

@MainActor
@Suite("AppSettings chrome")
struct ChromeSettingsTests {
    @Test func defaultsKeepCurrentBehaviourExceptTabStripAutomatic() {
        let s = AppSettings(defaults: suite())
        #expect(s.tabStrip == .automatic)
        #expect(s.hardwareKeyboardBar == .show)
        #expect(!s.fullScreen)
        #expect(s.accessoryBar == .docked)
        #expect(s.theme == .ristretto)
        #expect(s.theme.terminalTheme == .monokaiProRistretto)
        #expect(s.optionAsAlt)
    }
    @Test func tabStripModePersists() {
        let d = suite()
        AppSettings(defaults: d).tabStrip = .always
        #expect(AppSettings(defaults: d).tabStrip == .always)
        #expect(d.string(forKey: "tabStrip") == "always")
    }
    @Test func hardwareKeyboardBarPersists() {
        let d = suite()
        AppSettings(defaults: d).hardwareKeyboardBar = .hide
        #expect(AppSettings(defaults: d).hardwareKeyboardBar == .hide)
        #expect(d.string(forKey: "hardwareKeyboardBar") == "hide")
    }
    @Test func fullScreenPersists() {
        let d = suite()
        AppSettings(defaults: d).fullScreen = true
        #expect(AppSettings(defaults: d).fullScreen)
        #expect(d.bool(forKey: "fullScreen"))
    }
    @Test func unknownRawValuesFallBackToDefaults() {
        let d = suite()
        d.set("bogus", forKey: "tabStrip")
        d.set("bogus", forKey: "hardwareKeyboardBar")
        d.set("bogus", forKey: "accessoryBar")
        d.set("bogus", forKey: "fullScreen")
        let s = AppSettings(defaults: d)
        #expect(s.tabStrip == .automatic)
        #expect(s.hardwareKeyboardBar == .show)
        #expect(s.accessoryBar == .docked)
        #expect(!s.fullScreen)
    }
    @Test func accessoryBarRawValuesUnchanged() {
        #expect(AppSettings.AccessoryBarStyle.docked.rawValue == "docked")
        #expect(AppSettings.AccessoryBarStyle.floating.rawValue == "floating")
        #expect(AppSettings.AccessoryBarStyle.allCases.count == 2)
    }

    @Test func aStoredDarkThemeKeepsClaudeDark() {
        let d = suite()
        d.set("dark", forKey: "theme")
        let s = AppSettings(defaults: d)
        #expect(s.theme == .dark)
        #expect(s.theme.terminalTheme == .claudeDark)
    }
}
