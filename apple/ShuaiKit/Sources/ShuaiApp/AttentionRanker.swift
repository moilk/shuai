import Foundation

/// What a pane's agent is doing, for rows that show more than a dot.
public struct PaneAgentInfo: Equatable, Sendable {
    public var badge: PaneBadge
    /// One line: the agent's last message, else the last prompt.
    public var snippet: String?

    public init(badge: PaneBadge, snippet: String?) {
        self.badge = badge
        self.snippet = snippet
    }

    /// Single-line, whitespace-collapsed text of the agent's last message (preferred) or prompt,
    /// cut to `limit` characters (with an ellipsis).
    public static func snippet(prompt: String?, message: String?, limit: Int = 90) -> String? {
        for raw in [message, prompt] {
            guard let raw else { continue }
            let line = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard !line.isEmpty else { continue }
            return line.count > limit ? String(line.prefix(max(0, limit - 1))) + "\u{2026}" : line
        }
        return nil
    }
}

/// A badge provider that also knows what the agent said (the hub).
public protocol PaneAgentInfoProvider: PaneBadgeProvider {
    @MainActor func agentInfo(host: String, pane: String) -> PaneAgentInfo?
}

/// ⌘K order for agent-aware use: sessions that want you come first - needs permission, then
/// needs input, then failed, then done-and-unseen (the tracker reports seen `Done` as idle) -
/// and everything else keeps the default order. Inside a tier: fuzzy score, windows/panes before
/// sessions/hosts, then recency, then title.
public struct AttentionRanker: QuickSwitcherRanker {
    private let fallback = DefaultQuickSwitcherRanker()
    public init() {}

    static func tier(_ badge: PaneBadge?) -> Int? {
        switch badge {
        case .needsPermission?: 0
        case .needsInput?: 1
        case .failed?: 2
        case .done?: 3
        default: nil
        }
    }

    public func rank(_ candidates: [RankedCandidate]) -> [SwitcherItem] {
        let tiered = candidates.filter { Self.tier($0.badge) != nil }
        let rest = candidates.filter { Self.tier($0.badge) == nil }
        let ordered = tiered.sorted { a, b in
            let (ta, tb) = (Self.tier(a.badge)!, Self.tier(b.badge)!)
            if ta != tb { return ta < tb }
            if a.fuzzyScore != b.fuzzyScore { return a.fuzzyScore > b.fuzzyScore }
            if a.item.kind != b.item.kind { return a.item.kind.rawValue < b.item.kind.rawValue }
            switch (a.recency, b.recency) {
            case (let x?, let y?) where x != y: return x > y
            case (_?, nil): return true
            case (nil, _?): return false
            default: break
            }
            return a.item.title.localizedStandardCompare(b.item.title) == .orderedAscending
        }
        return ordered.map(\.item) + fallback.rank(rest)
    }
}

extension QuickSwitcherModel {
    /// The agent state to show in `item`'s row: its most urgent pane's.
    public func agentDetail(for item: SwitcherItem) -> PaneAgentInfo? {
        guard let provider = badges as? any PaneAgentInfoProvider else { return nil }
        return item.paneIDs.compactMap { provider.agentInfo(host: item.hostID.uuidString, pane: $0) }
            .max { $0.badge.priority < $1.badge.priority }
    }
}
