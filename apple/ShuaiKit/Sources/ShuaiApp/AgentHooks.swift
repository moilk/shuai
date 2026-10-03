public protocol PaneBadgeProvider { @MainActor func badge(host: String, pane: String) -> PaneBadge? }

public enum PaneBadge { case working, needsPermission, needsInput, done, failed, idle }
