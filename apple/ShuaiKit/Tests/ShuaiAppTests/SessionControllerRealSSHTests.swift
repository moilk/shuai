#if SHUAI_TESTKIT
import Foundation
import Testing
import ShuaiCore
import ShuaiPlatform
import ShuaiTerminal
@testable import ShuaiApp

/// SessionController against the in-process russh testkit server over a real TCP connection.
@MainActor @Suite(.timeLimit(.minutes(1))) struct SessionControllerRealSSHTests {
    private func makeController(
        _ server: TestServer, tmux: Bool = false, password: String? = nil
    ) -> (SessionController, FakeEngine, KnownHostsStore) {
        var profile = HostProfile(name: "local", host: "127.0.0.1", port: Int(server.port()), username: server.username(), auth: .password)
        profile.tmux.enabled = tmux
        let engine = FakeEngine()
        let passwords = InMemoryPasswordStore()
        try? passwords.setPassword(password ?? server.password(), for: profile.id)
        let known = KnownHostsStore(fileURL: scratchURL("known_hosts"))
        let c = SessionController(
            profile: profile, engine: engine, factory: LiveConnectionFactory(), keys: InMemoryKeyStore(),
            passwords: passwords, knownHosts: known)
        return (c, engine, known)
    }

    @Test func connectsTypesAndReceivesCJKEchoThenResizes() async throws {
        let server = await startTestSshServer()
        let (c, engine, known) = makeController(server)
        engine.gridSize = TerminalGridSize(cols: 100, rows: 30)
        let task = Task { @MainActor in await c.connect() }
        #expect(await waitUntil { c.pendingPrompt != nil })
        guard case .hostKey(let challenge) = c.pendingPrompt else { Issue.record("no host key prompt"); return }
        #expect(challenge.fingerprint == (try publicKeyFingerprint(publicKeyLine: server.hostPublicKeyLine())))
        c.answerHostKey(accept: true)
        await task.value
        #expect(c.state == .connected)
        #expect(try known.check(host: "127.0.0.1", port: server.port(), publicKeyLine: server.hostPublicKeyLine()) == .trusted)

        engine.onInput?(Data("echo 你好 ✓\r".utf8))
        #expect(await waitUntil { engine.fedText.contains("echo 你好 ✓") })

        engine.onResize?(TerminalGridSize(cols: 120, rows: 40))
        #expect(await waitUntil { engine.fedText.contains("RESIZE 120 40") })

        await c.disconnect()
        #expect(c.state == .disconnected(exitStatus: nil))
    }

    @Test func serverSideExitIsReportedWithItsStatus() async throws {
        let server = await startTestSshServer()
        let (c, engine, known) = makeController(server)
        try known.add(host: "127.0.0.1", port: server.port(), publicKeyLine: server.hostPublicKeyLine())
        await c.connect()
        #expect(c.state == .connected)
        engine.onInput?(Data("EXIT3".utf8))
        #expect(await waitUntil { c.state == .disconnected(exitStatus: 3) })
    }

    @Test func missingTmuxOnTheServerFallsBackToAPlainShell() async throws {
        // The testkit answers unknown exec commands (like `tmux new -A ...`) with exit status 127.
        let server = await startTestSshServer()
        let (c, engine, known) = makeController(server, tmux: true)
        try known.add(host: "127.0.0.1", port: server.port(), publicKeyLine: server.hostPublicKeyLine())
        await c.connect()
        #expect(await waitUntil { c.notice == SessionController.tmuxMissingNotice })
        #expect(c.state == .connected)
        engine.onInput?(Data("hello\r".utf8))
        #expect(await waitUntil { engine.fedText.contains("hello") })
        await c.disconnect()
    }

    @Test func askHostGetsTheHostKeyPromptBeforeThePasswordPrompt() async throws {
        let server = await startTestSshServer()
        var profile = HostProfile(name: "local", host: "127.0.0.1", port: Int(server.port()), username: server.username(), auth: .ask)
        profile.tmux.enabled = false
        let c = SessionController(
            profile: profile, engine: FakeEngine(), factory: LiveConnectionFactory(), keys: InMemoryKeyStore(),
            passwords: InMemoryPasswordStore(), knownHosts: KnownHostsStore(fileURL: scratchURL("known_hosts")))
        let task = Task { @MainActor in await c.connect() }
        #expect(await waitUntil { c.pendingPrompt != nil })
        guard case .hostKey = c.pendingPrompt else { Issue.record("host key must come first"); return }
        c.answerHostKey(accept: true)
        #expect(await waitUntil { c.pendingPrompt == .password(host: "127.0.0.1", username: server.username()) })
        c.answerPassword(server.password())
        await task.value
        #expect(c.state == .connected)
        await c.disconnect()
    }

    @Test func wrongPasswordFailsWithAuthFailed() async throws {
        let server = await startTestSshServer()
        let (c, _, known) = makeController(server, password: "wrong")
        try known.add(host: "127.0.0.1", port: server.port(), publicKeyLine: server.hostPublicKeyLine())
        await c.connect()
        guard case .failed(let e) = c.state else { Issue.record("expected failed, got \(c.state)"); return }
        #expect(e.kind == .authFailed)
    }
}
#endif
