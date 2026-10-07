import Foundation
import Testing
@testable import ShuaiApp
@testable import ShuaiTerminal

private func inputs(
    hasTopology: Bool = true, windows: Int = 1, sessions: Int = 1,
    sidebarCollapsed: Bool = true, fullScreen: Bool = false,
    tabStrip: TabStripMode = .automatic, preferFloating: Bool = false,
    hardwareKeyboardBar: HardwareKeyboardBar = .show,
    hardwareKeyboard: Bool = false, softwareKeyboardVisible: Bool = false,
    status: SessionState.Status = .connected, permissionPending: Bool = false
) -> ChromeInputs {
    ChromeInputs(
        hasTopology: hasTopology, windowCount: windows, sessionCount: sessions,
        sidebarCollapsed: sidebarCollapsed, fullScreen: fullScreen,
        tabStrip: tabStrip, preferFloatingBar: preferFloating, hardwareKeyboardBar: hardwareKeyboardBar,
        hardwareKeyboard: hardwareKeyboard, softwareKeyboardVisible: softwareKeyboardVisible,
        status: status, permissionPendingForHost: permissionPending)
}

@Suite("ChromePolicy")
struct ChromePolicyTests {
    @Test func tabStripHiddenWhileSidebarVisible() {
        #expect(!ChromePolicy.decide(inputs(windows: 3, sidebarCollapsed: false)).showsTabStrip)
    }
    @Test func tabStripHiddenWithoutTopology() {
        #expect(!ChromePolicy.decide(inputs(hasTopology: false, windows: 3, tabStrip: .always)).showsTabStrip)
    }
    @Test func automaticHidesSingleWindowSingleSession() {
        #expect(!ChromePolicy.decide(inputs()).showsTabStrip)
    }
    @Test func automaticShowsWithSeveralWindows() {
        #expect(ChromePolicy.decide(inputs(windows: 2)).showsTabStrip)
    }
    @Test func automaticShowsWithSeveralSessions() {
        #expect(ChromePolicy.decide(inputs(sessions: 2)).showsTabStrip)
    }
    @Test func alwaysShowsSingleWindow() {
        #expect(ChromePolicy.decide(inputs(tabStrip: .always)).showsTabStrip)
    }
    @Test func fullScreenShowsTabStripRulesEvenIfSidebarStateIsStale() {
        #expect(ChromePolicy.decide(inputs(windows: 2, sidebarCollapsed: false, fullScreen: true)).showsTabStrip)
        #expect(!ChromePolicy.decide(inputs(sidebarCollapsed: false, fullScreen: true)).showsTabStrip)
    }
    @Test func navigationBarShownOutsideFullScreen() {
        #expect(ChromePolicy.decide(inputs()).showsNavigationBar)
    }
    @Test func fullScreenHidesNavigationStatusBarAndHomeIndicator() {
        let d = ChromePolicy.decide(inputs(fullScreen: true))
        #expect(!d.showsNavigationBar && d.hidesStatusBar && d.hidesHomeIndicator)
        let n = ChromePolicy.decide(inputs())
        #expect(!n.hidesStatusBar && !n.hidesHomeIndicator)
    }
    @Test func handleOnlyInFullScreen() {
        #expect(ChromePolicy.decide(inputs(fullScreen: true)).showsHandle)
        #expect(!ChromePolicy.decide(inputs()).showsHandle)
    }
    @Test func handleProminentWhenNotConnected() {
        for s in [SessionState.Status.off, .busy, .warning, .error] {
            #expect(ChromePolicy.decide(inputs(fullScreen: true, status: s)).handleIsProminent)
        }
    }
    @Test func handleProminentWhenPermissionPending() {
        #expect(ChromePolicy.decide(inputs(fullScreen: true, permissionPending: true)).handleIsProminent)
    }
    @Test func handleQuietWhenConnected() {
        #expect(!ChromePolicy.decide(inputs(fullScreen: true)).handleIsProminent)
    }
    @Test func hardwareKeyboardHideHidesBar() {
        let d = ChromePolicy.decide(inputs(hardwareKeyboardBar: .hide, hardwareKeyboard: true))
        #expect(d.accessory == .hidden)
    }
    @Test func softwareKeyboardShowsDockedBarEvenWithHide() {
        let d = ChromePolicy.decide(inputs(hardwareKeyboardBar: .hide, hardwareKeyboard: true, softwareKeyboardVisible: true))
        #expect(d.accessory == .docked)
    }
    @Test func showKeepsFloatingBarWithHardwareKeyboard() {
        #expect(ChromePolicy.decide(inputs(hardwareKeyboard: true)).accessory == .floating)
    }
    @Test func floatingPreferenceUnchangedWithoutHardwareKeyboard() {
        #expect(ChromePolicy.decide(inputs(preferFloating: true)).accessory == .floating)
        #expect(ChromePolicy.decide(inputs()).accessory == .docked)
        #expect(ChromePolicy.decide(inputs(hardwareKeyboardBar: .hide)).accessory == .docked)
    }
}
