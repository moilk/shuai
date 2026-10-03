import Foundation
import Testing
import ShuaiCore
import ShuaiPlatform
import ShuaiTerminal
@testable import ShuaiApp

private let host = "dev.example.com"

private func newHostKey() -> String { try! generateKey(alg: .ed25519, comment: "").publicLine }

private func verify(_ verifier: HostKeyVerifierCallback, _ line: String) async throws {
    guard await verifier.verify(host: host, port: 22, publicKeyLine: line) else { throw FfiSshError.HostKeyRejected }
}

/// Mimics the SSH layer's order: host key verification during the handshake, then the auth
/// methods in order (a lazy password prompt is only asked after the key was accepted).
private func handshake(_ config: FfiConnectConfig, _ verifier: HostKeyVerifierCallback, key: String) async throws {
    try await verify(verifier, key)
    for method in config.auth {
        switch method {
        case .password: return
        case .passwordPrompt(let prompter):
            guard await prompter.password() != nil else { throw FfiSshError.AuthFailed(triedMethods: ["password"]) }
            return
        default: continue
        }
    }
}

@MainActor
private struct Harness {
    let engine = FakeEngine()
    let factory: FakeFactory
    let keys = InMemoryKeyStore()
    let passwords = InMemoryPasswordStore()
    let knownHosts = KnownHostsStore(fileURL: scratchURL("known_hosts"))
    let controller: SessionController
    let profile: HostProfile

    init(
        profile: HostProfile = HostProfile(name: "dev", host: host, username: "alice", auth: .password),
        maxAttempts: UInt32? = 3,
        sleep: @escaping @Sendable (UInt64) async throws -> Void = { _ in await Task.yield() },
        factory: FakeFactory = FakeFactory()
    ) {
        self.profile = profile
        self.factory = factory
        let keys = keys, passwords = passwords, knownHosts = knownHosts
        controller = SessionController(
            profile: profile, engine: engine, factory: factory, keys: keys, passwords: passwords,
            knownHosts: knownHosts,
            makePolicy: { ReconnectPolicy(maxAttempts: maxAttempts, jitter: false) },
            sleep: sleep, redrawNudgeDelay: .milliseconds(1))
        try? passwords.setPassword("pw", for: profile.id)
    }

    /// Connect in the background so the test can answer prompts.
    func connectInBackground() -> Task<Void, Never> {
        let c = controller
        return Task { @MainActor in await c.connect() }
    }
}

@MainActor @Suite(.timeLimit(.minutes(1))) struct SessionControllerTests {
    // MARK: connect + auth

    @Test func connectsWithStoredPasswordAndTrustedHost() async {
        let key = newHostKey()
        let h = Harness(factory: FakeFactory { _, _, v, _ in try await verify(v, key) })
        try? h.knownHosts.add(host: host, port: 22, publicKeyLine: key)
        await h.controller.connect()
        #expect(h.controller.state == .connected)
        #expect(h.controller.pendingPrompt == nil)
        #expect(h.controller.stateLog == [.idle, .connecting, .authenticating, .connected])
        let cfg = h.factory.configs.get[0]
        #expect(cfg.host == host && cfg.port == 22 && cfg.username == "alice")
        guard case .password(let pw) = cfg.auth.first else { Issue.record("no password auth"); return }
        #expect(pw == "pw")
    }

    @Test func unknownHostPromptsWithFingerprintThenRemembersOnAccept() async throws {
        let key = newHostKey()
        let h = Harness(factory: FakeFactory { _, _, v, _ in try await verify(v, key) })
        let task = h.connectInBackground()
        #expect(await waitUntil { h.controller.pendingPrompt != nil })
        guard case .hostKeyPrompt(let challenge) = h.controller.state, case .hostKey(let p) = h.controller.pendingPrompt else {
            Issue.record("expected hostKeyPrompt, got \(h.controller.state)"); return
        }
        #expect(p == challenge)
        #expect(challenge.kind == .unknown)
        #expect(challenge.fingerprint.hasPrefix("SHA256:"))
        #expect(challenge.fingerprint == (try publicKeyFingerprint(publicKeyLine: key)))
        h.controller.answerHostKey(accept: true)
        await task.value
        #expect(h.controller.state == .connected)
        #expect(try h.knownHosts.check(host: host, port: 22, publicKeyLine: key) == .trusted)
        #expect(h.controller.stateLog.contains(.authenticating))
    }

    @Test func rejectingUnknownHostFailsAndStoresNothing() async throws {
        let key = newHostKey()
        let h = Harness(factory: FakeFactory { _, _, v, _ in try await verify(v, key) })
        let task = h.connectInBackground()
        #expect(await waitUntil { h.controller.pendingPrompt != nil })
        h.controller.answerHostKey(accept: false)
        await task.value
        #expect(h.controller.state == .failed(SessionError(kind: .hostKeyRejected, message: SessionError.hostKeyRejectedMessage)))
        #expect(try h.knownHosts.check(host: host, port: 22, publicKeyLine: key) == .unknown)
    }

    @Test func changedHostKeyShowsBothFingerprintsAndRejectingKeepsOldKey() async throws {
        let old = newHostKey(), new = newHostKey()
        let h = Harness(factory: FakeFactory { _, _, v, _ in try await verify(v, new) })
        try h.knownHosts.add(host: host, port: 22, publicKeyLine: old)
        let task = h.connectInBackground()
        #expect(await waitUntil { h.controller.pendingPrompt != nil })
        guard case .hostKey(let challenge) = h.controller.pendingPrompt else { Issue.record("no prompt"); return }
        #expect(challenge.kind == .changed(expectedFingerprints: [try publicKeyFingerprint(publicKeyLine: old)]))
        #expect(challenge.fingerprint == (try publicKeyFingerprint(publicKeyLine: new)))
        h.controller.answerHostKey(accept: false) // the default / safe answer
        await task.value
        guard case .failed(let e) = h.controller.state else { Issue.record("expected failed"); return }
        #expect(e.kind == .hostKeyRejected)
        #expect(try h.knownHosts.check(host: host, port: 22, publicKeyLine: old) == .trusted)
    }

    @Test func acceptingChangedKeyReplacesTheEntry() async throws {
        let old = newHostKey(), new = newHostKey()
        let h = Harness(factory: FakeFactory { _, _, v, _ in try await verify(v, new) })
        try h.knownHosts.add(host: host, port: 22, publicKeyLine: old)
        let task = h.connectInBackground()
        #expect(await waitUntil { h.controller.pendingPrompt != nil })
        h.controller.answerHostKey(accept: true)
        await task.value
        #expect(h.controller.state == .connected)
        #expect(try h.knownHosts.check(host: host, port: 22, publicKeyLine: new) == .trusted)
    }

    @Test func askAuthAsksForTheHostKeyBeforeThePassword() async {
        let key = newHostKey()
        let profile = HostProfile(name: "d", host: host, username: "alice", auth: .ask)
        let h = Harness(profile: profile, factory: FakeFactory { _, c, v, _ in try await handshake(c, v, key: key) })
        try? h.passwords.deletePassword(for: profile.id)
        let task = h.connectInBackground()
        #expect(await waitUntil { h.controller.pendingPrompt != nil })
        // Unknown host: the TOFU decision comes first and no password was requested yet.
        guard case .hostKey = h.controller.pendingPrompt else { Issue.record("expected host key first, got \(String(describing: h.controller.pendingPrompt))"); return }
        for method in h.factory.configs.get[0].auth { if case .password = method { Issue.record("password handed over before the host key was verified") } }
        h.controller.answerHostKey(accept: true)
        #expect(await waitUntil { h.controller.pendingPrompt == .password(host: host, username: "alice") })
        #expect(h.controller.state == .authenticating)
        h.controller.answerPassword("s3cret")
        await task.value
        #expect(h.controller.state == .connected)
        #expect((try? h.passwords.password(for: profile.id)) == nil) // .ask never stores
    }

    @Test func rejectingTheHostKeyNeverPromptsForAPassword() async {
        let key = newHostKey()
        let profile = HostProfile(name: "d", host: host, username: "alice", auth: .ask)
        let h = Harness(profile: profile, factory: FakeFactory { _, c, v, _ in try await handshake(c, v, key: key) })
        try? h.passwords.deletePassword(for: profile.id)
        let task = h.connectInBackground()
        #expect(await waitUntil { h.controller.pendingPrompt != nil })
        h.controller.answerHostKey(accept: false)
        await task.value
        guard case .failed(let e) = h.controller.state else { Issue.record("expected failed, got \(h.controller.state)"); return }
        #expect(e.kind == .hostKeyRejected)
        #expect(!h.controller.stateLog.contains(.authenticating))
        #expect(h.controller.pendingPrompt == nil)
    }

    @Test func cancellingThePasswordPromptEndsDisconnected() async {
        let key = newHostKey()
        let profile = HostProfile(name: "d", host: host, username: "alice", auth: .ask)
        let h = Harness(profile: profile, factory: FakeFactory { _, c, v, _ in try await handshake(c, v, key: key) })
        try? h.knownHosts.add(host: host, port: 22, publicKeyLine: key)
        try? h.passwords.deletePassword(for: profile.id)
        let task = h.connectInBackground()
        #expect(await waitUntil { h.controller.pendingPrompt != nil })
        h.controller.answerPassword(nil)
        await task.value
        #expect(h.controller.state == .disconnected(exitStatus: nil))
        #expect(h.factory.last?.disconnects.get ?? 0 == 0)
    }

    @Test func missingStoredPasswordFallsBackToPromptAfterTheHostKey() async {
        let key = newHostKey()
        let profile = HostProfile(name: "d", host: host, username: "alice", auth: .password)
        let h = Harness(profile: profile, factory: FakeFactory { _, c, v, _ in try await handshake(c, v, key: key) })
        try? h.passwords.deletePassword(for: profile.id)
        let task = h.connectInBackground()
        #expect(await waitUntil { h.controller.pendingPrompt != nil })
        guard case .hostKey = h.controller.pendingPrompt else { Issue.record("expected host key first"); return }
        h.controller.answerHostKey(accept: true)
        #expect(await waitUntil { h.controller.pendingPrompt == .password(host: host, username: "alice") })
        h.controller.answerPassword("typed")
        await task.value
        #expect(h.controller.state == .connected)
    }

    @Test func storedPasswordIsStillHandedOverDirectly() async {
        let key = newHostKey()
        let h = Harness(factory: FakeFactory { _, c, v, _ in try await handshake(c, v, key: key) })
        try? h.knownHosts.add(host: host, port: 22, publicKeyLine: key)
        await h.controller.connect()
        guard case .password(let pw) = h.factory.configs.get[0].auth.first else { Issue.record("no stored password"); return }
        #expect(pw == "pw")
    }

    @Test func askPasswordIsForgottenOnUserDisconnect() async {
        let key = newHostKey()
        let profile = HostProfile(name: "d", host: host, username: "alice", auth: .ask)
        let h = Harness(profile: profile, factory: FakeFactory { _, c, v, _ in try await handshake(c, v, key: key) })
        try? h.knownHosts.add(host: host, port: 22, publicKeyLine: key)
        try? h.passwords.deletePassword(for: profile.id)
        var task = h.connectInBackground()
        #expect(await waitUntil { h.controller.pendingPrompt != nil })
        h.controller.answerPassword("s3cret")
        await task.value
        await h.controller.disconnect()
        task = h.connectInBackground()
        #expect(await waitUntil { h.controller.pendingPrompt == .password(host: host, username: "alice") })
        h.controller.answerPassword(nil)
        await task.value
    }

    @Test func aRejectedAskPasswordIsNotReusedOnTheNextAttempt() async {
        let key = newHostKey()
        let profile = HostProfile(name: "d", host: host, username: "alice", auth: .ask)
        let h = Harness(profile: profile, factory: FakeFactory { n, c, v, _ in
            try await handshake(c, v, key: key)
            if n == 1 { throw FfiSshError.AuthFailed(triedMethods: ["password"]) }
        })
        try? h.knownHosts.add(host: host, port: 22, publicKeyLine: key)
        try? h.passwords.deletePassword(for: profile.id)
        var task = h.connectInBackground()
        #expect(await waitUntil { h.controller.pendingPrompt != nil })
        h.controller.answerPassword("wrong")
        await task.value
        guard case .failed = h.controller.state else { Issue.record("expected failed"); return }
        task = h.connectInBackground()
        #expect(await waitUntil { h.controller.pendingPrompt == .password(host: host, username: "alice") })
        h.controller.answerPassword("right")
        await task.value
        #expect(h.controller.state == .connected)
    }

    @Test func keyAuthUsesPemFromKeyStore() async throws {
        let key = newHostKey()
        let material = try generateKey(alg: .ed25519, comment: "")
        let profile = HostProfile(name: "d", host: host, username: "alice", auth: .key(keyID: "k1"))
        let h = Harness(profile: profile, factory: FakeFactory { _, _, v, _ in try await verify(v, key) })
        try h.keys.save(privatePem: material.privatePem, record: KeyRecord(id: "k1", name: "k", material: material))
        try h.knownHosts.add(host: host, port: 22, publicKeyLine: key)
        await h.controller.connect()
        #expect(h.controller.state == .connected)
        guard case .privateKeyPem(let pem) = h.factory.configs.get[0].auth.first else { Issue.record("no key auth"); return }
        #expect(pem == material.privatePem)
    }

    @Test func missingKeyFailsWithoutConnecting() async {
        let profile = HostProfile(name: "d", host: host, username: "alice", auth: .key(keyID: "gone"))
        let h = Harness(profile: profile)
        await h.controller.connect()
        guard case .failed(let e) = h.controller.state else { Issue.record("expected failed"); return }
        #expect(e.kind == .keyMissing)
        #expect(h.factory.attempts == 0)
    }

    @Test func keyboardInteractivePromptsSurfaceToUI() async throws {
        let key = newHostKey()
        let answers = Locked<[String]?>(nil)
        let factory = FakeFactory { _, config, v, _ in
            try await verify(v, key)
            for case .keyboardInteractive(let prompter) in config.auth {
                let r = await prompter.respond(
                    name: "otp", instructions: "enter code", prompts: [FfiKbdPrompt(prompt: "Code: ", echo: false)])
                answers.with { $0 = r }
            }
        }
        let h = Harness(factory: factory)
        try h.knownHosts.add(host: host, port: 22, publicKeyLine: key)
        let task = h.connectInBackground()
        #expect(await waitUntil { if case .keyboardInteractive = h.controller.pendingPrompt { true } else { false } })
        guard case .keyboardInteractive(let name, let instr, let prompts) = h.controller.pendingPrompt else { return }
        #expect(name == "otp" && instr == "enter code")
        #expect(prompts == [FfiKbdPrompt(prompt: "Code: ", echo: false)])
        h.controller.answerKeyboardInteractive(["123456"])
        await task.value
        #expect(answers.get == ["123456"])
        #expect(h.controller.state == .connected)
    }

    @Test func authFailureSurfacesAsFailed() async {
        let key = newHostKey()
        let h = Harness(factory: FakeFactory { _, _, v, _ in
            try await verify(v, key)
            throw FfiSshError.AuthFailed(triedMethods: ["password"])
        })
        try? h.knownHosts.add(host: host, port: 22, publicKeyLine: key)
        await h.controller.connect()
        guard case .failed(let e) = h.controller.state else { Issue.record("expected failed"); return }
        #expect(e.kind == .authFailed)
        // Retry is possible.
        await h.controller.connect()
        #expect(h.factory.attempts == 2)
    }

    // MARK: opening the PTY

    @Test func opensTmuxDirectlyOnAPtySizedToTheGrid() async {
        let h = Harness()
        h.engine.gridSize = TerminalGridSize(cols: 132, rows: 43)
        await h.controller.connect()
        let opens = h.factory.last!.opens.get
        #expect(opens == [.ptyExec(
            command: "tmux new -A -s 'shuai'", cols: 132, rows: 43, term: "xterm-256color",
            env: [FfiEnvVar(name: "COLORTERM", value: "truecolor"), FfiEnvVar(name: "LANG", value: "en_US.UTF-8")])])
        #expect(h.factory.last!.shell.writes.get.isEmpty) // nothing typed into the shell
    }

    @Test func plainShellWhenTmuxDisabledAndStartupCommandIsTyped() async {
        var p = HostProfile(name: "d", host: host, username: "alice", auth: .password)
        p.tmux.enabled = false
        p.startupCommand = "claude"
        let h = Harness(profile: p)
        h.engine.gridSize = TerminalGridSize(cols: 90, rows: 20)
        await h.controller.connect()
        guard case .shell(let cols, let rows, let term, _) = h.factory.last!.opens.get[0] else { Issue.record("not a plain shell"); return }
        #expect(cols == 90 && rows == 20 && term == "xterm-256color")
        #expect(await waitUntil { h.factory.last!.shell.writtenText == "claude\r" })
    }

    @Test func fallsBackTo80x24BeforeFirstLayout() async {
        let h = Harness()
        h.engine.gridSize = TerminalGridSize(cols: 0, rows: 0)
        await h.controller.connect()
        guard case .ptyExec(_, let cols, let rows, _, _) = h.factory.last!.opens.get[0] else { return }
        #expect(cols == 80 && rows == 24)
    }

    @Test func shellOpenFailureFails() async {
        let factory = FakeFactory { _, _, _, conn in conn.openError = FfiSshError.ChannelClosed }
        let h = Harness(factory: factory)
        await h.controller.connect()
        guard case .failed = h.controller.state else { Issue.record("expected failed, got \(h.controller.state)"); return }
        #expect(h.factory.last!.disconnects.get == 1)
    }

    // MARK: terminal wiring

    @Test func remoteBytesGoToEngineAndTypedBytesGoToShellInOrder() async {
        let h = Harness()
        await h.controller.connect()
        let shell = h.factory.last!.shell
        shell.emit("你好 ✓\r\n")
        #expect(await waitUntil { h.engine.fedText == "你好 ✓\r\n" })
        for i in 0 ..< 20 { h.engine.onInput?(Data("k\(i);".utf8)) }
        #expect(await waitUntil { shell.writes.get.count == 20 })
        #expect(shell.writtenText == (0 ..< 20).map { "k\($0);" }.joined())
    }

    @Test func engineResizeIsForwardedToTheShell() async {
        let h = Harness()
        await h.controller.connect()
        h.engine.onResize?(TerminalGridSize(cols: 120, rows: 40))
        #expect(await waitUntil { h.factory.last!.shell.resizes.get == [TerminalGridSize(cols: 120, rows: 40)] })
    }

    @Test func titleNotificationAndClipboardAreSurfaced() async {
        let h = Harness()
        await h.controller.connect()
        h.engine.onTitleChange?("claude — repo")
        #expect(h.controller.title == "claude — repo")
        #expect(h.controller.windowTitle == "claude — repo")
        h.engine.onNotification?(TerminalNotification(title: "Claude", body: "done"))
        #expect(h.controller.banner == TerminalNotification(title: "Claude", body: "done"))
        h.controller.dismissBanner()
        #expect(h.controller.banner == nil)

        let answered = Locked<Bool?>(nil)
        h.engine.onClipboardRequest?(ClipboardRequest(contents: "rm -rf", kind: .osc52Write) { allow in answered.with { $0 = allow } })
        #expect(h.controller.pendingClipboard?.contents == "rm -rf")
        h.controller.pendingClipboard?.respond(allow: false)
        #expect(answered.get == false)
    }

    @Test func windowTitleFallsBackToProfileName() async {
        let h = Harness()
        #expect(h.controller.windowTitle == "dev")
    }

    // MARK: exit and drop

    @Test func shellExitMovesToDisconnectedWithStatusAndDoesNotReconnect() async {
        let h = Harness()
        await h.controller.connect()
        let shell = h.factory.last!.shell
        shell.emit(.exit(status: 3, signal: nil))
        shell.emit(.closed(reason: .remote))
        #expect(await waitUntil { h.controller.state == .disconnected(exitStatus: 3) })
        #expect(h.factory.attempts == 1)
    }

    @Test func userDisconnectClosesEverythingAndStaysDisconnected() async {
        let h = Harness()
        await h.controller.connect()
        await h.controller.disconnect()
        #expect(h.controller.state == .disconnected(exitStatus: nil))
        #expect(h.factory.last!.disconnects.get == 1)
        try? await Task.sleep(for: .milliseconds(30))
        #expect(h.factory.attempts == 1)
        #expect(h.controller.state == .disconnected(exitStatus: nil))
    }

    @Test func dropReconnectsReattachesTmuxAndKeepsTerminalContents() async {
        let h = Harness()
        h.engine.gridSize = TerminalGridSize(cols: 100, rows: 30)
        await h.controller.connect()
        let first = h.factory.last!
        first.shell.emit("before drop")
        #expect(await waitUntil { h.engine.fedText == "before drop" })

        first.shell.emit(.closed(reason: .keepaliveTimeout))
        first.end(.keepaliveTimeout)
        #expect(await waitUntil { h.factory.attempts == 2 && h.controller.state == .connected })
        #expect(h.controller.stateLog.contains(.reconnecting(attempt: 1, nextRetryAt: nil)))
        let second = h.factory.last!
        #expect(second !== first)
        // Reattached through tmux, sized to the current grid, and nudged to force a full redraw.
        guard case .ptyExec(let cmd, _, _, _, _) = second.opens.get[0] else { Issue.record("not tmux"); return }
        #expect(cmd == "tmux new -A -s 'shuai'")
        #expect(await waitUntil { second.shell.resizes.get.count == 2 })
        #expect(second.shell.resizes.get == [TerminalGridSize(cols: 100, rows: 29), TerminalGridSize(cols: 100, rows: 30)])
        // Old output is still on screen; fresh output keeps flowing and input works again.
        second.shell.emit(" after")
        #expect(await waitUntil { h.engine.fedText == "before drop after" })
        h.engine.onInput?(Data("x".utf8))
        #expect(await waitUntil { second.shell.writtenText == "x" })
        #expect(first.disconnects.get == 1) // the dead connection was torn down
    }

    @Test func connectionLossWithoutShellEventAlsoReconnects() async {
        let h = Harness()
        await h.controller.connect()
        h.factory.last!.end(.io)
        #expect(await waitUntil { h.factory.attempts == 2 && h.controller.state == .connected })
    }

    @Test func backoffExposesAttemptAndNextRetryTimeThenGivesUp() async {
        let attemptsSeen = Locked<[SessionState]>([])
        let factory = FakeFactory { n, _, _, _ in
            if n > 1 { throw FfiSshError.Connect(message: "no route") }
        }
        let now = Date(timeIntervalSince1970: 1000)
        let h = Harness(maxAttempts: 3, sleep: { _ in await Task.yield() }, factory: factory)
        await h.controller.connect()
        h.factory.last!.end(.io)
        #expect(await waitUntil { if case .failed = h.controller.state { true } else { false } })
        _ = (attemptsSeen, now)
        let log = h.controller.stateLog
        let backoffs = log.compactMap { s -> (Int, Date?)? in
            if case .reconnecting(let a, let t) = s { (a, t) } else { nil }
        }
        #expect(backoffs.contains { $0.0 == 1 && $0.1 == nil }) // attempt in flight
        #expect(backoffs.contains { $0.1 != nil })              // waiting, with a retry deadline
        guard case .failed(let e) = h.controller.state else { return }
        #expect(e.kind == .network)
        #expect(h.factory.attempts == 3) // initial + 2 retries
    }

    @Test func authFailureWhileReconnectingStopsRetrying() async {
        let factory = FakeFactory { n, _, _, _ in
            if n > 1 { throw FfiSshError.AuthFailed(triedMethods: ["password"]) }
        }
        let h = Harness(maxAttempts: nil, factory: factory)
        await h.controller.connect()
        h.factory.last!.end(.io)
        #expect(await waitUntil { if case .failed = h.controller.state { true } else { false } })
        #expect(h.factory.attempts == 2)
    }

    @Test func retryNowSkipsTheBackoffAndCancelStopsReconnecting() async {
        let sleeping = Locked(0)
        let factory = FakeFactory { n, _, _, _ in
            if n == 2 { throw FfiSshError.Connect(message: "down") }
        }
        // Backoff sleeps "forever" until cancelled.
        let h = Harness(maxAttempts: nil, sleep: { _ in
            sleeping.with { $0 += 1 }
            try await Task.sleep(for: .seconds(3600))
        }, factory: factory)
        await h.controller.connect()
        h.factory.last!.end(.io)
        #expect(await waitUntil { sleeping.get == 1 })
        guard case .reconnecting(let attempt, let retryAt) = h.controller.state else { Issue.record("expected reconnecting, got \(h.controller.state)"); return }
        #expect(attempt >= 1 && retryAt != nil)

        h.controller.retryNow() // attempt 2 fails, backs off again
        #expect(await waitUntil { h.factory.attempts == 2 && sleeping.get == 2 })
        h.controller.retryNow() // attempt 3 succeeds
        #expect(await waitUntil { h.factory.attempts == 3 && h.controller.state == .connected })

        // Drop again, then give up manually.
        h.factory.last!.end(.io)
        #expect(await waitUntil { sleeping.get == 3 })
        await h.controller.cancelReconnect()
        #expect(h.controller.state == .disconnected(exitStatus: nil))
        let attemptsAfterCancel = h.factory.attempts
        try? await Task.sleep(for: .milliseconds(30))
        #expect(h.factory.attempts == attemptsAfterCancel)
    }

    @Test func networkChangeAndForegroundNudgeAStalledReconnect() async {
        let factory = FakeFactory { n, _, _, _ in
            if n == 2 { throw FfiSshError.Connect(message: "down") }
        }
        let sleeping = Locked(0)
        let h = Harness(maxAttempts: nil, sleep: { _ in
            sleeping.with { $0 += 1 }
            try await Task.sleep(for: .seconds(3600))
        }, factory: factory)
        await h.controller.connect()
        h.factory.last!.end(.io)
        #expect(await waitUntil { sleeping.get == 1 })
        h.controller.networkChanged() // attempt 2 fails and backs off again
        #expect(await waitUntil { h.factory.attempts == 2 && sleeping.get == 2 })
        h.controller.appForegrounded() // attempt 3 succeeds
        #expect(await waitUntil { h.factory.attempts == 3 && h.controller.state == .connected })
    }

    @Test func manualReconnectFromFailedConnectsAgain() async {
        let h = Harness(factory: FakeFactory { n, _, _, _ in
            if n == 1 { throw FfiSshError.Timeout }
        })
        await h.controller.connect()
        guard case .failed(let e) = h.controller.state else { Issue.record("expected failed"); return }
        #expect(e.kind == .timeout)
        await h.controller.reconnect()
        #expect(h.controller.state == .connected)
    }

    @Test func reconnectWhileConnectedReplacesTheConnection() async {
        let h = Harness()
        await h.controller.connect()
        let first = h.factory.last!
        await h.controller.reconnect()
        #expect(h.controller.state == .connected)
        #expect(h.factory.attempts == 2)
        #expect(first.disconnects.get == 1)
    }

    @Test func markConnectedCallbackFiresOnEveryAttach() async {
        let h = Harness()
        let count = Locked(0)
        h.controller.onConnected = { count.with { $0 += 1 } }
        await h.controller.connect()
        h.factory.last!.end(.io)
        #expect(await waitUntil { h.factory.attempts == 2 && h.controller.state == .connected })
        #expect(count.get == 2)
    }
}

@Suite struct SessionStatusTests {
    // MARK: tmux missing

    private func failTmux(_ conn: FakeConnection, status: Int32? = 127, text: String? = "bash: tmux: command not found\r\n") {
        let shell = conn.shell
        if let text { shell.emit(text) }
        if let status { shell.emit(.exit(status: UInt32(status), signal: nil)) }
        shell.emit(.closed(reason: .remote))
    }

    @Test func missingTmuxFallsBackToAPlainShellWithANotice() async {
        let h = Harness()
        await h.controller.connect()
        let conn = h.factory.last!
        failTmux(conn)
        #expect(await waitUntil { conn.opens.get.count == 2 })
        guard case .shell = conn.opens.get[1] else { Issue.record("fallback must be a plain shell"); return }
        #expect(await waitUntil { h.controller.notice != nil })
        #expect(h.controller.notice == SessionController.tmuxMissingNotice)
        #expect(SessionController.tmuxMissingNotice == "tmux not found on host \u{2014} using plain shell (sessions won't persist)")
        #expect(h.controller.state == .connected)
        #expect(h.factory.attempts == 1 && conn.disconnects.get == 0)
        h.controller.sendInput("ls\r")
        #expect(await waitUntil { conn.shell.writtenText == "ls\r" })
        conn.shell.emit("file\r\n")
        #expect(await waitUntil { h.engine.fedText.contains("file") })
        h.controller.dismissNotice()
        #expect(h.controller.notice == nil)
    }

    @Test func exitStatus127AloneTriggersTheFallback() async {
        let h = Harness()
        await h.controller.connect()
        failTmux(h.factory.last!, status: 127, text: nil)
        #expect(await waitUntil { h.controller.notice != nil })
        #expect(h.controller.state == .connected)
    }

    @Test func commandNotFoundTextAloneTriggersTheFallback() async {
        let h = Harness()
        await h.controller.connect()
        failTmux(h.factory.last!, status: nil, text: "sh: 1: tmux: not found\r\n")
        #expect(await waitUntil { h.controller.notice != nil })
        #expect(h.controller.state == .connected)
    }

    @Test func aNormalTmuxExitIsNotAFallback() async {
        let h = Harness()
        await h.controller.connect()
        failTmux(h.factory.last!, status: 0, text: nil)
        #expect(await waitUntil { h.controller.state == .disconnected(exitStatus: 0) })
        #expect(h.controller.notice == nil)
        #expect(h.factory.last!.opens.get.count == 1)
    }

    @Test func tmuxExit127AfterRealOutputIsNotAFallback() async {
        let h = Harness()
        await h.controller.connect()
        let conn = h.factory.last!
        conn.shell.emit(String(repeating: "x", count: 5000))
        conn.shell.emit(.exit(status: 127, signal: nil))
        conn.shell.emit(.closed(reason: .remote))
        #expect(await waitUntil { h.controller.state == .disconnected(exitStatus: 127) })
        #expect(h.controller.notice == nil)
    }

    @Test func noFallbackNoticeWhenTmuxIsDisabled() async {
        var p = HostProfile(name: "d", host: host, username: "alice", auth: .password)
        p.tmux.enabled = false
        let h = Harness(profile: p)
        await h.controller.connect()
        failTmux(h.factory.last!)
        #expect(await waitUntil { h.controller.state == .disconnected(exitStatus: 127) })
        #expect(h.controller.notice == nil)
    }

    @Test func startupCommandIsTypedIntoTheFallbackShell() async {
        var p = HostProfile(name: "d", host: host, username: "alice", auth: .password)
        p.startupCommand = "claude"
        let h = Harness(profile: p)
        await h.controller.connect()
        failTmux(h.factory.last!)
        #expect(await waitUntil { h.factory.last!.shell.writtenText == "claude\r" })
    }

    @Test func reconnectAfterAFallbackGoesStraightToThePlainShell() async {
        let h = Harness()
        await h.controller.connect()
        failTmux(h.factory.last!)
        #expect(await waitUntil { h.controller.notice != nil })
        h.factory.last!.end(.io)
        #expect(await waitUntil { h.factory.attempts == 2 && h.controller.state == .connected })
        guard case .shell = h.factory.last!.opens.get[0] else { Issue.record("expected a plain shell on reconnect"); return }
        #expect(h.controller.notice == SessionController.tmuxMissingNotice)
    }

    // MARK: teardown

    @Test func controllerIsReleasedAfterDisconnect() async {
        weak var weakController: SessionController?
        do {
            let h = Harness()
            weakController = h.controller
            await h.controller.connect()
            await h.controller.disconnect()
        }
        #expect(await waitUntil { weakController == nil })
    }

    @Test func disconnectWhileHandshakingDiscardsTheLateConnection() async {
        let (gate, release) = AsyncStream<Void>.makeStream()
        let h = Harness(factory: FakeFactory { _, _, _, _ in for await _ in gate { break } })
        let task = h.connectInBackground()
        #expect(await waitUntil { h.factory.attempts == 1 })
        await h.controller.disconnect()
        release.yield()
        await task.value
        #expect(h.controller.state == .disconnected(exitStatus: nil))
        #expect(h.factory.last!.disconnects.get == 1)
        #expect(h.factory.last!.opens.get.isEmpty)
    }

    @Test func disconnectWhileAPromptIsPendingResolvesIt() async {
        let key = newHostKey()
        let h = Harness(factory: FakeFactory { _, _, v, _ in try await verify(v, key) })
        let task = h.connectInBackground()
        #expect(await waitUntil { h.controller.pendingPrompt != nil })
        await h.controller.disconnect()
        await task.value
        #expect(h.controller.pendingPrompt == nil)
        #expect(h.controller.state == .disconnected(exitStatus: nil))
    }

    @Test func statusDotMapping() {
        #expect(SessionState.idle.status == .off)
        #expect(SessionState.disconnected(exitStatus: nil).status == .off)
        #expect(SessionState.connecting.status == .busy)
        #expect(SessionState.authenticating.status == .busy)
        #expect(SessionState.connected.status == .connected)
        #expect(SessionState.reconnecting(attempt: 2, nextRetryAt: nil).status == .warning)
        #expect(SessionState.failed(SessionError(kind: .other, message: "x")).status == .error)
    }

    @Test func errorMessagesAreHumanReadable() {
        #expect(SessionError(FfiSshError.AuthFailed(triedMethods: ["password"])).kind == .authFailed)
        #expect(SessionError(FfiSshError.Timeout).kind == .timeout)
        #expect(SessionError(FfiSshError.Connect(message: "refused")).message.contains("refused"))
        #expect(SessionError(FfiSshError.HostKeyRejected).kind == .hostKeyRejected)
    }
}
