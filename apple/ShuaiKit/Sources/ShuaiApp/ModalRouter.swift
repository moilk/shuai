import Foundation

/// Pages pushed inside the Settings sheet's navigation stack.
public enum SettingsPage: Hashable, Sendable { case root, keys, push }

/// Every modal the app can present. Exactly one is open at a time.
public enum ModalRoute: Hashable, Identifiable, Sendable {
    case newHost
    case editHost(UUID)
    case settings
    /// Keys as a standalone sheet. Inside the editor and Settings it is a pushed page instead.
    case keys
    case quickSwitcher
    case agentInstall(UUID)

    public var id: String {
        switch self {
        case .newHost: "newHost"
        case .editHost(let id): "editHost-\(id.uuidString)"
        case .settings: "settings"
        case .keys: "keys"
        case .quickSwitcher: "quickSwitcher"
        case .agentInstall(let id): "agentInstall-\(id.uuidString)"
        }
    }
}

/// Decides which modal is presented. One `.sheet(item:)` shows `current`, so two sheets never compete
/// for the same presenter. Only the quick switcher is replaceable; any other open modal wins over a
/// later request for a different route.
public struct ModalRouter: Equatable, Sendable {
    public private(set) var current: ModalRoute?

    public enum Outcome: Equatable, Sendable { case presented, replaced, ignored }

    public init() {}

    /// `currentIsDirty`: the open modal holds unsaved input and must not be replaced.
    public mutating func request(_ route: ModalRoute, currentIsDirty: Bool = false) -> Outcome {
        guard let open = current else {
            current = route
            return .presented
        }
        guard open != route, open == .quickSwitcher, !currentIsDirty else { return .ignored }
        current = route
        return .replaced
    }

    /// No-op unless `route` is still the open modal, so a late dismissal never closes its successor.
    public mutating func dismiss(_ route: ModalRoute) {
        if current == route { current = nil }
    }
}
