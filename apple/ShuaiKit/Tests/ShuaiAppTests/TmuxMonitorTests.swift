import Foundation
import ShuaiCore
import ShuaiPlatform
import Testing
@testable import ShuaiApp

@MainActor
@Suite struct TmuxMonitorTests {
    static let us = "\u{1f}"
    let listPanes = Fixtures.text("local36-listpanes.txt")

    /// A connection whose `tmux -V` works and whose control channel is served by `server`.
    func rig(
        version: String = "tmux 3.6a", debounce: Duration = .milliseconds(30), pollInterval: Duration = .milliseconds(20),
        attachRetryDelay: Duration = .milliseconds(1)
    ) -> (FakeConnection, FakeControlServer, TmuxMonitor) {
        let conn = FakeConnection()
        let server = FakeControlServer(panes: listPanes)
        conn.execHandler.with { $0 = { cmd in
            if cmd == "tmux -V" { return ExecResult(stdout: Data((version + "\n").utf8), stderr: Data(), exitStatus: 0, exitSignal: nil) }
            if cmd.hasPrefix("tmux list-panes") { return ExecResult(stdout: Data(server.panes.get.utf8), stderr: Data(), exitStatus: 0, exitSignal: nil) }
            if cmd.hasPrefix("tmux list-clients") { return ExecResult(stdout: Data(server.clients.get.utf8), stderr: Data(), exitStatus: 0, exitSignal: nil) }
            return ExecResult(stdout: Data("exec:\(cmd)".utf8), stderr: Data(), exitStatus: 0, exitSignal: nil)
        } }
        conn.execStreamSetup.with { $0 = { exec, _ in server.install(on: exec) } }
        let monitor = TmuxMonitor(
            sessionName: "main", ptySize: { (120, 40) }, debounce: debounce, pollInterval: pollInterval,
            attachRetries: 5, attachRetryDelay: attachRetryDelay)
        return (conn, server, monitor)
    }

    func clientsText(ptyTTY: String = "/dev/ttys002", controlPid: Int = 4242) -> String {
        [
            ["\(ptyTTY)", "100", "$0", "main", "0", "1000", "120", "40"].joined(separator: Self.us),
            ["", "\(controlPid)", "$0", "main", "1", "1001", "80", "24"].joined(separator: Self.us),
        ].joined(separator: "\n") + "\n"
    }

    // MARK: startup

    @Test func opensAControlChannelSuppressesOutputAndLoadsTheTopology() async throws {
        let (conn, server, monitor) = rig()
        await monitor.start(on: conn)
        #expect(monitor.state == .live)
        let cmd = try #require(conn.execStreamCommands.get.first)
        #expect(cmd.hasPrefix("tmux -C attach-session"))
        #expect(cmd.contains("=main:"))
        // suppression is the very first line
        #expect(conn.execStreams.get[0].lines.first == "refresh-client -f no-output")
        #expect(server.listPanesCount == 1)
        let t = try #require(monitor.topology)
        #expect(t.sessions.count == 1)
        #expect(t.sessions[0].name == "main")
        #expect(t.sessions[0].windows.count == 2)
        await monitor.stop()
    }

    @Test func controlModeNeedsNoPty() async throws {
        // `tmux -C` is spawned on a plain exec channel (execStream), never on a PTY.
        let (conn, _, monitor) = rig()
        await monitor.start(on: conn)
        #expect(conn.opens.get.isEmpty)
        #expect(conn.execStreams.get.count == 1)
        await monitor.stop()
    }

    @Test func tmuxMissingTurnsTheMonitorOff() async {
        let conn = FakeConnection() // default exec: exit 127
        let monitor = TmuxMonitor(sessionName: "main")
        await monitor.start(on: conn)
        guard case .unavailable = monitor.state else { Issue.record("state \(monitor.state)"); return }
        #expect(conn.execStreams.get.isEmpty)
        #expect(monitor.topology == nil)
    }

    @Test func unparseableVersionTurnsTheMonitorOff() async {
        let (conn, _, monitor) = rig(version: "wat")
        await monitor.start(on: conn)
        guard case .unavailable = monitor.state else { Issue.record("state \(monitor.state)"); return }
        #expect(conn.execStreams.get.isEmpty)
    }

    @Test func attachRaceRetriesUntilTheSessionExists() async {
        let (conn, server, monitor) = rig()
        // the PTY client creates the session a moment later: the first two attaches fail at once
        conn.execStreamSetup.with { $0 = { exec, n in
            if n <= 2 { exec.finish(.remote) } else { server.install(on: exec) }
        } }
        await monitor.start(on: conn)
        #expect(monitor.state == .live)
        #expect(conn.execStreams.get.count == 3)
        await monitor.stop()
    }

    @Test func givesUpWhenTheSessionNeverAppears() async {
        let (conn, _, monitor) = rig()
        conn.execStreamSetup.with { $0 = { exec, _ in exec.finish(.remote) } }
        await monitor.start(on: conn)
        guard case .ended = monitor.state else { Issue.record("state \(monitor.state)"); return }
        #expect(conn.execStreams.get.count == 5)
    }

    // MARK: events

    @Test func renamePatchesApplyWithoutAnotherListPanes() async throws {
        let (conn, server, monitor) = rig()
        await monitor.start(on: conn)
        let exec = conn.execStreams.get[0]
        let window = try #require(monitor.topology?.sessions[0].windows.first)
        exec.emit("%window-renamed \(window.id) fresh-name\n")
        #expect(await waitUntil { monitor.topology?.sessions[0].windows.first?.name == "fresh-name" })
        exec.emit("%session-renamed $0 other\n")
        #expect(await waitUntil { monitor.topology?.sessions[0].name == "other" })
        try? await Task.sleep(for: .milliseconds(120))
        #expect(server.listPanesCount == 1)
        await monitor.stop()
    }

    @Test func structuralBurstsAreDebouncedIntoOneRefresh() async throws {
        let (conn, server, monitor) = rig(debounce: .milliseconds(80))
        await monitor.start(on: conn)
        let exec = conn.execStreams.get[0]
        for i in 0 ..< 6 {
            exec.emit("%window-add @\(10 + i)\n")
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(await waitUntil { server.listPanesCount >= 2 })
        try? await Task.sleep(for: .milliseconds(200))
        #expect(server.listPanesCount == 2) // initial + exactly one
        await monitor.stop()
    }

    @Test func refreshPublishesTheNewTopologyAndTheDiff() async throws {
        let (conn, server, monitor) = rig()
        await monitor.start(on: conn)
        let before = monitor.changeCount
        // a new window in the same session appears
        let extra = ["$0", "main", "0", "@7", "2", "build", "0", "-", "%9", "0", "1", "make", "/home/dev/projx", "9", "/dev/ttys009", "t", "120", "40"]
            .joined(separator: Self.us)
        server.panes.with { $0 += extra + "\n" }
        conn.execStreams.get[0].emit("%window-add @7\n")
        #expect(await waitUntil { monitor.changeCount > before })
        #expect(monitor.topology?.sessions[0].windows.count == 3)
        #expect(monitor.lastChanges.contains { if case .windowAdded(_, let w, _, _) = $0 { w == "@7" } else { false } })
        await monitor.stop()
    }

    @Test func replayingTheRealTranscriptNeverStallsAndEndsOnExit() async throws {
        let (conn, server, monitor) = rig()
        await monitor.start(on: conn)
        conn.execStreams.get[0].emit(Fixtures.text("local36-control.txt"))
        #expect(await waitUntil { if case .ended = monitor.state { true } else { false } })
        // many structural events, but they coalesce: nowhere near one list-panes per event
        #expect(server.listPanesCount <= 4)
        #expect(monitor.topology != nil)
    }

    @Test func replayingTheNoOutputTranscriptEndsOnExit() async throws {
        let (conn, _, monitor) = rig()
        await monitor.start(on: conn)
        conn.execStreams.get[0].emit(Fixtures.text("local36-nooutput.txt"))
        #expect(await waitUntil { if case .ended = monitor.state { true } else { false } })
    }

    @Test func byteChunksSplitAnywhereGiveTheSameResult() async throws {
        let (conn, _, monitor) = rig()
        await monitor.start(on: conn)
        let exec = conn.execStreams.get[0]
        let window = try #require(monitor.topology?.sessions[0].windows.first)
        let bytes = Array("%window-renamed \(window.id) chunked\n".utf8)
        for b in bytes { exec.emit(.stdout(bytes: Data([b]))) }
        #expect(await waitUntil { monitor.topology?.sessions[0].windows.first?.name == "chunked" })
        await monitor.stop()
    }

    @Test func sessionKilledEndsTheMonitor() async throws {
        let (conn, _, monitor) = rig()
        await monitor.start(on: conn)
        conn.execStreams.get[0].emit("%exit\n")
        #expect(await waitUntil { if case .ended = monitor.state { true } else { false } })
        // the last known tree stays for the UI
        #expect(monitor.topology != nil)
    }

    @Test func channelClosingWithoutExitEndsTheMonitorAndFailsPendingCommands() async throws {
        let (conn, server, monitor) = rig()
        await monitor.start(on: conn)
        let exec = conn.execStreams.get[0]
        exec.onWrite.with { $0 = nil } // swallow replies: the command stays pending
        _ = server
        let cmd = try tmuxSelectWindow(windowId: "@0")
        let pending = Task { @MainActor in try await monitor.run(cmd) }
        try? await Task.sleep(for: .milliseconds(20))
        exec.finish(.remote)
        await #expect(throws: TmuxError.self) { _ = try await pending.value }
        #expect(await waitUntil { if case .ended = monitor.state { true } else { false } })
    }

    // MARK: commands

    @Test func commandsGoOverTheControlChannelAndReturnTheirOutput() async throws {
        let (conn, _, monitor) = rig()
        await monitor.start(on: conn)
        let lines = try await monitor.run(try tmuxSelectWindow(windowId: "@1"))
        #expect(lines.first?.hasPrefix("reply:select-window") == true)
        await monitor.stop()
    }

    @Test func tmuxErrorsAreThrown() async throws {
        let (conn, _, monitor) = rig()
        await monitor.start(on: conn)
        let bogus = FfiTmuxCommand(argv: ["bogus"], shell: "tmux bogus", controlLine: "bogus")
        await #expect(throws: TmuxError.self) { _ = try await monitor.run(bogus) }
        await monitor.stop()
    }

    @Test func concurrentCommandsGetTheirOwnReplies() async throws {
        let (conn, _, monitor) = rig()
        await monitor.start(on: conn)
        let tasks = (0 ..< 20).map { i in
            Task { @MainActor in try await monitor.run(try tmuxSelectWindow(windowId: "@\(i)")) }
        }
        var results: [Int: [String]] = [:]
        for (i, t) in tasks.enumerated() { results[i] = try await t.value }
        for i in 0 ..< 20 { #expect(results[i]?.first?.contains("@\(i)") == true, "\(i): \(String(describing: results[i]))") }
        await monitor.stop()
    }

    @Test func stopClosesTheChannelAndKeepsTheLastTree() async throws {
        let (conn, _, monitor) = rig()
        await monitor.start(on: conn)
        await monitor.stop()
        #expect(monitor.state == .stopped)
        #expect(conn.execStreams.get[0].closeCalls.get >= 1)
        #expect(monitor.topology != nil)
        await #expect(throws: TmuxError.self) { _ = try await monitor.run(try tmuxSelectWindow(windowId: "@0")) }
    }

    // MARK: client targeting

    @Test func findsTheOwnPtyClientThroughTheControlClientsPid() async throws {
        let (conn, server, monitor) = rig()
        server.clients.with { $0 = clientsText() }
        await monitor.start(on: conn)
        #expect(monitor.ptyClientTty == "/dev/ttys002")
        #expect(monitor.viewedSessionID == "$0")
        // the control channel was asked who it is
        #expect(server.commands.get.contains { $0.hasPrefix("display-message") })
        await monitor.stop()
    }

    @Test func ptyClientStaysStickyAfterItSwitchesSession() async throws {
        let (conn, server, monitor) = rig()
        server.clients.with { $0 = clientsText() }
        await monitor.start(on: conn)
        // the user switched the terminal to another session: same tty, new session
        let moved = [
            ["/dev/ttys002", "100", "$1", "other", "0", "1000", "120", "40"].joined(separator: Self.us),
            ["", "4242", "$0", "main", "1", "1001", "80", "24"].joined(separator: Self.us),
        ].joined(separator: "\n") + "\n"
        server.clients.with { $0 = moved }
        await monitor.refreshNow()
        #expect(monitor.ptyClientTty == "/dev/ttys002")
        #expect(monitor.viewedSessionID == "$1")
        await monitor.stop()
    }

    @Test func noPtyClientFoundLeavesTargetingEmpty() async throws {
        let (conn, _, monitor) = rig()
        await monitor.start(on: conn)
        #expect(monitor.ptyClientTty == nil)
        await monitor.stop()
    }

    // MARK: old tmux fallback

    @Test func tmuxBeforeNoOutputPollsListPanes() async throws {
        let (conn, server, monitor) = rig(version: "tmux 2.9a", pollInterval: .milliseconds(15))
        await monitor.start(on: conn)
        #expect(monitor.state == .polling)
        #expect(conn.execStreams.get.isEmpty) // no control channel on a version that cannot silence %output
        #expect(monitor.topology?.sessions[0].windows.count == 2)
        let extra = ["$0", "main", "0", "@7", "2", "build", "0", "-", "%9", "0", "1", "make", "/x", "9", "/dev/ttys009", "t", "120", "40"]
            .joined(separator: Self.us)
        server.panes.with { $0 += extra + "\n" }
        #expect(await waitUntil { monitor.topology?.sessions[0].windows.count == 3 })
        await monitor.stop()
        #expect(monitor.state == .stopped)
    }

    @Test func pollingModeRunsCommandsThroughOneShotExec() async throws {
        let (conn, _, monitor) = rig(version: "tmux 2.9a", pollInterval: .seconds(30))
        await monitor.start(on: conn)
        let lines = try await monitor.run(try tmuxSelectWindow(windowId: "@1"))
        #expect(conn.execCommands.get.contains("tmux select-window -t @1"))
        #expect(lines.first?.hasPrefix("exec:") == true)
        await monitor.stop()
    }
}
