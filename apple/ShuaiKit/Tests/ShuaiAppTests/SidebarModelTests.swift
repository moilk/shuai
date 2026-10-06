import Foundation
import ShuaiCore
import Testing
@testable import ShuaiApp

@MainActor
@Suite struct SidebarModelTests {
    let hostID = UUID()

    func pane(_ id: String, _ i: UInt32, active: Bool, cmd: String = "zsh", path: String = "/home/dev/app") -> FfiTmuxPane {
        FfiTmuxPane(id: id, index: i, active: active, currentCommand: cmd, currentPath: path, pid: 1, tty: "/dev/x", title: "", width: 80, height: 24)
    }

    func topology(mainID: String = "$0") -> FfiTopology {
        let w0 = FfiTmuxWindow(id: "@0", index: 1, name: "shell", active: false, flags: "-", panes: [pane("%0", 0, active: true)])
        let w1 = FfiTmuxWindow(id: "@1", index: 2, name: "claude", active: true, flags: "*Z", panes: [
            pane("%1", 0, active: false, cmd: "claude", path: "/srv/api"), pane("%2", 1, active: true, cmd: "vim"),
        ])
        let main = FfiTmuxSession(id: mainID, name: "main", attached: 1, windows: [w1, w0])
        let work = FfiTmuxSession(id: "$1", name: "work", attached: 0, windows: [
            FfiTmuxWindow(id: "@5", index: 0, name: "edit", active: true, flags: "*", panes: [pane("%5", 0, active: true)]),
        ])
        return FfiTopology(sessions: [main, work])
    }

    func input(
        topology: FfiTopology? = nil, session: SessionState? = .connected, monitor: TmuxMonitor.State = .live,
        viewed: String? = "$0", waiting: Int = 0, tmuxEnabled: Bool = true
    ) -> SidebarHostInput {
        SidebarHostInput(
            id: hostID, name: "dev", target: "me@example.test", status: session?.status ?? .off, session: session,
            tmuxEnabled: tmuxEnabled, monitor: monitor, topology: topology, viewedSessionID: viewed,
            agent: .unknown, waiting: waiting)
    }

    struct Badges: PaneBadgeProvider {
        var map: [String: PaneBadge]
        func badge(host _: String, pane: String) -> PaneBadge? { map[pane] }
    }

    func rows(_ i: SidebarHostInput, _ e: SidebarExpansion = SidebarExpansion(), badges: any PaneBadgeProvider = NoPaneBadges()) -> [SidebarRow] {
        SidebarModel.rows([i], expansion: e, badges: badges)
    }

    func kinds(_ r: [SidebarRow]) -> [String] {
        r.map {
            switch $0 {
            case .host: "host"
            case .loading: "loading"
            case .session(let s): "session:\(s.name)"
            case .window(let w): "window:\(w.index)"
            case .pane(let p): "pane:\(p.index)"
            }
        }
    }

    @Test func hostWithoutTopologyHasNoChildren() {
        let r = rows(input(session: .idle, monitor: .idle))
        #expect(kinds(r) == ["host"])
        guard case .host(let h) = r[0] else { Issue.record("not a host"); return }
        #expect(!h.hasChildren)
        #expect(h.aggregate == nil)
    }

    @Test func loadingRowWhileTreeArrives() {
        let r = rows(input(monitor: .starting))
        #expect(kinds(r) == ["host", "loading"])
        #expect(r[1].depth == 1)
        let off = rows(input(monitor: .unavailable("x")))
        #expect(kinds(off) == ["host"])
    }

    @Test func viewedSessionExpandedOthersCollapsedByDefault() {
        let r = rows(input(topology: topology()))
        #expect(kinds(r) == ["host", "session:main", "window:1", "window:2", "pane:0", "pane:1", "session:work"])
        #expect(r.map(\.depth) == [0, 1, 2, 2, 3, 3, 1])
        guard case .session(let work) = r[6] else { Issue.record("not a session"); return }
        #expect(!work.isExpanded)
        #expect(work.hasChildren)
    }

    @Test func collapsingHostHidesTree() {
        var e = SidebarExpansion()
        e.toggle(.host(hostID), default: true)
        let r = rows(input(topology: topology()), e)
        #expect(kinds(r) == ["host"])
        guard case .host(let h) = r[0] else { Issue.record("not a host"); return }
        #expect(h.hasChildren)
        #expect(!h.isExpanded)
        #expect(h.toggleLabel == "Expand")
    }

    @Test func toggleBackToDefaultDropsOverride() {
        var e = SidebarExpansion()
        let k = SidebarExpansion.Key.host(hostID)
        e.toggle(k, default: true)
        #expect(e.overrides[k] == false)
        #expect(!e.isExpanded(k, default: true))
        e.toggle(k, default: true)
        #expect(e.overrides.isEmpty)
        #expect(e.isExpanded(k, default: true))
    }

    @Test func keyUsesSessionNameNotTmuxID() {
        var e = SidebarExpansion()
        // expand the (non-viewed) "work" session
        e.toggle(.session(host: hostID, name: "work"), default: false)
        let before = rows(input(topology: topology(), viewed: "$0"), e)
        #expect(kinds(before).contains("window:0"))
        // a restarted server hands "main" a new id: the collapsed override still applies by name
        var e2 = SidebarExpansion()
        e2.toggle(.session(host: hostID, name: "main"), default: true) // collapse main
        let after = rows(input(topology: topology(mainID: "$7"), viewed: "$1"), e2)
        #expect(kinds(after) == ["host", "session:main", "session:work", "window:0"])
    }

    @Test func forgetHostRemovesItsKeys() {
        let other = UUID()
        var e = SidebarExpansion()
        e.toggle(.host(hostID), default: true)
        e.toggle(.session(host: hostID, name: "a"), default: false)
        e.toggle(.host(other), default: true)
        e.forget(host: hostID)
        #expect(e.overrides.keys.contains(.host(other)))
        #expect(e.overrides.count == 1)
    }

    @Test func pruneKeepsOnlyKnownHosts() {
        let other = UUID()
        var e = SidebarExpansion()
        e.toggle(.host(hostID), default: true)
        e.toggle(.session(host: other, name: "a"), default: false)
        e.prune(keeping: [hostID])
        #expect(Set(e.overrides.keys) == [.host(hostID)])
    }

    @Test func overridesAreCapped() {
        var e = SidebarExpansion()
        for i in 0..<(SidebarExpansion.maxEntries + 10) {
            e.toggle(.session(host: hostID, name: "s\(i)"), default: false)
        }
        #expect(e.overrides.count == SidebarExpansion.maxEntries)
        #expect(e.overrides[.session(host: hostID, name: "s0")] == nil)
        #expect(e.overrides[.session(host: hostID, name: "s\(SidebarExpansion.maxEntries + 9)")] == true)
    }

    @Test func hostAggregateIsHighestPaneBadge() {
        let b = Badges(map: ["%0": .working, "%5": .needsPermission, "%2": .done])
        let r = rows(input(topology: topology()), badges: b)
        guard case .host(let h) = r[0] else { Issue.record("not a host"); return }
        #expect(h.aggregate == .needsPermission)
    }

    @Test func collapsedSessionKeepsAttentionBadge() {
        let b = Badges(map: ["%5": .needsInput])
        let r = rows(input(topology: topology()), badges: b)
        guard case .session(let work) = r.last else { Issue.record("not a session"); return }
        #expect(!work.isExpanded)
        #expect(work.badge == .needsInput)
        #expect(work.accessibilityLabel.hasSuffix("needs input"))
    }

    @Test func windowValueIsExactlyActive() {
        let r = rows(input(topology: topology()))
        guard case .window(let w1) = r[2], case .window(let w2) = r[3] else { Issue.record("not windows"); return }
        #expect(w1.accessibilityValue == "")
        #expect(w2.accessibilityValue == "active")
    }

    @Test func labelsNameEveryState() {
        let b = Badges(map: ["%1": .needsPermission])
        let r = rows(input(topology: topology(), waiting: 2), badges: b)
        guard case .host(let h) = r[0], case .session(let s) = r[1], case .window(let w0) = r[2],
            case .window(let w1) = r[3], case .pane(let p0) = r[4], case .pane(let p1) = r[5],
            case .session(let work) = r[6]
        else { Issue.record("shape"); return }
        #expect(h.accessibilityLabel == "dev, me@example.test")
        #expect(h.accessibilityValue == "Connected, 2 waiting for you")
        #expect(h.toggleLabel == "Collapse")
        #expect(s.accessibilityLabel == "Session main, 2 windows, needs approval")
        #expect(s.accessibilityValue == "viewed")
        #expect(work.accessibilityLabel == "Session work, 1 window")
        #expect(work.accessibilityValue == "collapsed")
        #expect(w0.accessibilityLabel == "1: shell, 1 pane")
        #expect(w1.accessibilityLabel == "2: claude, 2 panes, zoomed, needs approval")
        #expect(p0.accessibilityLabel == "Pane 0: claude \u{2014} api, needs approval")
        #expect(p0.accessibilityValue == "")
        #expect(p1.accessibilityLabel == "Pane 1: vim \u{2014} app")
        #expect(p1.accessibilityValue == "active")
    }

    @Test func rowIDsStableAcrossRebuilds() {
        let i = input(topology: topology())
        let a = rows(i).map(\.id)
        let b = rows(i).map(\.id)
        #expect(a == b)
        #expect(Set(a).count == a.count)
    }

    @Test func storeRoundTrips() {
        let suite = "sidebar-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        let s = SidebarExpansionStore(defaults: d)
        s.toggle(.host(hostID), default: true)
        s.toggle(.session(host: hostID, name: "work"), default: false)
        let s2 = SidebarExpansionStore(defaults: d)
        #expect(s2.expansion == s.expansion)
        #expect(s2.expansion.overrides.count == 2)
        s2.forget(host: hostID)
        #expect(SidebarExpansionStore(defaults: d).expansion.overrides.isEmpty)
    }

    @Test func corruptStoreFallsBackToEmpty() {
        let suite = "sidebar-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        d.set(Data("not json".utf8), forKey: "sidebarExpansion.v1")
        #expect(SidebarExpansionStore(defaults: d).expansion.overrides.isEmpty)
        #expect(SidebarExpansionStore(defaults: UserDefaults(suiteName: "sidebar-\(UUID().uuidString)")!).expansion.overrides.isEmpty)
    }

    @Test func notExpandingOnAttention() {
        let b = Badges(map: ["%5": .needsPermission])
        let r = rows(input(topology: topology()), badges: b)
        // the attention is in the collapsed "work" session; it stays collapsed
        #expect(kinds(r) == ["host", "session:main", "window:1", "window:2", "pane:0", "pane:1", "session:work"])
        var e = SidebarExpansion()
        e.toggle(.host(hostID), default: true)
        #expect(kinds(rows(input(topology: topology(), waiting: 3), e, badges: b)) == ["host"])
    }

    // MARK: current location

    func bothExpanded() -> SidebarExpansion {
        var e = SidebarExpansion()
        e.toggle(.session(host: hostID, name: "work"), default: false)
        return e
    }

    func windows(_ r: [SidebarRow]) -> [WindowRowModel] { r.compactMap { if case .window(let w) = $0 { w } else { nil } } }
    func panes(_ r: [SidebarRow]) -> [PaneRowModel] { r.compactMap { if case .pane(let p) = $0 { p } else { nil } } }

    @Test func onlyTheViewedSessionsWindowIsCurrent() {
        let w = windows(rows(input(topology: topology(), viewed: "$0"), bothExpanded()))
        #expect(w.map(\.row.id) == ["@1", "@0", "@5"])
        #expect(w.filter(\.isCurrent).map(\.row.id) == ["@1"])
    }

    @Test func onlyTheViewedSessionsActivePaneIsCurrent() {
        let p = panes(rows(input(topology: topology(), viewed: "$0"), bothExpanded()))
        #expect(p.map(\.row.id) == ["%1", "%2", "%0", "%5"])
        #expect(p.filter(\.isCurrent).map(\.row.id) == ["%2"])
    }

    @Test func switchingSessionsMovesTheCurrentWindow() {
        let r = rows(input(topology: topology(), viewed: "$1"), bothExpanded())
        let sessions = r.compactMap { if case .session(let s) = $0 { s } else { nil } }
        #expect(sessions.map(\.row.viewed) == [false, true])
        #expect(windows(r).filter(\.isCurrent).map(\.row.id) == ["@5"])
        #expect(panes(r).filter(\.isCurrent).map(\.row.id) == ["%5"])
    }

    @Test func windowValueIsActiveOnlyInTheViewedSession() {
        let w = windows(rows(input(topology: topology(), viewed: "$0"), bothExpanded()))
        #expect(w.map(\.accessibilityValue) == ["active", "", ""])
        let p = panes(rows(input(topology: topology(), viewed: "$0"), bothExpanded()))
        #expect(p.map(\.accessibilityValue) == ["", "active", "", ""])
    }

    @Test func noViewedSessionMeansNothingIsCurrent() {
        let r = rows(input(topology: topology(), viewed: nil), bothExpanded())
        #expect(!windows(r).contains(where: \.isCurrent))
        #expect(!panes(r).contains(where: \.isCurrent))
    }
}
