import Foundation
import ShuaiTerminal

/// Window tab strip visibility preference.
public enum TabStripMode: String, CaseIterable, Sendable {
    /// Hidden only when the viewed session has one window and the host has one session.
    case automatic
    case always
}

/// What the accessory bar does while a hardware keyboard is the only keyboard.
public enum HardwareKeyboardBar: String, CaseIterable, Sendable {
    case show, hide
}

public struct ChromeInputs: Equatable, Sendable {
    public var hasTopology: Bool
    public var windowCount: Int
    public var sessionCount: Int
    public var sidebarCollapsed: Bool
    public var fullScreen: Bool
    public var tabStrip: TabStripMode
    public var preferFloatingBar: Bool
    public var hardwareKeyboardBar: HardwareKeyboardBar
    public var hardwareKeyboard: Bool
    public var softwareKeyboardVisible: Bool
    public var status: SessionState.Status
    public var permissionPendingForHost: Bool

    public init(
        hasTopology: Bool, windowCount: Int, sessionCount: Int,
        sidebarCollapsed: Bool, fullScreen: Bool,
        tabStrip: TabStripMode, preferFloatingBar: Bool, hardwareKeyboardBar: HardwareKeyboardBar,
        hardwareKeyboard: Bool, softwareKeyboardVisible: Bool,
        status: SessionState.Status, permissionPendingForHost: Bool
    ) {
        self.hasTopology = hasTopology
        self.windowCount = windowCount
        self.sessionCount = sessionCount
        self.sidebarCollapsed = sidebarCollapsed
        self.fullScreen = fullScreen
        self.tabStrip = tabStrip
        self.preferFloatingBar = preferFloatingBar
        self.hardwareKeyboardBar = hardwareKeyboardBar
        self.hardwareKeyboard = hardwareKeyboard
        self.softwareKeyboardVisible = softwareKeyboardVisible
        self.status = status
        self.permissionPendingForHost = permissionPendingForHost
    }
}

public enum AccessoryChoice: Equatable, Sendable { case docked, floating, hidden }

public struct ChromeDecision: Equatable, Sendable {
    public var showsTabStrip: Bool
    public var showsNavigationBar: Bool
    public var hidesStatusBar: Bool
    public var hidesHomeIndicator: Bool
    public var showsHandle: Bool
    public var handleIsProminent: Bool
    public var accessory: AccessoryChoice
}

/// Which chrome is visible around the terminal. Pure: views feed the inputs and apply the result.
public enum ChromePolicy {
    public static func decide(_ i: ChromeInputs) -> ChromeDecision {
        let needsStrip = i.tabStrip == .always || i.windowCount > 1 || i.sessionCount > 1
        let showsStrip = i.hasTopology && (i.sidebarCollapsed || i.fullScreen) && needsStrip

        // The bar hides only for a hardware keyboard with no software keyboard up (the bar is then
        // the only thing that would be drawn); a software keyboard always keeps its docked bar.
        let accessory: AccessoryChoice
        if i.hardwareKeyboardBar == .hide && i.hardwareKeyboard && !i.softwareKeyboardVisible {
            accessory = .hidden
        } else {
            switch AccessoryBarPlacement.decide(
                hardwareKeyboard: i.hardwareKeyboard, preferFloating: i.preferFloatingBar,
                softwareKeyboardVisible: i.softwareKeyboardVisible
            ) {
            case .docked: accessory = .docked
            case .floating: accessory = .floating
            }
        }

        return ChromeDecision(
            showsTabStrip: showsStrip,
            showsNavigationBar: !i.fullScreen,
            hidesStatusBar: i.fullScreen,
            hidesHomeIndicator: i.fullScreen,
            showsHandle: i.fullScreen,
            handleIsProminent: i.status != .connected || i.permissionPendingForHost,
            accessory: accessory)
    }
}
