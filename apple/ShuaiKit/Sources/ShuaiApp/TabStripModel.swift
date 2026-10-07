import Foundation
import ShuaiCore

/// What the window tab strip shows: the viewed session's windows as tabs and the host's sessions
/// for the session menu. Pure view model; the views own the tmux actions.
@MainActor
public struct TabStripModel {
    public struct Tab: Identifiable, Equatable, Sendable {
        public var row: TmuxTree.WindowRow
        public var id: String { row.id }
        /// `<index>: <name>[, zoomed][, <badge>]`: state is spoken, never colour-only.
        public var label: String {
            var parts = [row.title]
            if row.zoomed { parts.append("zoomed") }
            if let badge = row.badge { parts.append(badge.label) }
            return parts.joined(separator: ", ")
        }
        /// Exactly `active` or empty (UI tests and VoiceOver rely on it).
        public var value: String { row.active ? "active" : "" }
    }

    public struct SessionEntry: Identifiable, Equatable, Sendable {
        public var id: String
        public var name: String
        public var isViewed: Bool
        public var badge: PaneBadge?
    }

    public let tabs: [Tab]
    public let sessions: [SessionEntry]
    public let viewedSessionID: String?
    public let viewedSessionName: String?

    public init(topology: FfiTopology, viewedSessionID: String?, host: UUID, badges: any PaneBadgeProvider) {
        let viewed = viewedSessionID.flatMap { id in topology.sessions.first { $0.id == id } }
        self.viewedSessionID = viewed?.id
        viewedSessionName = viewed?.name
        tabs = viewed.map { TmuxTree.windowRows(of: $0, host: host, badges: badges).map(Tab.init) } ?? []
        sessions = TmuxTree.sessions(topology: topology, viewedSessionID: viewed?.id, host: host, badges: badges)
            .map { SessionEntry(id: $0.id, name: $0.name, isViewed: $0.viewed, badge: $0.badge) }
    }
}
