import Foundation

/// Whether tmux commands can run for the selected host (`TmuxMonitor.State` reduced to what menus need).
public enum TmuxMenuAvailability: Equatable, Sendable {
    case available, unavailable

    /// Mirrors `AppModel.handleShortcut`: only a live or polling monitor runs tmux commands.
    public init(_ state: TmuxMonitor.State) {
        switch state {
        case .live, .polling: self = .available
        case .idle, .starting, .unavailable, .ended, .stopped: self = .unavailable
        }
    }
}

/// One entry of the menu bar's tmux menu. `id` is the `ShortcutAction.id` handed to `handleShortcut`.
public struct TmuxMenuItem: Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    /// The chord bound to the action, for display; nil when the action is unbound.
    public let chord: KeyChord?
    public let enabled: Bool
}

/// The tmux menu, derived from the shortcut map so menu and key commands share one source.
public enum TmuxMenuState {
    /// Menu actions in display order (window navigation, panes, then direct window positions).
    public static let actions: [ShortcutAction] =
        [.newWindow, .killWindow, .previousWindow, .nextWindow, .splitRight, .splitDown, .zoomPane]
            + (1 ... 9).map { ShortcutAction.selectWindow(position: $0) }

    public static func items(shortcuts: ShortcutMap, availability: TmuxMenuAvailability) -> [TmuxMenuItem] {
        actions.map {
            TmuxMenuItem(
                id: $0.id, title: $0.title, chord: shortcuts.chord(for: $0), enabled: availability == .available)
        }
    }
}
