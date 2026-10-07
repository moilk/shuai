import Foundation
import Observation
import ShuaiTerminal

/// User preferences (UserDefaults-backed).
@MainActor @Observable
public final class AppSettings {
    public enum Theme: String, CaseIterable, Identifiable, Sendable {
        case dark, light
        public var id: String { rawValue }
        public var terminalTheme: TerminalTheme { self == .dark ? .claudeDark : .claudeLight }
    }

    public enum AccessoryBarStyle: String, CaseIterable, Identifiable, Sendable {
        case docked, floating
        public var id: String { rawValue }
    }

    public var theme: Theme { didSet { defaults.set(theme.rawValue, forKey: "theme") } }
    public var fontSize: Int {
        didSet {
            let clamped = min(max(fontSize, FontSizeModel.range.lowerBound), FontSizeModel.range.upperBound)
            if clamped != fontSize { fontSize = clamped; return }
            defaults.set(fontSize, forKey: "fontSize")
        }
    }
    public var accessoryBar: AccessoryBarStyle { didSet { defaults.set(accessoryBar.rawValue, forKey: "accessoryBar") } }
    public var tabStrip: TabStripMode { didSet { defaults.set(tabStrip.rawValue, forKey: "tabStrip") } }
    public var hardwareKeyboardBar: HardwareKeyboardBar {
        didSet { defaults.set(hardwareKeyboardBar.rawValue, forKey: "hardwareKeyboardBar") }
    }
    public var fullScreen: Bool { didSet { defaults.set(fullScreen, forKey: "fullScreen") } }
    public var optionAsAlt: Bool { didSet { defaults.set(optionAsAlt, forKey: "optionAsAlt") } }

    /// Post a local notification when an agent wants you while the app is not active (best effort).
    public var notificationsEnabled: Bool { didSet { defaults.set(notificationsEnabled, forKey: "notificationsEnabled") } }
    /// The one-time explanation before the system notification prompt was shown.
    public var notificationsExplained: Bool { didSet { defaults.set(notificationsExplained, forKey: "notificationsExplained") } }

    @ObservationIgnored private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        theme = defaults.string(forKey: "theme").flatMap(Theme.init) ?? .dark
        let size = defaults.object(forKey: "fontSize") as? Int ?? FontSizeModel.defaultSize
        fontSize = min(max(size, FontSizeModel.range.lowerBound), FontSizeModel.range.upperBound)
        accessoryBar = defaults.string(forKey: "accessoryBar").flatMap(AccessoryBarStyle.init) ?? .docked
        tabStrip = defaults.string(forKey: "tabStrip").flatMap(TabStripMode.init) ?? .automatic
        hardwareKeyboardBar = defaults.string(forKey: "hardwareKeyboardBar").flatMap(HardwareKeyboardBar.init) ?? .show
        fullScreen = defaults.object(forKey: "fullScreen") as? Bool ?? false
        optionAsAlt = defaults.object(forKey: "optionAsAlt") as? Bool ?? true
        notificationsEnabled = defaults.object(forKey: "notificationsEnabled") as? Bool ?? false
        notificationsExplained = defaults.object(forKey: "notificationsExplained") as? Bool ?? false
    }
}
