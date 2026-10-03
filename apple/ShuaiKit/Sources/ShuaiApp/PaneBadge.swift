import Foundation

/// A small status marker shown next to a pane/window/session row in the sidebar and in the
/// quick switcher. Producers (M5's agent monitor) decide the content; the tmux UI only renders
/// it and sorts by `priority`.
public struct PaneBadge: Equatable, Hashable, Sendable {
    public enum Tint: String, Sendable { case neutral, info, success, warning, danger }

    /// SF Symbol name.
    public var symbol: String
    /// Short accessibility/tooltip text ("needs approval").
    public var label: String
    public var tint: Tint
    /// Higher wins when badges are aggregated (window = max of its panes).
    public var priority: Int
    /// The user is being waited for: the quick switcher may list these first.
    public var needsAttention: Bool

    public init(symbol: String, label: String, tint: Tint = .neutral, priority: Int = 0, needsAttention: Bool = false) {
        self.symbol = symbol
        self.label = label
        self.tint = tint
        self.priority = priority
        self.needsAttention = needsAttention
    }

    /// The badge with the highest priority among `panes` (nil when none has one).
    @MainActor
    public static func aggregate(panes: [String], host: UUID, provider: any PaneBadgeProvider) -> PaneBadge? {
        panes.compactMap { provider.badge(host: host, pane: $0) }.max { $0.priority < $1.priority }
    }
}

/// Hook for per-pane badges. The default is `NoPaneBadges`; the agent monitor (M5) supplies
/// its own implementation (`@Observable` state read inside `badge` is tracked by SwiftUI).
@MainActor
public protocol PaneBadgeProvider {
    /// `host` is `HostProfile.id`, `pane` a tmux pane id (`%3`).
    func badge(host: UUID, pane: String) -> PaneBadge?
}

public struct NoPaneBadges: PaneBadgeProvider {
    public init() {}
    public func badge(host _: UUID, pane _: String) -> PaneBadge? { nil }
}
