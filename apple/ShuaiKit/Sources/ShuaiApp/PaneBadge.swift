import Foundation

// `PaneBadge` (the agent state of a pane) and `PaneBadgeProvider` are defined in AgentHooks.swift;
// this file adds the presentation/ordering the tmux sidebar and quick switcher need.

extension PaneBadge {
    public enum Tint: String, Sendable { case neutral, info, success, warning, danger }

    /// SF Symbol name.
    public var symbol: String {
        switch self {
        case .working: "gearshape"
        case .needsPermission: "hand.raised"
        case .needsInput: "ellipsis.bubble"
        case .done: "checkmark.circle"
        case .failed: "exclamationmark.triangle"
        case .idle: "moon.zzz"
        }
    }

    /// Short accessibility/tooltip text.
    public var label: String {
        switch self {
        case .working: "working"
        case .needsPermission: "needs approval"
        case .needsInput: "needs input"
        case .done: "done"
        case .failed: "failed"
        case .idle: "idle"
        }
    }

    public var tint: Tint {
        switch self {
        case .working: .info
        case .needsPermission: .warning
        case .needsInput: .warning
        case .done: .success
        case .failed: .danger
        case .idle: .neutral
        }
    }

    /// Higher wins when badges are aggregated (window = max of its panes).
    public var priority: Int {
        switch self {
        case .needsPermission: 5
        case .needsInput: 4
        case .failed: 3
        case .working: 2
        case .done: 1
        case .idle: 0
        }
    }

    /// The user is being waited for: the quick switcher may list these first.
    public var needsAttention: Bool { self == .needsPermission || self == .needsInput }

    /// The badge with the highest priority among `panes` (nil when none has one). `host` is the
    /// provider's host key (what `AgentMonitor.host` is).
    @MainActor
    public static func aggregate(panes: [String], host: String, provider: any PaneBadgeProvider) -> PaneBadge? {
        panes.compactMap { provider.badge(host: host, pane: $0) }.max { $0.priority < $1.priority }
    }
}

/// Default provider: no badges.
public struct NoPaneBadges: PaneBadgeProvider {
    public init() {}
    @MainActor public func badge(host _: String, pane _: String) -> PaneBadge? { nil }
}
