public protocol PaneBadgeProvider { @MainActor func badge(host: String, pane: String) -> PaneBadge? }

public enum PaneBadge: Sendable, Hashable { case working, needsPermission, needsInput, done, failed, idle }
