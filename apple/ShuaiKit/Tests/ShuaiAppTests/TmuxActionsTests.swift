import Foundation
import ShuaiCore
import Testing
@testable import ShuaiApp

@MainActor
@Suite struct TmuxActionsTests {
    nonisolated static let us = "\u{1f}"

    /// Two sessions: `main` (windows @0 index 1 "zsh", @1 index 2 active with panes %1 %2 active) and `work` ($1, @5).
    nonisolated(unsafe) static let panes: String = {
        func row(_ f: [String]) -> String { f.joined(separator: us) }
        return [
            row(["$0", "main", "1", "@0", "1", "zsh", "0", "-", "%0", "0", "1", "zsh", "/home/dev", "1", "/dev/ttys002", "t", "120", "40"]),
            row(["$0", "main", "1", "@1", "2", "build", "1", "*", "%1", "0", "0", "bash", "/home/dev/projx", "2", "/dev/ttys003", "t", "60", "40"]),
            row(["$0", "main", "1", "@1", "2", "build", "1", "*", "%2", "1", "1", "env", "/home/dev/projx", "3", "/dev/ttys004", "t", "59", "40"]),
            row(["$1", "work", "0", "@5", "0", "edit", "1", "*", "%5", "0", "1", "vim", "/srv/w", "5", "/dev/ttys005", "t", "120", "40"]),
        ].joined(separator: "\n") + "\n"
    }()

    func clients(pty: String = "/dev/ttys002", session: (String, String) = ("$0", "main")) -> String {
        [
            [pty, "100", session.0, session.1, "0", "1000", "120", "40"].joined(separator: Self.us),
            ["", "4242", "$0", "main", "1", "1001", "80", "24"].joined(separator: Self.us),
        ].joined(separator: "\n") + "\n"
    }

    func rig(
        withClient: Bool = true, hostID: UUID = UUID(), notices: (any NoticePosting)? = nil
    ) async -> (FakeControlServer, TmuxMonitor, TmuxActions) {
        let conn = FakeConnection()
        let server = FakeControlServer(panes: Self.panes)
        if withClient { server.clients.with { $0 = clients() } }
        conn.execHandler.with { $0 = { _ in ExecResult(stdout: Data("tmux 3.6a\n".utf8), stderr: Data(), exitStatus: 0, exitSignal: nil) } }
        conn.execStreamSetup.with { $0 = { exec, _ in server.install(on: exec) } }
        let monitor = TmuxMonitor(sessionName: "main", debounce: .milliseconds(10))
        await monitor.start(on: conn)
        return (server, monitor, TmuxActions(monitor: monitor, notices: notices.map { NoticeRoute(hostID: hostID, poster: $0) }))
    }

    func sent(_ server: FakeControlServer) -> [String] {
        server.commands.get.filter { !$0.hasPrefix("list-") && !$0.hasPrefix("display-message") && !$0.hasPrefix("refresh-client") }
    }

    // MARK: derived state

    @Test func viewedSessionWindowsAreOrderedByIndex() async {
        let (_, monitor, actions) = await rig()
        #expect(actions.viewedSession?.name == "main")
        #expect(actions.windows.map(\.id) == ["@0", "@1"])
        #expect(actions.activeWindow?.id == "@1")
        #expect(actions.activePane?.id == "%2")
        await monitor.stop()
    }

    @Test func viewedSessionFallsBackToTheMonitoredName() async {
        let (_, monitor, actions) = await rig(withClient: false)
        #expect(actions.viewedSession?.id == "$0")
        await monitor.stop()
    }

    // MARK: selecting

    @Test func selectWindowSendsSelectWindow() async throws {
        let (server, monitor, actions) = await rig()
        try await actions.selectWindow("@0")
        #expect(sent(server) == [try tmuxSelectWindow(windowId: "@0").controlLine])
        await monitor.stop()
    }

    @Test func positionIsTheListPositionNotTheTmuxIndex() async throws {
        // base-index 1: window index 1 is first. Position 2 is @1 (index 2); position 3 does not exist.
        let (server, monitor, actions) = await rig()
        try await actions.selectWindow(position: 2)
        #expect(sent(server) == [try tmuxSelectWindow(windowId: "@1").controlLine])
        try await actions.selectWindow(position: 3)
        #expect(sent(server).count == 1)
        await monitor.stop()
    }

    @Test func selectPaneSelectsItsWindowFirst() async throws {
        let (server, monitor, actions) = await rig()
        try await actions.selectPane("%1")
        #expect(sent(server) == [try tmuxSelectWindow(windowId: "@1").controlLine, try tmuxSelectPane(paneId: "%1").controlLine])
        await monitor.stop()
    }

    @Test func selectingInAnotherSessionSwitchesThePtyClientFirst() async throws {
        let (server, monitor, actions) = await rig()
        try await actions.selectWindow("@5")
        #expect(sent(server) == [
            try tmuxSwitchClient(clientTty: "/dev/ttys002", sessionId: "$1").controlLine,
            try tmuxSelectWindow(windowId: "@5").controlLine,
        ])
        await monitor.stop()
    }

    @Test func switchSessionTargetsThePtyClientNotTheControlClient() async throws {
        let (server, monitor, actions) = await rig()
        try await actions.switchSession("$1")
        let line = try #require(sent(server).first)
        #expect(line.contains("-c /dev/ttys002"))
        #expect(line.hasPrefix("switch-client"))
        await monitor.stop()
    }

    @Test func switchSessionWithoutAPtyClientFails() async throws {
        let (server, monitor, actions) = await rig(withClient: false)
        await #expect(throws: TmuxError.noPtyClient) { try await actions.switchSession("$1") }
        #expect(sent(server).isEmpty)
        await monitor.stop()
    }

    // MARK: structure

    @Test func newWindowUsesTheActivePaneDirectory() async throws {
        let (server, monitor, actions) = await rig()
        try await actions.newWindow()
        #expect(sent(server) == [tmuxNewWindow(session: "main", cwd: "/home/dev/projx", name: nil).controlLine])
        await monitor.stop()
    }

    @Test func splitUsesTheActivePaneAndDirection() async throws {
        let (server, monitor, actions) = await rig()
        try await actions.split(horizontal: true)
        try await actions.split(horizontal: false)
        #expect(sent(server) == [
            try tmuxSplitWindow(paneId: "%2", horizontal: true, cwd: "/home/dev/projx").controlLine,
            try tmuxSplitWindow(paneId: "%2", horizontal: false, cwd: "/home/dev/projx").controlLine,
        ])
        await monitor.stop()
    }

    @Test func renameWindow() async throws {
        let (server, monitor, actions) = await rig()
        try await actions.renameWindow("@1", to: "my name")
        #expect(sent(server) == [try tmuxRenameWindow(windowId: "@1", name: "my name").controlLine])
        await monitor.stop()
    }

    @Test func windowNavigationTargetsTheViewedSession() async throws {
        let (server, monitor, actions) = await rig()
        try await actions.nextWindow()
        try await actions.previousWindow()
        try await actions.lastWindow()
        #expect(sent(server) == [
            tmuxNextWindow(session: "main").controlLine, tmuxPreviousWindow(session: "main").controlLine,
            tmuxLastWindow(session: "main").controlLine,
        ])
        await monitor.stop()
    }

    @Test func zoomAndPaneDirectionUseTheActivePane() async throws {
        let (server, monitor, actions) = await rig()
        try await actions.zoom()
        try await actions.selectPane(direction: .left)
        #expect(sent(server) == [
            try tmuxZoomPane(paneId: "%2").controlLine,
            try tmuxSelectPaneDirection(windowId: "@1", direction: .left).controlLine,
        ])
        await monitor.stop()
    }

    // MARK: kill needs confirmation

    @Test func killWindowAsksFirstAndOnlyRunsWhenConfirmed() async throws {
        let (server, monitor, actions) = await rig()
        actions.requestKillWindow("@1")
        #expect(actions.pendingConfirmation?.title.contains("build") == true)
        #expect(sent(server).isEmpty)
        try await actions.confirmPending()
        #expect(sent(server) == [try tmuxKillWindow(windowId: "@1").controlLine])
        #expect(actions.pendingConfirmation == nil)
        await monitor.stop()
    }

    @Test func cancellingTheConfirmationSendsNothing() async throws {
        let (server, monitor, actions) = await rig()
        actions.requestKillWindow("@1")
        actions.cancelPending()
        try await actions.confirmPending()
        #expect(sent(server).isEmpty)
        await monitor.stop()
    }

    @Test func confirmingAfterTheDialogDismissStillKills() async throws {
        let (server, monitor, actions) = await rig()
        actions.requestKillWindow("@1")
        let captured = try #require(actions.pendingConfirmation)
        actions.cancelPending() // what the dialog's dismissal does after the button action
        try await actions.confirm(captured)
        #expect(sent(server) == [try tmuxKillWindow(windowId: "@1").controlLine])
        await monitor.stop()
    }

    @Test func confirmClearsThePendingConfirmation() async throws {
        let (_, monitor, actions) = await rig()
        actions.requestKillWindow("@1")
        let captured = try #require(actions.pendingConfirmation)
        try await actions.confirm(captured)
        #expect(actions.pendingConfirmation == nil)
        await monitor.stop()
    }

    @Test func confirmingAPaneKillSendsKillPane() async throws {
        let (server, monitor, actions) = await rig()
        actions.requestKillPane("%1")
        let captured = try #require(actions.pendingConfirmation)
        try await actions.confirm(captured)
        #expect(sent(server) == [try tmuxKillPane(paneId: "%1").controlLine])
        await monitor.stop()
    }

    @Test func cancelPendingStillSendsNothing() async throws {
        let (server, monitor, actions) = await rig()
        actions.requestKillPane("%1")
        actions.cancelPending()
        #expect(actions.pendingConfirmation == nil)
        try await actions.confirmPending()
        #expect(sent(server).isEmpty)
        await monitor.stop()
    }

    @Test func killPaneAsksFirstAndOnlyRunsWhenConfirmed() async throws {
        let (server, monitor, actions) = await rig()
        actions.requestKillPane("%1")
        #expect(actions.pendingConfirmation?.kind == .killPane(id: "%1"))
        #expect(actions.pendingConfirmation?.message.contains("window") == false)
        #expect(sent(server).isEmpty)
        try await actions.confirmPending()
        #expect(sent(server) == [try tmuxKillPane(paneId: "%1").controlLine])
        #expect(actions.pendingConfirmation == nil)
        await monitor.stop()
    }

    @Test func killingTheOnlyPaneWarnsThatTheWindowCloses() async throws {
        let (server, monitor, actions) = await rig()
        actions.requestKillPane("%0")
        #expect(actions.pendingConfirmation?.message.contains("window") == true)
        actions.cancelPending()
        try await actions.confirmPending()
        #expect(sent(server).isEmpty)
        await monitor.stop()
    }

    @Test func killingAnUnknownPaneAsksNothing() async throws {
        let (_, monitor, actions) = await rig()
        actions.requestKillPane("%99")
        #expect(actions.pendingConfirmation == nil)
        await monitor.stop()
    }

    // MARK: shortcut dispatch

    @Test func shortcutsMapToActions() async throws {
        let (server, monitor, actions) = await rig()
        try await actions.perform(.selectWindow(position: 1))
        try await actions.perform(.newWindow)
        try await actions.perform(.splitRight)
        try await actions.perform(.nextWindow)
        try await actions.perform(.zoomPane)
        try await actions.perform(.killWindow)
        #expect(sent(server).count == 5) // kill only asks
        #expect(actions.pendingConfirmation != nil)
        await monitor.stop()
    }

    @Test func quickSwitcherIsNotATmuxAction() async throws {
        let (server, monitor, actions) = await rig()
        try await actions.perform(.quickSwitcher)
        #expect(sent(server).isEmpty)
        await monitor.stop()
    }

    @Test func nextAttentionIsAUIActionNotATmuxCommand() async throws {
        let (server, monitor, actions) = await rig()
        try await actions.perform(.nextAttention)
        #expect(sent(server).isEmpty)
        #expect(ShortcutAction(id: "nextAttention") == .nextAttention)
        await monitor.stop()
    }

    @Test func tmuxRunFailurePostsErrorNotice() async {
        let sink = RecordingNoticeSink()
        let id = UUID()
        let (_, monitor, actions) = await rig(withClient: false, hostID: id, notices: sink)
        await actions.run { try await actions.switchSession("$1") }
        let n = sink.posted.last
        #expect(sink.posted.count == 1)
        #expect(n?.severity == .error)
        #expect(n?.source == .tmux)
        #expect(n?.scope == .host(id))
        #expect(n?.key == "tmux-error:\(id.uuidString)")
        #expect(n?.text == TmuxActions.describe(TmuxError.noPtyClient))
        await monitor.stop()
    }

    @Test func tmuxErrorTextHasHomePathsCollapsed() async {
        let sink = RecordingNoticeSink()
        let (_, monitor, actions) = await rig(notices: sink)
        await actions.run { throw TmuxError.commandFailed("no such file /home/someone/proj") }
        #expect(sink.posted.last?.text == "no such file ~/proj")
        await monitor.stop()
    }

    @Test func retiredActionsPostNothing() async {
        let sink = RecordingNoticeSink()
        let (_, monitor, actions) = await rig(withClient: false, notices: sink)
        actions.retire()
        await actions.run { try await actions.switchSession("$1") }
        #expect(sink.posted.isEmpty)
        await monitor.stop()
    }

    @Test func tmuxErrorKeysAreNamespacedPerHost() async {
        let sink = RecordingNoticeSink()
        let a = UUID(), b = UUID()
        let (_, ma, actionsA) = await rig(withClient: false, hostID: a, notices: sink)
        let (_, mb, actionsB) = await rig(withClient: false, hostID: b, notices: sink)
        await actionsA.run { try await actionsA.switchSession("$1") }
        await actionsB.run { try await actionsB.switchSession("$1") }
        #expect(sink.posted.map(\.key) == ["tmux-error:\(a.uuidString)", "tmux-error:\(b.uuidString)"])
        #expect(sink.active.count == 2)
        await ma.stop()
        await mb.stop()
    }

    @Test func successfulRunPostsNothing() async {
        let sink = RecordingNoticeSink()
        let (_, monitor, actions) = await rig(notices: sink)
        await actions.run { try await actions.selectWindow("@5") }
        #expect(sink.posted.isEmpty)
        await monitor.stop()
    }

    // MARK: quick switcher jumps

    func item(_ kind: SwitcherItem.Kind, session: String? = nil, window: String? = nil, pane: String? = nil) -> SwitcherItem {
        SwitcherItem(
            id: "x", kind: kind, hostID: UUID(), hostName: "h", sessionID: session, windowID: window, paneID: pane,
            title: "t", subtitle: "", searchFields: [], paneIDs: [], connected: true)
    }

    @Test func jumpingToAWindowSelectsIt() async throws {
        let (server, monitor, actions) = await rig()
        try await actions.jump(to: item(.window, session: "$0", window: "@0"))
        #expect(sent(server) == [try tmuxSelectWindow(windowId: "@0").controlLine])
        await monitor.stop()
    }

    @Test func jumpingToAPaneSelectsWindowAndPane() async throws {
        let (server, monitor, actions) = await rig()
        try await actions.jump(to: item(.pane, session: "$0", window: "@1", pane: "%1"))
        #expect(sent(server) == [try tmuxSelectWindow(windowId: "@1").controlLine, try tmuxSelectPane(paneId: "%1").controlLine])
        await monitor.stop()
    }

    @Test func jumpingToASessionSwitchesTheClient() async throws {
        let (server, monitor, actions) = await rig()
        try await actions.jump(to: item(.session, session: "$1"))
        #expect(sent(server) == [try tmuxSwitchClient(clientTty: "/dev/ttys002", sessionId: "$1").controlLine])
        await monitor.stop()
    }

    @Test func jumpingToAHostDoesNothingHere() async throws {
        let (server, monitor, actions) = await rig()
        try await actions.jump(to: item(.host))
        #expect(sent(server).isEmpty)
        await monitor.stop()
    }
}
