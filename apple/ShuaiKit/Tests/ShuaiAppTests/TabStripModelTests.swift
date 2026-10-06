import Foundation
import ShuaiCore
import Testing
@testable import ShuaiApp

@MainActor
@Suite struct TabStripModelTests {
    let host = UUID()

    func topology() -> FfiTopology {
        func pane(_ id: String, active: Bool) -> FfiTmuxPane {
            FfiTmuxPane(id: id, index: 0, active: active, currentCommand: "zsh", currentPath: "/work", pid: 1, tty: "", title: "", width: 80, height: 24)
        }
        let w0 = FfiTmuxWindow(id: "@0", index: 1, name: "shell", active: false, flags: "-", panes: [pane("%0", active: true)])
        let w1 = FfiTmuxWindow(id: "@1", index: 2, name: "claude", active: true, flags: "*Z", panes: [pane("%1", active: true)])
        let main = FfiTmuxSession(id: "$0", name: "main", attached: 1, windows: [w1, w0])
        let other = FfiTmuxSession(id: "$1", name: "scratch", attached: 0, windows: [
            FfiTmuxWindow(id: "@5", index: 0, name: "logs", active: true, flags: "*", panes: [pane("%5", active: true)]),
        ])
        return FfiTopology(sessions: [main, other])
    }

    struct Badges: PaneBadgeProvider {
        func badge(host _: String, pane: String) -> PaneBadge? { pane == "%5" ? .needsInput : (pane == "%1" ? .working : nil) }
    }

    func model(viewed: String? = "$0", badges: any PaneBadgeProvider = NoPaneBadges()) -> TabStripModel {
        TabStripModel(topology: topology(), viewedSessionID: viewed, host: host, badges: badges)
    }

    @Test func tabsAreTheViewedSessionsWindowsInOrder() {
        #expect(model().tabs.map(\.id) == ["@0", "@1"])
        #expect(model(viewed: "$1").tabs.map(\.id) == ["@5"])
    }

    @Test func sessionMenuMarksTheViewedSession() {
        let entries = model(badges: Badges()).sessions
        #expect(entries.map(\.name) == ["main", "scratch"])
        #expect(entries.map(\.isViewed) == [true, false])
        #expect(entries[1].badge == .needsInput)
        #expect(model().viewedSessionName == "main")
    }

    @Test func tabValueIsExactlyActive() {
        let tabs = model().tabs
        #expect(tabs.map(\.value) == ["", "active"])
    }

    @Test func tabLabelMentionsZoomAndBadge() {
        let tabs = model(badges: Badges()).tabs
        #expect(tabs[0].label == "1: shell")
        #expect(tabs[1].label == "2: claude, zoomed, working")
    }

    @Test func emptyTopologyHasNoTabs() {
        let m = TabStripModel(topology: FfiTopology(sessions: []), viewedSessionID: nil, host: host, badges: NoPaneBadges())
        #expect(m.tabs.isEmpty)
        #expect(m.sessions.isEmpty)
        #expect(m.viewedSessionName == nil)
        #expect(m.viewedSessionID == nil)
    }
}
