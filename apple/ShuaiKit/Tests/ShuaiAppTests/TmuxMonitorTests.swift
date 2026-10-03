import Foundation
import ShuaiCore
import ShuaiPlatform
import Testing
@testable import ShuaiApp

/// A debounce timer the test fires by hand: every `sleep` suspends until `fire()` (or cancellation).
final class ManualSleeper: @unchecked Sendable {
    private let state = Locked<(calls: Int, nextID: Int, waiters: [Int: CheckedContinuation<Void, Error>])>((0, 0, [:]))
    var calls: Int { state.get.calls }

    @Sendable func sleep(_ d: Duration) async throws {
        let id = state.with { s -> Int in s.calls += 1; s.nextID += 1; return s.nextID }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { cont.resume(throwing: CancellationError()); return }
                state.with { $0.waiters[id] = cont }
            }
        } onCancel: {
            let c = state.with { $0.waiters.removeValue(forKey: id) }
            c?.resume(throwing: CancellationError())
        }
    }

    func fire() {
        let all = state.with { s -> [CheckedContinuation<Void, Error>] in
            defer { s.waiters = [:] }
            return Array(s.waiters.values)
        }
        all.forEach { $0.resume() }
    }
}

@MainActor
@Suite struct TmuxMonitorTests {
    static let us = "\u{1f}"
    let listPanes = Fixtures.text("local36-listpanes.txt")

    /// A connection whose `tmux -V` works and whose control channel is served by `server`.
    func rig(
        version: String = "tmux 3.6a", debounce: Duration = .milliseconds(30), pollInterval: Duration = .milliseconds(20),
        attachRetryDelay: Duration = .milliseconds(1),
        debounceSleep: (@Sendable (Duration) async throws -> Void)? = nil
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
            attachRetries: 5, attachRetryDelay: attachRetryDelay, debounceSleep: debounceSleep)
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
        let timer = ManualSleeper()
        let (conn, server, monitor) = rig(debounceSleep: timer.sleep)
        await monitor.start(on: conn)
        let exec = conn.execStreams.get[0]
        let window = try #require(monitor.topology?.sessions[0].windows.first)
        var renames = 0
        // A rename is patched in place, in stream order: once it shows, everything before it was processed.
        func barrier() async {
            renames += 1
            exec.emit("%window-renamed \(window.id) barrier-\(renames)\n")
            #expect(await waitUntil(timeout: .seconds(20)) { monitor.topology?.sessions[0].windows.first?.name == "barrier-\(renames)" })
        }

        // burst 1: six notifications inside the window -> one timer, no refresh until it fires
        for i in 0 ..< 6 { exec.emit("%window-add @\(10 + i)\n") }
        await barrier()
        #expect(timer.calls == 1)
        #expect(server.listPanesCount == 1)
        timer.fire()
        #expect(await waitUntil(timeout: .seconds(20)) { server.listPanesCount == 2 })

        // burst 2 after the window: a fresh timer and exactly one more refresh
        for i in 0 ..< 3 { exec.emit("%window-add @\(20 + i)\n") }
        await barrier()
        #expect(timer.calls == 2)
        #expect(server.listPanesCount == 2)
        timer.fire()
        #expect(await waitUntil(timeout: .seconds(20)) { server.listPanesCount == 3 })
        await barrier()
        #expect(timer.calls == 2)
        #expect(server.listPanesCount == 3)
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

    @Test func restartForgetsAStalePtyClientEvenIfItsTtyStillExists() async throws {
        let (conn, server, monitor) = rig()
        server.clients.with { $0 = clientsText(ptyTTY: "/dev/ttys002") }
        await monitor.start(on: conn)
        #expect(monitor.ptyClientTty == "/dev/ttys002")
        // reconnect: the old client lingers (or its tty was reused by another client); our new PTY
        // client and control client are newer
        let after = [
            ["/dev/ttys002", "100", "$0", "main", "0", "1000", "90", "20"].joined(separator: Self.us),
            ["/dev/ttys007", "300", "$0", "main", "0", "2000", "120", "40"].joined(separator: Self.us),
            ["", "4343", "$0", "main", "1", "2001", "80", "24"].joined(separator: Self.us),
        ].joined(separator: "\n") + "\n"
        server.clients.with { $0 = after }
        server.controlPid.with { $0 = 4343 }
        await monitor.start(on: conn)
        #expect(monitor.ptyClientTty == "/dev/ttys007")
        await monitor.stop()
    }

    @Test func lateEventsOfAReplacedChannelAreIgnored() async throws {
        let (conn, _, monitor) = rig()
        await monitor.start(on: conn)
        let old = conn.execStreams.get[0]
        let window = try #require(monitor.topology?.sessions[0].windows.first)
        let original = window.name
        await monitor.start(on: conn)
        #expect(conn.execStreams.get.count == 2)
        old.emit("%window-renamed \(window.id) stale\n")
        old.emit("%exit\n")
        try? await Task.sleep(for: .milliseconds(80))
        #expect(monitor.topology?.sessions[0].windows.first?.name == original)
        #expect(monitor.state == .live)
        await monitor.stop()
    }

    func twoClientsOnOneSession() -> String {
        // the laptop's client matches our size; ours does not (the terminal was resized meanwhile)
        [
            ["/dev/ttys002", "100", "$0", "main", "0", "1000", "120", "40"].joined(separator: Self.us),
            ["/dev/ttys003", "200", "$0", "main", "0", "1500", "100", "30"].joined(separator: Self.us),
            ["", "4242", "$0", "main", "1", "1501", "80", "24"].joined(separator: Self.us),
        ].joined(separator: "\n") + "\n"
    }

    @Test func otherClientsOnTheSameSessionAreToldApartByTheSshProcessTree() async throws {
        let (conn, server, monitor) = rig()
        server.clients.with { $0 = twoClientsOnOneSession() }
        let base = conn.execHandler.get
        // pid ppid: 4242 and 200 share sshd session 900; 100 hangs off another connection (777)
        let ps = "1 0\n800 1\n900 800\n777 800\n4240 900\n4242 4240\n199 900\n200 199\n99 777\n100 99\n"
        conn.execHandler.with { $0 = { cmd in
            cmd.hasPrefix("ps ") ? ExecResult(stdout: Data(ps.utf8), stderr: Data(), exitStatus: 0, exitSignal: nil) : base(cmd)
        } }
        await monitor.start(on: conn)
        #expect(monitor.ptyClientTty == "/dev/ttys003")
        await monitor.stop()
    }

    @Test func ambiguousClientsFallBackToTheHeuristicWhenPsFails() async throws {
        let (conn, server, monitor) = rig()
        server.clients.with { $0 = twoClientsOnOneSession() }
        await monitor.start(on: conn) // the default handler answers `ps` with garbage
        #expect(monitor.ptyClientTty == "/dev/ttys002") // size match
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
