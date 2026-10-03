import Foundation
import Testing
import ShuaiCore
@testable import ShuaiApp

@Suite("AttentionRanker")
struct AttentionRankerTests {
    private func item(_ id: String, kind: SwitcherItem.Kind = .window, title: String = "t") -> SwitcherItem {
        SwitcherItem(
            id: id, kind: kind, hostID: UUID(), hostName: "h", sessionID: nil, windowID: nil, paneID: nil,
            title: title, subtitle: "", searchFields: [title], paneIDs: [], connected: true)
    }

    private func cand(_ id: String, _ badge: PaneBadge?, fuzzy: Int = 0, recency: Date? = nil, kind: SwitcherItem.Kind = .window)
        -> RankedCandidate
    {
        RankedCandidate(item: item(id, kind: kind, title: id), fuzzyScore: fuzzy, recency: recency, badge: badge)
    }

    @Test func permissionBeforeInputBeforeFailedBeforeUnseenDoneBeforeTheRest() {
        let out = AttentionRanker().rank([
            cand("working", .working), cand("none", nil), cand("done", .done), cand("failed", .failed),
            cand("idle", .idle), cand("input", .needsInput), cand("perm", .needsPermission),
        ]).map(\.id)
        #expect(Array(out.prefix(4)) == ["perm", "input", "failed", "done"])
        #expect(Set(out.suffix(3)) == ["working", "none", "idle"])
    }

    @Test func withinATierWindowsBeatSessionsThenFuzzyThenRecency() {
        let now = Date()
        let out = AttentionRanker().rank([
            cand("session", .needsInput, kind: .session),
            cand("old", .needsInput, recency: now.addingTimeInterval(-100)),
            cand("recent", .needsInput, recency: now),
            cand("best", .needsInput, fuzzy: 50),
        ]).map(\.id)
        #expect(out == ["best", "recent", "old", "session"])
    }

    @Test func nonAttentionItemsKeepTheDefaultOrder() {
        let cands = [cand("b", .working, fuzzy: 1), cand("a", nil, fuzzy: 9), cand("c", .idle, fuzzy: 1)]
        #expect(AttentionRanker().rank(cands).map(\.id) == DefaultQuickSwitcherRanker().rank(cands).map(\.id))
    }
}

@MainActor
@Suite("Quick switcher agent rows")
struct QuickSwitcherAgentRowTests {
    struct Provider: PaneAgentInfoProvider {
        var infos: [String: PaneAgentInfo]
        func badge(host _: String, pane: String) -> PaneBadge? { infos[pane]?.badge }
        func agentInfo(host _: String, pane: String) -> PaneAgentInfo? { infos[pane] }
    }

    @Test func rowDetailIsTheMostUrgentPanesStateAndSnippet() {
        let host = UUID()
        let w = SwitcherItem(
            id: "w", kind: .window, hostID: host, hostName: "h", sessionID: "$0", windowID: "@0", paneID: nil,
            title: "1: claude", subtitle: "", searchFields: ["claude"], paneIDs: ["%0", "%1"], connected: true)
        let provider = Provider(infos: [
            "%0": PaneAgentInfo(badge: .working, snippet: "building the thing"),
            "%1": PaneAgentInfo(badge: .needsPermission, snippet: "run rm -rf build?"),
        ])
        let q = QuickSwitcherModel(items: [w], ranker: AttentionRanker(), badges: provider)
        let d = q.agentDetail(for: w)
        #expect(d?.badge == .needsPermission)
        #expect(d?.snippet == "run rm -rf build?")
    }

    @Test func noProviderInfoMeansNoDetail() {
        let w = SwitcherItem(
            id: "w", kind: .window, hostID: UUID(), hostName: "h", sessionID: nil, windowID: nil, paneID: nil,
            title: "x", subtitle: "", searchFields: ["x"], paneIDs: ["%0"], connected: true)
        let q = QuickSwitcherModel(items: [w])
        #expect(q.agentDetail(for: w) == nil)
    }

    @Test func snippetsAreSingleLineAndTrimmed() {
        #expect(PaneAgentInfo.snippet(prompt: "  fix\nthe  bug \n", message: nil, limit: 80) == "fix the bug")
        #expect(PaneAgentInfo.snippet(prompt: "p", message: "the reply", limit: 80) == "the reply")
        #expect(PaneAgentInfo.snippet(prompt: nil, message: nil, limit: 80) == nil)
        let long = String(repeating: "x", count: 200)
        #expect(PaneAgentInfo.snippet(prompt: long, message: nil, limit: 20)?.count == 20)
        #expect(PaneAgentInfo.snippet(prompt: long, message: nil, limit: 20)?.hasSuffix("\u{2026}") == true)
    }
}
