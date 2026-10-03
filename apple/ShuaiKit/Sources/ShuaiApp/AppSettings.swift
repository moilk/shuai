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
    public var optionAsAlt: Bool { didSet { defaults.set(optionAsAlt, forKey: "optionAsAlt") } }

    @ObservationIgnored private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        theme = defaults.string(forKey: "theme").flatMap(Theme.init) ?? .dark
        let size = defaults.object(forKey: "fontSize") as? Int ?? FontSizeModel.defaultSize
        fontSize = min(max(size, FontSizeModel.range.lowerBound), FontSizeModel.range.upperBound)
        accessoryBar = defaults.string(forKey: "accessoryBar").flatMap(AccessoryBarStyle.init) ?? .docked
        optionAsAlt = defaults.object(forKey: "optionAsAlt") as? Bool ?? true
    }
}
