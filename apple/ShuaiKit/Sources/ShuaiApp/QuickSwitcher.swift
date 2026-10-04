import Foundation
import Observation
import ShuaiCore

/// One jumpable thing in the quick switcher: a host, tmux session, window or pane.
public struct SwitcherItem: Identifiable, Hashable, Sendable {
    public enum Kind: Int, Sendable { case window = 0, pane = 1, session = 2, host = 3 }

    public var id: String
    public var kind: Kind
    public var hostID: UUID
    public var hostName: String
    public var sessionID: String?
    public var windowID: String?
    public var paneID: String?
    public var title: String
    public var subtitle: String
    /// What a query can match directly: the item's own name, command, cwd, title.
    public var searchFields: [String]
    /// Parent names and child commands: they match too, but rank below an own match.
    public var contextFields: [String] = []
    /// Panes below this item (a pane lists itself); used to aggregate badges.
    public var paneIDs: [String]
    public var connected: Bool

    /// A host and what is known of its tmux tree.
    public struct HostSnapshot: Sendable {
        public var id: UUID
        public var name: String
        public var connected: Bool
        public var topology: FfiTopology?
        public init(id: UUID, name: String, connected: Bool, topology: FfiTopology?) {
            self.id = id
            self.name = name
            self.connected = connected
            self.topology = topology
        }
    }

    public static func build(hosts: [HostSnapshot]) -> [SwitcherItem] {
        var out: [SwitcherItem] = []
        for h in hosts {
            let allPanes = h.topology?.sessions.flatMap { $0.windows.flatMap { $0.panes.map(\.id) } } ?? []
            out.append(SwitcherItem(
                id: "host:\(h.id.uuidString)", kind: .host, hostID: h.id, hostName: h.name,
                sessionID: nil, windowID: nil, paneID: nil,
                title: h.name, subtitle: h.connected ? "Connected" : "Not connected",
                searchFields: [h.name], paneIDs: allPanes, connected: h.connected))
            for s in h.topology?.sessions ?? [] {
                out.append(SwitcherItem(
                    id: "session:\(h.id.uuidString):\(s.id)", kind: .session, hostID: h.id, hostName: h.name,
                    sessionID: s.id, windowID: nil, paneID: nil,
                    title: s.name, subtitle: "\(h.name) \u{203A} \(s.windows.count) windows",
                    searchFields: [s.name], contextFields: [h.name],
                    paneIDs: s.windows.flatMap { $0.panes.map(\.id) }, connected: h.connected))
                for w in s.windows {
                    out.append(SwitcherItem(
                        id: "window:\(h.id.uuidString):\(w.id)", kind: .window, hostID: h.id, hostName: h.name,
                        sessionID: s.id, windowID: w.id, paneID: nil,
                        title: "\(w.index): \(w.name)", subtitle: "\(h.name) \u{203A} \(s.name)",
                        searchFields: [w.name], contextFields: [s.name, h.name] + w.panes.map(\.currentCommand),
                        paneIDs: w.panes.map(\.id), connected: h.connected))
                    for p in w.panes {
                        out.append(SwitcherItem(
                            id: "pane:\(h.id.uuidString):\(p.id)", kind: .pane, hostID: h.id, hostName: h.name,
                            sessionID: s.id, windowID: w.id, paneID: p.id,
                            title: "\(p.currentCommand) \u{2014} \(Self.basename(p.currentPath))",
                            subtitle: "\(h.name) \u{203A} \(s.name) \u{203A} \(w.name)",
                            searchFields: [p.currentCommand, p.currentPath, p.title], contextFields: [w.name, s.name, h.name],
                            paneIDs: [p.id], connected: h.connected))
                    }
                }
            }
        }
        return out
    }

    /// Last path component (`/` for the root, `~`-less on purpose: it is a label, not a path).
    static func basename(_ path: String) -> String {
        let trimmed = path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path
        return trimmed.split(separator: "/").last.map(String.init) ?? (path.isEmpty ? "" : "/")
    }
}

/// When each item was last jumped to.
public struct QuickSwitcherHistory: Sendable, Equatable {
    private var used: [String: Date] = [:]
    public init() {}
    public mutating func record(_ id: String, at date: Date) { used[id] = date }
    public func lastUsed(_ id: String) -> Date? { used[id] }
}

/// A matching item with everything a ranker may weigh.
public struct RankedCandidate: Sendable {
    public var item: SwitcherItem
    /// Higher is better; 0 for an empty query.
    public var fuzzyScore: Int
    public var recency: Date?
    /// The (aggregated) badge of the item's panes, e.g. "needs approval" from the agent monitor.
    public var badge: PaneBadge?

    public init(item: SwitcherItem, fuzzyScore: Int, recency: Date?, badge: PaneBadge?) {
        self.item = item
        self.fuzzyScore = fuzzyScore
        self.recency = recency
        self.badge = badge
    }
}

/// Orders the candidates that matched the query. Swap the ranker to change the order (`AttentionRanker`
/// puts items whose badge `needsAttention` first).
public protocol QuickSwitcherRanker: Sendable {
    func rank(_ candidates: [RankedCandidate]) -> [SwitcherItem]
}

/// Fuzzy score, then most recently used, then windows/panes before sessions/hosts, then title.
public struct DefaultQuickSwitcherRanker: QuickSwitcherRanker {
    public init() {}
    public func rank(_ candidates: [RankedCandidate]) -> [SwitcherItem] {
        candidates.sorted { a, b in
            if a.fuzzyScore != b.fuzzyScore { return a.fuzzyScore > b.fuzzyScore }
            switch (a.recency, b.recency) {
            case (let x?, let y?) where x != y: return x > y
            case (_?, nil): return true
            case (nil, _?): return false
            default: break
            }
            if a.item.kind != b.item.kind { return a.item.kind.rawValue < b.item.kind.rawValue }
            return a.item.title.localizedStandardCompare(b.item.title) == .orderedAscending
        }.map(\.item)
    }
}

/// State of the ⌘K sheet: query, ranked results and keyboard selection.
@MainActor @Observable
public final class QuickSwitcherModel {
    public var query = "" {
        didSet {
            guard query != oldValue else { return }
            recompute()
            selectedIndex = 0
        }
    }
    public var items: [SwitcherItem] {
        didSet { recompute() }
    }
    public private(set) var results: [SwitcherItem] = []
    public private(set) var selectedIndex = 0
    public private(set) var history: QuickSwitcherHistory

    @ObservationIgnored private let ranker: any QuickSwitcherRanker
    @ObservationIgnored let badges: any PaneBadgeProvider
    @ObservationIgnored private let now: @Sendable () -> Date

    public init(
        items: [SwitcherItem], ranker: any QuickSwitcherRanker = DefaultQuickSwitcherRanker(),
        badges: any PaneBadgeProvider = NoPaneBadges(), history: QuickSwitcherHistory = QuickSwitcherHistory(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.items = items
        self.ranker = ranker
        self.badges = badges
        self.history = history
        self.now = now
        recompute()
    }

    public var selected: SwitcherItem? {
        results.indices.contains(selectedIndex) ? results[selectedIndex] : nil
    }

    public func moveDown() {
        guard !results.isEmpty else { return }
        selectedIndex = (selectedIndex + 1) % results.count
    }

    public func moveUp() {
        guard !results.isEmpty else { return }
        selectedIndex = (selectedIndex - 1 + results.count) % results.count
    }

    /// Picks the selected item (nil when there is none) and remembers it.
    @discardableResult
    public func activate() -> SwitcherItem? {
        guard let item = selected else { return nil }
        history.record(item.id, at: now())
        return item
    }

    private func recompute() {
        let tokens = query.split(whereSeparator: \.isWhitespace).map(String.init)
        var candidates: [RankedCandidate] = []
        for item in items {
            guard let score = Self.score(tokens: tokens, item: item) else { continue }
            candidates.append(RankedCandidate(
                item: item, fuzzyScore: score, recency: history.lastUsed(item.id),
                badge: PaneBadge.aggregate(panes: item.paneIDs, host: item.hostID.uuidString, provider: badges)))
        }
        results = ranker.rank(candidates)
        if selectedIndex >= results.count { selectedIndex = 0 }
    }

    private static let contextPenalty = 25

    /// Every token must match some field; the score is the sum of each token's best field.
    private static func score(tokens: [String], item: SwitcherItem) -> Int? {
        if tokens.isEmpty { return 0 }
        var total = 0
        for t in tokens {
            let own = item.searchFields.compactMap { FuzzyMatcher.score(query: t, in: $0) }.max()
            let inherited = item.contextFields.compactMap { FuzzyMatcher.score(query: t, in: $0) }
                .max().map { max(1, $0 - contextPenalty) }
            guard let best = [own, inherited].compactMap({ $0 }).max() else { return nil }
            total += best
        }
        return total
    }
}
