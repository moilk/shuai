import Foundation
import ShuaiCore

/// Sidebar / tab strip rows derived from a topology. Pure view models: no tmux I/O.
public enum TmuxTree {
    public struct PaneRow: Identifiable, Equatable, Sendable {
        public var id: String
        public var index: Int
        public var title: String
        public var active: Bool
        public var badge: PaneBadge?
    }

    public struct WindowRow: Identifiable, Equatable, Sendable {
        public var id: String
        public var index: Int
        public var name: String
        public var title: String
        public var active: Bool
        public var zoomed: Bool
        public var paneCount: Int
        /// The pane keystrokes go to (split/zoom of this window act on it).
        public var activePaneID: String?
        /// Only filled when the window has more than one pane.
        public var panes: [PaneRow]
        public var badge: PaneBadge?
    }

    public struct SessionRow: Identifiable, Equatable, Sendable {
        public var id: String
        public var name: String
        /// The terminal currently shows this session.
        public var viewed: Bool
        public var windows: [WindowRow]
        public var badge: PaneBadge?
    }

    /// A lightweight "loading" row instead of an empty gap while a connected host's tmux tree has
    /// not arrived yet (control channel attaching, first `list-panes` in flight). An existing tree
    /// is kept while the monitor restarts, and an unusable tmux shows nothing.
    public static func showsLoadingPlaceholder(
        session: SessionState, tmuxEnabled: Bool, monitor: TmuxMonitor.State, hasTopology: Bool
    ) -> Bool {
        guard tmuxEnabled, !hasTopology, session == .connected else { return false }
        switch monitor {
        case .idle, .starting, .live, .polling: return true
        case .unavailable, .ended, .stopped: return false
        }
    }

    @MainActor
    public static func sessions(
        topology: FfiTopology, viewedSessionID: String?, host: UUID, badges: any PaneBadgeProvider
    ) -> [SessionRow] {
        topology.sessions.map { s in
            let rows = windowRows(of: s, host: host, badges: badges)
            let allPanes = s.windows.flatMap { $0.panes.map(\.id) }
            return SessionRow(
                id: s.id, name: s.name, viewed: s.id == viewedSessionID, windows: rows,
                badge: PaneBadge.aggregate(panes: allPanes, host: host.uuidString, provider: badges))
        }
    }

    /// The windows of `session` in tmux order (also what the tab strip shows).
    @MainActor
    public static func windowRows(of session: FfiTmuxSession, host: UUID, badges: any PaneBadgeProvider) -> [WindowRow] {
        session.windows.sorted { $0.index < $1.index }.map { w in
            let paneIDs = w.panes.map(\.id)
            let panes: [PaneRow] = w.panes.count > 1
                ? w.panes.sorted { $0.index < $1.index }.map { p in
                    PaneRow(
                        id: p.id, index: Int(p.index),
                        title: "\(p.currentCommand) \u{2014} \(SwitcherItem.basename(p.currentPath))", active: p.active,
                        badge: badges.badge(host: host.uuidString, pane: p.id))
                }
                : []
            return WindowRow(
                id: w.id, index: Int(w.index), name: w.name, title: "\(w.index): \(w.name)", active: w.active,
                zoomed: w.flags.contains("Z"), paneCount: w.panes.count,
                activePaneID: (w.panes.first(where: \.active) ?? w.panes.first)?.id, panes: panes,
                badge: PaneBadge.aggregate(panes: paneIDs, host: host.uuidString, provider: badges))
        }
    }
}
