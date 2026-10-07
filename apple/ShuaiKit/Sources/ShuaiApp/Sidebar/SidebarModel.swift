import Foundation
import ShuaiCore

/// Everything the sidebar needs to know about one host, as plain values (no controllers).
public struct SidebarHostInput: Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var target: String
    public var status: SessionState.Status
    /// The controller's connection state; nil when the host has no controller yet.
    public var session: SessionState?
    /// tmux is enabled for the host and was not found missing.
    public var tmuxEnabled: Bool
    public var monitor: TmuxMonitor.State
    public var topology: FfiTopology?
    public var viewedSessionID: String?
    public var agent: AgentHostStatus
    public var waiting: Int

    public init(
        id: UUID, name: String, target: String, status: SessionState.Status, session: SessionState?, tmuxEnabled: Bool,
        monitor: TmuxMonitor.State, topology: FfiTopology?, viewedSessionID: String?, agent: AgentHostStatus, waiting: Int
    ) {
        self.id = id
        self.name = name
        self.target = target
        self.status = status
        self.session = session
        self.tmuxEnabled = tmuxEnabled
        self.monitor = monitor
        self.topology = topology
        self.viewedSessionID = viewedSessionID
        self.agent = agent
        self.waiting = waiting
    }
}

public struct HostRowModel: Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var target: String
    public var status: SessionState.Status
    public var agent: AgentHostStatus
    public var waiting: Int
    /// The most urgent badge across all panes, shown even while the host is collapsed.
    public var aggregate: PaneBadge?
    public var hasChildren: Bool
    public var isExpanded: Bool
    public var accessibilityLabel: String
    public var accessibilityValue: String
    public var toggleLabel: String
}

public struct SessionRowModel: Equatable, Sendable {
    public var host: UUID
    public var row: TmuxTree.SessionRow
    public var isExpanded: Bool
    public var hasChildren: Bool
    public var accessibilityLabel: String
    public var accessibilityValue: String
    public var name: String { row.name }
    public var badge: PaneBadge? { row.badge }
}

public struct WindowRowModel: Equatable, Sendable {
    public var host: UUID
    public var row: TmuxTree.WindowRow
    /// The active window of the viewed session: the one current location in the tree. Every session
    /// has an active window, so `row.active` alone does not identify it.
    public var isCurrent: Bool
    public var accessibilityLabel: String
    public var accessibilityValue: String
    public var index: Int { row.index }
    public var badge: PaneBadge? { row.badge }
}

public struct PaneRowModel: Equatable, Sendable {
    public var host: UUID
    public var row: TmuxTree.PaneRow
    /// The active pane of the current window (see `WindowRowModel.isCurrent`).
    public var isCurrent: Bool
    public var accessibilityLabel: String
    public var accessibilityValue: String
    public var index: Int { row.index }
    public var badge: PaneBadge? { row.badge }
}

public enum SidebarRow: Identifiable, Equatable, Sendable {
    case host(HostRowModel)
    case loading(UUID)
    case session(SessionRowModel)
    case window(WindowRowModel)
    case pane(PaneRowModel)

    public var id: String {
        switch self {
        case .host(let h): "host:\(h.id.uuidString)"
        case .loading(let h): "loading:\(h.uuidString)"
        case .session(let s): "session:\(s.host.uuidString):\(s.row.id)"
        case .window(let w): "window:\(w.host.uuidString):\(w.row.id)"
        case .pane(let p): "pane:\(p.host.uuidString):\(p.row.id)"
        }
    }

    public var depth: Int {
        switch self {
        case .host: 0
        case .loading, .session: 1
        case .window: 2
        case .pane: 3
        }
    }
}

public enum SidebarModel {
    /// Flat, ordered rows for `hosts`. Hosts and the viewed session are expanded by default, other
    /// sessions collapsed; an agent needing attention never changes expansion.
    @MainActor
    public static func rows(_ hosts: [SidebarHostInput], expansion: SidebarExpansion, badges: any PaneBadgeProvider) -> [SidebarRow] {
        var out: [SidebarRow] = []
        for h in hosts {
            let sessions = h.topology.map {
                TmuxTree.sessions(topology: $0, viewedSessionID: h.viewedSessionID, host: h.id, badges: badges)
            } ?? []
            let loading = h.topology == nil && h.session.map {
                TmuxTree.showsLoadingPlaceholder(session: $0, tmuxEnabled: h.tmuxEnabled, monitor: h.monitor, hasTopology: false)
            } == true
            let hasChildren = !sessions.isEmpty || loading
            let expanded = expansion.isExpanded(.host(h.id), default: true)
            let aggregate = sessions.compactMap(\.badge).max { $0.priority < $1.priority }
            out.append(.host(HostRowModel(
                id: h.id, name: h.name, target: h.target, status: h.status, agent: h.agent, waiting: h.waiting,
                aggregate: aggregate, hasChildren: hasChildren, isExpanded: expanded,
                accessibilityLabel: "\(h.name), \(h.target)",
                accessibilityValue: h.waiting > 0 ? "\(h.status.label), \(h.waiting) waiting for you" : h.status.label,
                toggleLabel: expanded ? "Collapse" : "Expand")))
            guard expanded else { continue }
            if loading { out.append(.loading(h.id)) }
            for s in sessions {
                let open = expansion.isExpanded(.session(host: h.id, name: s.name), default: s.viewed)
                out.append(.session(sessionModel(s, host: h.id, expanded: open)))
                guard open else { continue }
                for w in s.windows {
                    let current = s.viewed && w.active
                    out.append(.window(windowModel(w, host: h.id, current: current)))
                    for p in w.panes { out.append(.pane(paneModel(p, host: h.id, current: current && p.active))) }
                }
            }
        }
        return out
    }

    private static func plural(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }

    private static func join(_ parts: [String?]) -> String { parts.compactMap { $0 }.joined(separator: ", ") }

    private static func sessionModel(_ s: TmuxTree.SessionRow, host: UUID, expanded: Bool) -> SessionRowModel {
        SessionRowModel(
            host: host, row: s, isExpanded: expanded, hasChildren: !s.windows.isEmpty,
            accessibilityLabel: join(["Session \(s.name)", plural(s.windows.count, "window"), s.badge?.label]),
            accessibilityValue: join([s.viewed ? "viewed" : nil, expanded ? nil : "collapsed"]))
    }

    private static func windowModel(_ w: TmuxTree.WindowRow, host: UUID, current: Bool) -> WindowRowModel {
        WindowRowModel(
            host: host, row: w, isCurrent: current,
            accessibilityLabel: join(["\(w.index): \(w.name)", plural(w.paneCount, "pane"), w.zoomed ? "zoomed" : nil, w.badge?.label]),
            accessibilityValue: current ? "active" : "")
    }

    private static func paneModel(_ p: TmuxTree.PaneRow, host: UUID, current: Bool) -> PaneRowModel {
        PaneRowModel(
            host: host, row: p, isCurrent: current, accessibilityLabel: join(["Pane \(p.index): \(p.title)", p.badge?.label]),
            accessibilityValue: current ? "active" : "")
    }
}
