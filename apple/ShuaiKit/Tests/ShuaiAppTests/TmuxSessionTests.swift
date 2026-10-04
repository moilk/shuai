import Foundation
import ShuaiCore
import ShuaiPlatform
import Testing
@testable import ShuaiApp

private let host = "dev.example.com"

extension FakeConnection {
    /// Makes this connection a host with a working tmux whose control channel is played by `server`.
    func serveTmux(_ server: FakeControlServer) {
        execHandler.with { $0 = { cmd in
            let out = cmd == "tmux -V" ? "tmux 3.6a\n" : ""
            return ExecResult(stdout: Data(out.utf8), stderr: Data(), exitStatus: 0, exitSignal: nil)
        } }
        execStreamSetup.with { $0 = { exec, _ in server.install(on: exec) } }
    }
}

@MainActor
private struct Harness {
    let engine = FakeEngine()
    let server = FakeControlServer(panes: Fixtures.text("local36-listpanes.txt"))
    let factory: FakeFactory
    let controller: SessionController

    init(tmux: Bool = true, hasTmux: Bool = true) {
        let server = server
        factory = FakeFactory { _, _, _, conn in
            if hasTmux { conn.serveTmux(server) }
        }
        var profile = HostProfile(name: "dev", host: host, username: "alice", auth: .password)
        profile.tmux.enabled = tmux
        profile.tmux.sessionName = "main"
        let passwords = InMemoryPasswordStore()
        try? passwords.setPassword("pw", for: profile.id)
        let known = KnownHostsStore(fileURL: scratchURL("known_hosts"))
        controller = SessionController(
            profile: profile, engine: engine, factory: factory, keys: InMemoryKeyStore(), passwords: passwords,
            knownHosts: known, makePolicy: { ReconnectPolicy(maxAttempts: 3, jitter: false) },
            sleep: { _ in await Task.yield() }, redrawNudgeDelay: .milliseconds(1))
    }
}

@MainActor @Suite(.timeLimit(.minutes(1))) struct TmuxSessionTests {
    @Test func connectingStartsTheControlChannelOnTheSameConnection() async {
        let h = Harness()
        await h.controller.connect()
        #expect(await waitUntil { h.controller.tmux.state == .live && h.controller.tmux.topology != nil })
        let conn = h.factory.last!
        #expect(conn.execStreamCommands.get.count == 1)
        #expect(conn.opens.get.count == 1) // only the PTY is a shell channel
        #expect(h.controller.tmux.topology?.sessions.first?.name == "main")
        await h.controller.disconnect()
    }

    @Test func tmuxDisabledNeverStartsAMonitor() async {
        let h = Harness(tmux: false)
        await h.controller.connect()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(h.factory.last!.execStreamCommands.get.isEmpty)
        #expect(h.factory.last!.execCommands.get.isEmpty)
        #expect(h.controller.tmux.state == .idle)
    }

    @Test func aHostWithoutTmuxLeavesTheMonitorOff() async {
        let h = Harness(hasTmux: false)
        await h.controller.connect()
        #expect(await waitUntil { if case .unavailable = h.controller.tmux.state { true } else { false } })
        #expect(h.controller.tmux.topology == nil)
    }

    @Test func disconnectingStopsTheMonitorAndKeepsTheLastTree() async {
        let h = Harness()
        await h.controller.connect()
        #expect(await waitUntil { h.controller.tmux.state == .live && h.controller.tmux.topology != nil })
        await h.controller.disconnect()
        #expect(h.controller.tmux.state == .stopped)
        #expect(h.controller.tmux.topology != nil)
    }

    @Test func theTmuxClientEndingStopsTheMonitor() async {
        let h = Harness()
        await h.controller.connect()
        #expect(await waitUntil { h.controller.tmux.state == .live && h.controller.tmux.topology != nil })
        // the user detached / killed the session: the PTY command exits cleanly
        h.factory.last!.shell.emit(.exit(status: 0, signal: nil))
        h.factory.last!.shell.emit(.closed(reason: .remote))
        #expect(await waitUntil { h.controller.state == .disconnected(exitStatus: 0) })
        #expect(await waitUntil { h.controller.tmux.state == .stopped })
    }

    @Test func aReconnectRestartsTheMonitorOnTheNewConnection() async {
        let h = Harness()
        await h.controller.connect()
        #expect(await waitUntil { h.controller.tmux.state == .live && h.controller.tmux.topology != nil })
        let first = h.factory.last!
        first.end(.io)
        #expect(await waitUntil { h.factory.attempts == 2 && h.controller.state == .connected })
        let second = h.factory.last!
        #expect(second !== first)
        #expect(await waitUntil { second.execStreamCommands.get.count == 1 && h.controller.tmux.state == .live })
        // the old channel was closed
        #expect(first.execStreams.get[0].closeCalls.get >= 1)
        await h.controller.disconnect()
    }

    @Test func actionsAreAvailableOnTheController() async throws {
        let h = Harness()
        await h.controller.connect()
        #expect(await waitUntil { h.controller.tmux.state == .live && h.controller.tmux.topology != nil })
        #expect(h.controller.tmuxActions.windows.count == 2)
        await h.controller.disconnect()
    }
}
