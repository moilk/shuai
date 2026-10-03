import Foundation
import ShuaiCore
import Testing
@testable import ShuaiApp

@MainActor
@Suite struct TmuxTreeTests {
    let host = UUID()

    func topology() -> FfiTopology {
        func pane(_ id: String, _ i: UInt32, active: Bool, cmd: String = "zsh", path: String = "/home/dev/app") -> FfiTmuxPane {
            FfiTmuxPane(id: id, index: i, active: active, currentCommand: cmd, currentPath: path, pid: 1, tty: "/dev/x", title: "", width: 80, height: 24)
        }
        let w0 = FfiTmuxWindow(id: "@0", index: 1, name: "shell", active: false, flags: "-", panes: [pane("%0", 0, active: true)])
        let w1 = FfiTmuxWindow(id: "@1", index: 2, name: "claude", active: true, flags: "*Z", panes: [
            pane("%1", 0, active: false, cmd: "claude", path: "/srv/api"), pane("%2", 1, active: true, cmd: "vim"),
        ])
        let s0 = FfiTmuxSession(id: "$0", name: "main", attached: 1, windows: [w1, w0]) // deliberately unsorted
        let s1 = FfiTmuxSession(id: "$1", name: "work", attached: 0, windows: [
            FfiTmuxWindow(id: "@5", index: 0, name: "edit", active: true, flags: "*", panes: [pane("%5", 0, active: true)]),
        ])
        return FfiTopology(sessions: [s0, s1])
    }

    struct Badges: PaneBadgeProvider {
        func badge(host _: String, pane: String) -> PaneBadge? {
            pane == "%1" ? .needsPermission : nil
        }
    }

    @Test func sessionsWindowsAndPanes() {
        let tree = TmuxTree.sessions(topology: topology(), viewedSessionID: "$0", host: host, badges: NoPaneBadges())
        #expect(tree.map(\.name) == ["main", "work"])
        #expect(tree.map(\.viewed) == [true, false])
        let main = tree[0]
        // windows are ordered by tmux index, not by arrival
        #expect(main.windows.map(\.id) == ["@0", "@1"])
        #expect(main.windows.map(\.paneCount) == [1, 2])
        #expect(main.windows[1].active)
        #expect(main.windows[1].zoomed)
        #expect(!main.windows[0].zoomed)
        #expect(main.windows[1].title == "2: claude")
    }

    @Test func panesAreListedOnlyWhenThereIsMoreThanOne() {
        let main = TmuxTree.sessions(topology: topology(), viewedSessionID: "$0", host: host, badges: NoPaneBadges())[0]
        #expect(main.windows[0].panes.isEmpty)
        #expect(main.windows[1].panes.map(\.id) == ["%1", "%2"])
        #expect(main.windows[1].panes[1].active)
        #expect(main.windows[1].panes[0].title == "claude \u{2014} api")
    }

    @Test func windowBadgeIsTheStrongestOfItsPanes() {
        let main = TmuxTree.sessions(topology: topology(), viewedSessionID: "$0", host: host, badges: Badges())[0]
        #expect(main.windows[0].badge == nil)
        #expect(main.windows[1].badge?.label == "needs approval")
        #expect(main.windows[1].panes[0].badge?.needsAttention == true)
        #expect(main.windows[1].panes[1].badge == nil)
        #expect(main.badge?.label == "needs approval") // the session row aggregates too
    }

    @Test func noViewedSessionMarksNone() {
        let tree = TmuxTree.sessions(topology: topology(), viewedSessionID: nil, host: host, badges: NoPaneBadges())
        #expect(tree.allSatisfy { !$0.viewed })
    }

    @Test func tabStripIsTheViewedSessionsWindowsInOrder() {
        let t = topology()
        let tabs = TmuxTree.windowRows(of: t.sessions[0], host: host, badges: Badges())
        #expect(tabs.map(\.title) == ["1: shell", "2: claude"])
        #expect(tabs[1].badge != nil)
    }
}
