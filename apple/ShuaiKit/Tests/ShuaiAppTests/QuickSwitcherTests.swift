import Foundation
import ShuaiCore
import Testing
@testable import ShuaiApp

@Suite struct FuzzyMatcherTests {
    @Test func emptyQueryMatchesEverythingNeutrally() {
        #expect(FuzzyMatcher.score(query: "", in: "anything") == 0)
        #expect(FuzzyMatcher.score(query: "  ", in: "anything") == 0)
    }

    @Test func subsequenceMatchIsCaseInsensitive() {
        #expect(FuzzyMatcher.score(query: "vm", in: "VIM") != nil)
        #expect(FuzzyMatcher.score(query: "mv", in: "VIM") == nil) // order matters
        #expect(FuzzyMatcher.score(query: "xyz", in: "vim") == nil)
        #expect(FuzzyMatcher.score(query: "vimm", in: "vim") == nil) // each char used once
    }

    @Test func prefixBeatsInnerMatch() throws {
        let prefix = try #require(FuzzyMatcher.score(query: "vi", in: "vim"))
        let inner = try #require(FuzzyMatcher.score(query: "vi", in: "devil"))
        #expect(prefix > inner)
    }

    @Test func consecutiveBeatsScattered() throws {
        let tight = try #require(FuzzyMatcher.score(query: "abc", in: "xabcx"))
        let loose = try #require(FuzzyMatcher.score(query: "abc", in: "xaxbxcx"))
        #expect(tight > loose)
    }

    @Test func wordBoundaryBeatsMidWord() throws {
        let boundary = try #require(FuzzyMatcher.score(query: "pw", in: "project-web"))
        let middle = try #require(FuzzyMatcher.score(query: "pw", in: "xxpxxwxx"))
        #expect(boundary > middle)
        let slash = try #require(FuzzyMatcher.score(query: "api", in: "/home/dev/api"))
        let mid = try #require(FuzzyMatcher.score(query: "api", in: "/home/dev/rapid"))
        #expect(slash > mid)
    }

    @Test func shorterCandidateWinsOnEqualMatch() throws {
        let short = try #require(FuzzyMatcher.score(query: "log", in: "log"))
        let long = try #require(FuzzyMatcher.score(query: "log", in: "logging-service-worker"))
        #expect(short > long)
    }

    @Test func unicodeAndCJK() {
        #expect(FuzzyMatcher.score(query: "服务", in: "后端服务器") != nil)
        #expect(FuzzyMatcher.score(query: "é", in: "Café") != nil)
        #expect(FuzzyMatcher.score(query: "cafe", in: "Café") != nil) // diacritics folded
    }

    @Test func matchedIndicesPointAtTheCharacters() throws {
        let m = try #require(FuzzyMatcher.match(query: "vm", in: "vim"))
        #expect(m.indices == [0, 2])
    }
}

@MainActor
@Suite struct QuickSwitcherModelTests {
    let hostA = UUID()
    let hostB = UUID()

    func topology() throws -> FfiTopology {
        try parseTopology(text: Self.panes([
            ("$0", "main", "@1", 0, "editor", "%1", "nvim", "/home/dev/api", true),
            ("$0", "main", "@2", 1, "logs", "%2", "tail", "/var/log", false),
            ("$0", "main", "@2", 1, "logs", "%3", "htop", "/home/dev", false),
            ("$1", "scratch", "@3", 0, "zsh", "%4", "zsh", "/tmp", true),
        ]))
    }

    static func panes(_ rows: [(String, String, String, Int, String, String, String, String, Bool)]) -> String {
        let us = "\u{1f}"
        return rows.map { r in
            [r.0, r.1, "1", r.2, String(r.3), r.4, r.8 ? "1" : "0", "*", r.5, "0", r.8 ? "1" : "0", r.6, r.7, "1", "/dev/pts/1", "t", "80", "24"]
                .joined(separator: us)
        }.joined(separator: "\n") + "\n"
    }

    func items() throws -> [SwitcherItem] {
        SwitcherItem.build(hosts: [
            .init(id: hostA, name: "devbox", connected: true, topology: try topology()),
            .init(id: hostB, name: "offline", connected: false, topology: nil),
        ])
    }

    @Test func itemsCoverHostsSessionsWindowsAndPanes() throws {
        let kinds = try items().map(\.kind)
        #expect(kinds.filter { $0 == .host }.count == 2)
        #expect(kinds.filter { $0 == .session }.count == 2)
        #expect(kinds.filter { $0 == .window }.count == 3)
        #expect(kinds.filter { $0 == .pane }.count == 4)
    }

    @Test func paneItemsCarryCommandCwdAndTargets() throws {
        let pane = try #require(try items().first { $0.kind == .pane && $0.paneID == "%1" })
        #expect(pane.hostID == hostA)
        #expect(pane.sessionID == "$0" && pane.windowID == "@1")
        #expect(pane.searchFields.contains("nvim"))
        #expect(pane.searchFields.contains("/home/dev/api"))
    }

    @Test func queryFiltersAcrossNameCommandAndCwd() throws {
        let model = QuickSwitcherModel(items: try items())
        model.query = "nvim"
        #expect(model.results.first?.paneID == "%1")
        model.query = "var/log"
        #expect(model.results.contains { $0.paneID == "%2" })
        model.query = "scratch"
        #expect(model.results.first?.kind == .session)
        model.query = "zzzz"
        #expect(model.results.isEmpty)
    }

    @Test func allTokensMustMatch() throws {
        let model = QuickSwitcherModel(items: try items())
        model.query = "main logs"
        #expect(model.results.contains { $0.windowID == "@2" })
        #expect(!model.results.contains { $0.windowID == "@3" })
    }

    @Test func emptyQueryListsEverythingOrderedByRecencyThenKind() throws {
        var history = QuickSwitcherHistory()
        let all = try items()
        let logs = try #require(all.first { $0.kind == .window && $0.windowID == "@2" })
        history.record(logs.id, at: Date(timeIntervalSince1970: 100))
        let model = QuickSwitcherModel(items: all, history: history)
        #expect(model.results.count == all.count)
        #expect(model.results.first?.id == logs.id)
    }

    @Test func keyboardNavigationClampsAndWrapsSelection() throws {
        let model = QuickSwitcherModel(items: try items())
        model.query = "a"
        let n = model.results.count
        #expect(n > 2)
        #expect(model.selectedIndex == 0)
        model.moveUp() // wraps to the last
        #expect(model.selectedIndex == n - 1)
        model.moveDown()
        #expect(model.selectedIndex == 0)
        model.moveDown()
        #expect(model.selectedIndex == 1)
    }

    @Test func changingTheQueryResetsTheSelection() throws {
        let model = QuickSwitcherModel(items: try items())
        model.moveDown()
        model.moveDown()
        #expect(model.selectedIndex == 2)
        model.query = "log"
        #expect(model.selectedIndex == 0)
    }

    @Test func activateReturnsTheSelectedItemAndRecordsRecency() throws {
        let model = QuickSwitcherModel(items: try items(), now: { Date(timeIntervalSince1970: 5) })
        model.query = "nvim"
        let picked = try #require(model.activate())
        #expect(picked.paneID == "%1")
        #expect(model.history.lastUsed(picked.id) == Date(timeIntervalSince1970: 5))
        model.query = "zzzz"
        #expect(model.activate() == nil)
    }

    @Test func customRankerCanPutNeedsAttentionFirst() throws {
        struct AttentionFirst: QuickSwitcherRanker {
            let attention: Set<String>
            func rank(_ candidates: [RankedCandidate]) -> [SwitcherItem] {
                candidates.sorted {
                    let a = $0.item.paneID.map(attention.contains) ?? false
                    let b = $1.item.paneID.map(attention.contains) ?? false
                    if a != b { return a }
                    return $0.fuzzyScore > $1.fuzzyScore
                }.map(\.item)
            }
        }
        let model = QuickSwitcherModel(items: try items(), ranker: AttentionFirst(attention: ["%3"]))
        #expect(model.results.first?.paneID == "%3")
        model.query = "dev"
        #expect(model.results.first?.paneID == "%3")
    }

    @Test func rankerSeesBadgesAndFuzzyScoreAndRecency() throws {
        final class Spy: QuickSwitcherRanker, @unchecked Sendable {
            var seen: [RankedCandidate] = []
            func rank(_ candidates: [RankedCandidate]) -> [SwitcherItem] { seen = candidates; return candidates.map(\.item) }
        }
        let spy = Spy()
        let badge = PaneBadge(symbol: "exclamationmark", label: "needs approval", priority: 10)
        struct One: PaneBadgeProvider {
            let badge: PaneBadge
            func badge(host: UUID, pane: String) -> PaneBadge? { pane == "%1" ? badge : nil }
        }
        let model = QuickSwitcherModel(items: try items(), ranker: spy, badges: One(badge: badge))
        model.query = "nvim"
        let c = try #require(spy.seen.first { $0.item.paneID == "%1" })
        #expect(c.badge == badge)
        #expect(c.fuzzyScore > 0)
    }
}

@MainActor
@Suite struct PaneBadgeTests {
    @Test func defaultProviderHasNoBadges() {
        let p = NoPaneBadges()
        #expect(p.badge(host: UUID(), pane: "%1") == nil)
    }

    @Test func windowBadgeIsTheHighestPriorityPaneBadge() {
        struct P: PaneBadgeProvider {
            func badge(host: UUID, pane: String) -> PaneBadge? {
                switch pane {
                case "%1": PaneBadge(symbol: "a", label: "low", priority: 1)
                case "%2": PaneBadge(symbol: "b", label: "high", priority: 5)
                default: nil
                }
            }
        }
        let b = PaneBadge.aggregate(panes: ["%1", "%2", "%3"], host: UUID(), provider: P())
        #expect(b?.label == "high")
        #expect(PaneBadge.aggregate(panes: ["%3"], host: UUID(), provider: P()) == nil)
    }
}
