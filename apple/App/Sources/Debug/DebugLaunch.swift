#if DEBUG
import Foundation
import ShuaiApp
import ShuaiCore
import ShuaiTerminal

/// DEBUG-only launch arguments for scripted simulator runs (never compiled into Release):
///
/// - `-debugHostFile <path>`: JSON `{name, host, port, user, keyPath, [tmuxSession]}`. The key is
///   imported from that path on the Mac (the simulator can read host paths), a host profile is
///   created (or reused by name) and selected, which connects it.
/// - `-debugAutoAcceptHostKey`: answers the TOFU prompt with "trust" (scripted runs only).
/// - `-debugConnectionState <reconnecting|failed|disconnected>`: shows that connection state in the
///   views without a server (a fixed `ConnectionPresentation`; the session controller is untouched
///   and does not connect).
/// - `-debugSendAfterConnect <text>`: types `text` + Enter shortly after the session attaches.
/// - `-debugSidebarCollapsed`: starts with the sidebar collapsed (the window tab strip is shown).
/// - `-debugSingleWindow`: with the tmux fixture, a topology of one session with one window.
/// - `-debugNoticeTimeScale <n>`: notices last `n` times longer (default 1), so UI tests on a slow
///   runner can still find a transient notice.
enum DebugLaunch {
    private static let args = ProcessInfo.processInfo.arguments

    static func value(of flag: String) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    /// Fixed id of the fixture host, so UI tests can build `shuai://open?host=...` links for it.
    static let fixtureHostID = UUID(uuidString: "5B0F1C00-0000-4000-8000-00000000F1E1")!
    static func isFixtureHost(_ id: UUID) -> Bool { id == fixtureHostID && (args.contains("-debugTmuxFixture") || agentFixture) }

    static var agentFixture: Bool { args.contains("-debugAgentFixture") }
    static var autoAccept: Bool { args.contains("-debugAutoAcceptHostKey") }
    static var sendAfterConnect: String? { value(of: "-debugSendAfterConnect") }
    static var connectionState: String? { value(of: "-debugConnectionState") }

    /// `-debugNoticeTimeScale`: an integer >= 1, else 1.
    static var noticeTimeScale: UInt64 { value(of: "-debugNoticeTimeScale").flatMap(UInt64.init).map { max($0, 1) } ?? 1 }

    /// The notice clock slowed by `noticeTimeScale`: time advances `n` times slower, sleeps last `n` times longer.
    static func slowedNoticeTime(
        now: @escaping @Sendable () -> UInt64, sleep: @escaping @Sendable (UInt64) async throws -> Void
    ) -> (@Sendable () -> UInt64, @Sendable (UInt64) async throws -> Void) {
        let scale = min(noticeTimeScale, 1_000_000)
        guard scale > 1 else { return (now, sleep) }
        return ({ now() / scale }, { ms in try await sleep(ms.multipliedReportingOverflow(by: scale).partialValue) })
    }

    /// The presentation shown instead of the controller's, or nil without `-debugConnectionState`.
    static func connectionPresentation(hostName: String, target: String) -> ConnectionPresentation? {
        let state: SessionState
        switch connectionState {
        case "reconnecting": state = .reconnecting(attempt: 2, nextRetryAt: Date().addingTimeInterval(3600))
        case "failed": state = .failed(SessionError(kind: .network, message: "Connection refused"))
        case "disconnected": state = .disconnected(exitStatus: 0)
        default: return nil
        }
        return ConnectionPresentation.make(state, hostName: hostName, target: target)
    }

    private struct HostFile: Decodable {
        var name: String
        var host: String
        var port: Int?
        var user: String
        var keyPath: String
        var tmuxSession: String?
        var tmuxArgs: String?
    }

    @MainActor
    static func applyIfRequested(model: AppModel) async {
        applyTmuxFixtureIfRequested(model: model)
        if args.contains("-debugSidebarCollapsed") {
            // After the first layout: the split view resets its visibility while it first appears.
            try? await Task.sleep(for: .milliseconds(500))
            model.columnVisibility = .detailOnly
        }
        guard let path = value(of: "-debugHostFile") else { return }
        do {
            let file = try JSONDecoder().decode(HostFile.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
            let keyData = try Data(contentsOf: URL(fileURLWithPath: file.keyPath))
            let keyName = "debug-\(file.name)"
            let key = try model.keys.items.first { $0.name == keyName }
                ?? model.keys.importKey(data: keyData, name: keyName, passphrase: nil)
            var profile = model.hosts.hosts.first { $0.name == file.name }
                ?? HostProfile(name: file.name, host: file.host, username: file.user)
            profile.host = file.host
            profile.port = file.port ?? 22
            profile.username = file.user
            profile.auth = .key(keyID: key.id)
            TmuxLaunch.debugArgs = file.tmuxArgs.map { " " + $0 } ?? ""
            profile.tmux = TmuxPrefs(enabled: true, sessionName: file.tmuxSession ?? "shuai-sim-test")
            if model.hosts.host(id: profile.id) == nil { try model.hosts.add(profile) } else { try model.hosts.update(profile) }
            model.selection = profile.id
            NSLog("[debug] host \(profile.name) ready, selected")
        } catch {
            NSLog("[debug] -debugHostFile failed: \(error)")
        }
    }

    /// `-debugTmuxFixture`: a host whose tmux tree is a made-up topology (no server involved), for UI tests.
    @MainActor
    static func applyTmuxFixtureIfRequested(model: AppModel) {
        guard args.contains("-debugTmuxFixture") || agentFixture else { return }
        var profile = HostProfile(id: fixtureHostID, name: "fixture-host", host: "example.invalid", username: "alice")
        profile.tmux = TmuxPrefs(enabled: true, sessionName: "main")
        if model.hosts.host(id: profile.id) == nil { try? model.hosts.add(profile) }
        func pane(_ id: String, _ i: UInt32, _ active: Bool, _ cmd: String) -> FfiTmuxPane {
            FfiTmuxPane(id: id, index: i, active: active, currentCommand: cmd, currentPath: "/work/app", pid: 1, tty: "", title: "", width: 80, height: 24)
        }
        let main = FfiTmuxSession(id: "$0", name: "main", attached: 1, windows: [
            FfiTmuxWindow(id: "@0", index: 1, name: "shell", active: false, flags: "-", panes: [pane("%0", 0, true, "zsh")]),
            FfiTmuxWindow(id: "@1", index: 2, name: "claude", active: true, flags: "*", panes: [
                pane("%1", 0, false, "claude"), pane("%2", 1, true, "vim"),
            ]),
        ])
        let other = FfiTmuxSession(id: "$1", name: "scratch", attached: 0, windows: [
            FfiTmuxWindow(id: "@5", index: 0, name: "logs", active: true, flags: "*", panes: [pane("%5", 0, true, "tail")]),
        ])
        let single = args.contains("-debugSingleWindow")
        let only = FfiTmuxSession(id: "$0", name: "main", attached: 1, windows: [
            FfiTmuxWindow(id: "@1", index: 1, name: "claude", active: true, flags: "*", panes: [pane("%1", 0, true, "claude")]),
        ])
        model.sessions.controller(for: profile).tmux.debugSeed(
            topology: FfiTopology(sessions: single ? [only] : [main, other]), viewedSessionID: "$0")
        model.selection = profile.id
        if agentFixture {
            let remote = FixtureAgentRemote()
            fixtureRemote = remote
            Task { await model.agentHub.hostConnected(id: profile.id, remote: remote) }
        }
    }

    /// `-debugAgentFixture`: fake terminal content (no server, no real data) with a prompt on the last row.
    @MainActor
    static func seedFixtureTerminal(_ engine: GhosttyEngine) async {
        for _ in 0 ..< 60 where !engine.gridSize.isValid { try? await Task.sleep(for: .milliseconds(50)) }
        try? await Task.sleep(for: .milliseconds(1200))  // let the first layout settle
        let rows = max(engine.gridSize.rows, 10)
        var text = "\u{1B}[2J\u{1B}[H"
        let lines = [
            "$ swift build", "Compiling ShuaiApp (42 files)", "Build complete! (12.3s)", "$ claude",
            "\u{1B}[38;5;208m\u{25CF}\u{1B}[0m Refactor the session store", "  \u{23BF} Read(Sources/Store.swift)",
            "  \u{23BF} Bash(rm -rf build && swift build)",
        ]
        for l in lines { text += l + "\r\n" }
        text += "\u{1B}[\(rows);1H\u{1B}[1m\u{276F}\u{1B}[0m "
        engine.feed(Data(text.utf8))
    }

    @MainActor static var fixtureRemote: FixtureAgentRemote?

    @MainActor
    static func autoAnswer(controller: SessionController) async {
        guard autoAccept, case .hostKey(let challenge)? = controller.pendingPrompt else { return }
        NSLog("[debug] auto-accepting host key \(challenge.fingerprint)")
        controller.answerHostKey(accept: true)
    }

    @MainActor
    static func sendAfterConnect(controller: SessionController) async {
        guard controller.state == .connected, let text = sendAfterConnect else { return }
        // Give tmux a moment to draw before typing.
        try? await Task.sleep(for: .seconds(2.5))
        guard controller.state == .connected, !sentOnce else { return }
        sentOnce = true
        NSLog("[debug] sending after connect: \(text)")
        controller.sendInput(text + "\r")
    }

    @MainActor private static var sentOnce = false
}

extension AppModel {
    /// Fixture hosts have no server: a deep link selects the pane in the made-up topology instead
    /// (the real parsing, host lookup and pane-exists check have already run).
    func debugNavigate(host: HostProfile, pane: String?) -> PaneNavigationResult {
        selection = host.id
        guard let pane else { return .opened }
        let monitor = sessions.controller(for: host).tmux
        guard var topology = monitor.topology,
            let si = topology.sessions.firstIndex(where: { $0.windows.contains { $0.panes.contains { $0.id == pane } } })
        else { return .paneNotFound }
        let wi = topology.sessions[si].windows.firstIndex { $0.panes.contains { $0.id == pane } }!
        for i in topology.sessions[si].windows.indices { topology.sessions[si].windows[i].active = i == wi }
        for pi in topology.sessions[si].windows[wi].panes.indices {
            topology.sessions[si].windows[wi].panes[pi].active = topology.sessions[si].windows[wi].panes[pi].id == pane
        }
        monitor.debugSeed(topology: topology, viewedSessionID: topology.sessions[si].id)
        agentHub.markSeen(profileID: host.id, paneID: pane)
        return .opened
    }
}
#endif
