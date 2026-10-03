import Foundation
import Observation
import ShuaiCore
import ShuaiPlatform
import ShuaiTerminal

/// One host's terminal session: connection lifecycle (TOFU, auth prompts, PTY + tmux attach,
/// reconnect) and the glue between the SSH shell and a `TerminalEngine`.
///
/// Threading: everything runs on the main actor; SSH I/O is awaited. Input/resize go through
/// one ordered command queue per shell so keystrokes never reorder. A `generation` counter
/// invalidates the callbacks of a connection that was replaced, dropped or cancelled.
@MainActor @Observable
public final class SessionController {
    public let profile: HostProfile
    public private(set) var state: SessionState = .idle {
        didSet {
            guard oldValue != state else { return }
            stateLog.append(state)
            if stateLog.count > 200 { stateLog.removeFirst(100) }
        }
    }
    public private(set) var pendingPrompt: SessionPrompt?
    /// Terminal title (OSC 0/2); see `windowTitle`.
    public private(set) var title = ""
    /// Latest OSC 9/777 notification, shown as an in-app banner.
    public private(set) var banner: TerminalNotification?
    /// OSC 52 / unsafe paste awaiting the user's decision.
    public var pendingClipboard: ClipboardRequest?
    /// Fired after every successful attach (initial and reconnects).
    @ObservationIgnored public var onConnected: (() -> Void)?

    public var windowTitle: String { title.isEmpty ? profile.name : title }

    @ObservationIgnored var stateLog: [SessionState] = [.idle]

    // Dependencies
    @ObservationIgnored private let engine: any TerminalEngine
    @ObservationIgnored private let factory: ConnectionFactory
    @ObservationIgnored private let keys: KeyStore
    @ObservationIgnored private let passwords: PasswordStore
    @ObservationIgnored private let knownHosts: KnownHostsStore
    @ObservationIgnored private let makePolicy: @Sendable () -> ReconnectPolicy
    @ObservationIgnored private let sleep: @Sendable (UInt64) async throws -> Void
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let redrawNudgeDelay: Duration

    // Live transport
    private enum Command: Sendable {
        case write(Data)
        case resize(cols: UInt32, rows: UInt32)
    }
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var connection: RemoteConnection?
    @ObservationIgnored private var shell: RemoteShell?
    @ObservationIgnored private var commands: AsyncStream<Command>.Continuation?
    @ObservationIgnored private var eventsTask: Task<Void, Never>?
    @ObservationIgnored private var writerTask: Task<Void, Never>?
    @ObservationIgnored private var closedTask: Task<Void, Never>?
    @ObservationIgnored private var nudgeTask: Task<Void, Never>?

    // Reconnect
    @ObservationIgnored private var reconnector: ReconnectController?
    @ObservationIgnored private var reconnectObserver: Task<Void, Never>?
    @ObservationIgnored private var networkSignal: AsyncStream<Void>.Continuation?
    @ObservationIgnored private var foregroundSignal: AsyncStream<Void>.Continuation?
    @ObservationIgnored private var isReconnecting = false
    @ObservationIgnored private var reconnectAttempt = 1
    @ObservationIgnored private var lastReconnectError: SessionError?

    // Prompts
    private enum PendingAnswer {
        case bool(CheckedContinuation<Bool, Never>)
        case string(CheckedContinuation<String?, Never>)
        case strings(CheckedContinuation<[String]?, Never>)
    }
    @ObservationIgnored private var pendingAnswer: PendingAnswer?
    /// Password typed for `.ask` hosts; kept in memory only, so reconnects need no prompt.
    @ObservationIgnored private var sessionPassword: String?

    private struct Cancelled: Error {}

    public init(
        profile: HostProfile,
        engine: any TerminalEngine,
        factory: ConnectionFactory,
        keys: KeyStore,
        passwords: PasswordStore,
        knownHosts: KnownHostsStore,
        makePolicy: @escaping @Sendable () -> ReconnectPolicy = { ReconnectPolicy(maxAttempts: nil, jitter: true) },
        sleep: @escaping @Sendable (UInt64) async throws -> Void = { try await Task.sleep(for: .milliseconds($0)) },
        now: @escaping @Sendable () -> Date = { Date() },
        redrawNudgeDelay: Duration = .milliseconds(80)
    ) {
        self.profile = profile
        self.engine = engine
        self.factory = factory
        self.keys = keys
        self.passwords = passwords
        self.knownHosts = knownHosts
        self.makePolicy = makePolicy
        self.sleep = sleep
        self.now = now
        self.redrawNudgeDelay = redrawNudgeDelay
        wireEngine()
    }

    // MARK: - Engine wiring

    private func wireEngine() {
        engine.onInput = { [weak self] data in
            MainActor.assumeIsolated { self?.commands?.yield(.write(data)) }
        }
        engine.onResize = { [weak self] grid in
            MainActor.assumeIsolated {
                guard grid.isValid else { return }
                self?.commands?.yield(.resize(cols: UInt32(grid.cols), rows: UInt32(grid.rows)))
            }
        }
        engine.onTitleChange = { [weak self] t in MainActor.assumeIsolated { self?.title = t } }
        engine.onNotification = { [weak self] n in MainActor.assumeIsolated { self?.banner = n } }
        engine.onClipboardRequest = { [weak self] r in MainActor.assumeIsolated { self?.pendingClipboard = r } }
    }

    public func dismissBanner() { banner = nil }

    /// Types text into the remote (debug scripting, tests).
    public func sendInput(_ text: String) { commands?.yield(.write(Data(text.utf8))) }

    // MARK: - Public lifecycle

    /// Connects (from idle/failed/disconnected). Returns when the attempt has settled: connected,
    /// failed or cancelled. Prompts surface through `pendingPrompt` while this is suspended.
    public func connect() async {
        switch state {
        case .idle, .failed, .disconnected: break
        default: return
        }
        generation += 1
        let gen = generation
        state = .connecting
        do {
            let auth = try await buildAuth()
            guard gen == generation else { return }
            state = .connecting
            let conn = try await open(auth: auth)
            guard gen == generation else { await conn.disconnect(); return }
            try await attach(conn, gen: gen, reconnecting: false)
        } catch is Cancelled {
            if gen == generation { state = .disconnected(exitStatus: nil) }
        } catch {
            guard gen == generation else { return }
            await dropReconnector()
            state = .failed(SessionError(error))
        }
    }

    /// User-initiated disconnect (also gives up a reconnect).
    public func disconnect() async {
        resolvePending()
        generation += 1
        isReconnecting = false
        nudgeTask?.cancel()
        await dropReconnector()
        await teardownTransport()
        state = .disconnected(exitStatus: nil)
    }

    public func cancelReconnect() async { await disconnect() }

    /// Starts over: replaces a live/lost/failed connection with a fresh one.
    public func reconnect() async {
        await disconnect()
        await connect()
    }

    /// "Retry now" while waiting between reconnect attempts, or a fresh connect after giving up.
    public func retryNow() {
        switch state {
        case .reconnecting:
            if let reconnector { Task { await reconnector.start() } }
        case .failed, .disconnected:
            Task { await reconnect() }
        default: break
        }
    }

    public func networkChanged() { networkSignal?.yield() }
    public func appForegrounded() { foregroundSignal?.yield() }

    // MARK: - Prompts

    public func answerHostKey(accept: Bool) {
        guard case .bool(let c) = pendingAnswer else { return }
        pendingAnswer = nil
        pendingPrompt = nil
        c.resume(returning: accept)
    }

    /// `nil` cancels.
    public func answerPassword(_ password: String?) {
        guard case .string(let c) = pendingAnswer else { return }
        pendingAnswer = nil
        pendingPrompt = nil
        c.resume(returning: password)
    }

    /// `nil` abandons keyboard-interactive.
    public func answerKeyboardInteractive(_ answers: [String]?) {
        guard case .strings(let c) = pendingAnswer else { return }
        pendingAnswer = nil
        pendingPrompt = nil
        c.resume(returning: answers)
    }

    /// Rejects whatever is pending (host key: reject, password/kbd: cancel).
    private func resolvePending() {
        let answer = pendingAnswer
        pendingAnswer = nil
        pendingPrompt = nil
        switch answer {
        case .bool(let c): c.resume(returning: false)
        case .string(let c): c.resume(returning: nil)
        case .strings(let c): c.resume(returning: nil)
        case nil: break
        }
    }

    fileprivate func askHostKey(_ challenge: HostKeyChallenge) async -> Bool {
        resolvePending()
        let accepted: Bool = await withCheckedContinuation { c in
            pendingAnswer = .bool(c)
            pendingPrompt = .hostKey(challenge)
            state = .hostKeyPrompt(challenge)
        }
        if isReconnecting, case .hostKeyPrompt = state {
            state = .reconnecting(attempt: reconnectAttempt, nextRetryAt: nil)
        }
        return accepted
    }

    fileprivate func hostKeyTrusted() {
        switch state {
        case .connecting, .hostKeyPrompt: state = .authenticating
        default: break
        }
    }

    private func askPassword() async -> String? {
        resolvePending()
        return await withCheckedContinuation { c in
            pendingAnswer = .string(c)
            pendingPrompt = .password(host: profile.host, username: profile.username)
            if !isReconnecting { state = .authenticating }
        }
    }

    fileprivate func askKeyboardInteractive(name: String, instructions: String, prompts: [FfiKbdPrompt]) async -> [String]? {
        resolvePending()
        return await withCheckedContinuation { c in
            pendingAnswer = .strings(c)
            pendingPrompt = .keyboardInteractive(name: name, instructions: instructions, prompts: prompts)
            if !isReconnecting { state = .authenticating }
        }
    }

    // MARK: - Connecting

    private func buildAuth() async throws -> [FfiAuth] {
        var auth: [FfiAuth] = []
        switch profile.auth {
        case .key(let id):
            guard let pem = (try? keys.loadPrivatePem(id: id)) ?? nil else {
                throw SessionError(kind: .keyMissing, message: "The SSH key for this host is missing. Choose another key in the host settings.")
            }
            auth.append(.privateKeyPem(pem: pem))
        case .password:
            if let stored = (try? passwords.password(for: profile.id)) ?? nil {
                auth.append(.password(password: stored))
            } else {
                auth.append(.password(password: try await passwordFromUser()))
            }
        case .ask:
            auth.append(.password(password: try await passwordFromUser()))
        }
        auth.append(.keyboardInteractive(prompter: KbdBridge(controller: self)))
        return auth
    }

    private func passwordFromUser() async throws -> String {
        if let sessionPassword { return sessionPassword }
        guard let pw = await askPassword() else { throw Cancelled() }
        if profile.auth == .ask { sessionPassword = pw }
        return pw
    }

    private func open(auth: [FfiAuth]) async throws -> RemoteConnection {
        let config = FfiConnectConfig(
            host: profile.host.trimmingCharacters(in: .whitespaces), port: UInt16(clamping: profile.port),
            username: profile.username, auth: auth, keepaliveSecs: 15, connectTimeoutSecs: 15, authTimeoutSecs: 90)
        let tofu = TOFUVerifier(
            store: knownHosts,
            decide: { [weak self] in await self?.askHostKey($0) ?? false },
            decideChanged: { [weak self] in await self?.askHostKey($0) ?? false })
        if !isReconnecting { state = .connecting }
        return try await factory.connect(config: config, verifier: SessionVerifier(tofu: tofu, controller: self))
    }

    private func currentSize() -> (cols: UInt32, rows: UInt32) {
        let g = engine.gridSize
        return g.isValid ? (UInt32(g.cols), UInt32(g.rows)) : (80, 24)
    }

    private static let env = [
        FfiEnvVar(name: "COLORTERM", value: "truecolor"),
        FfiEnvVar(name: "LANG", value: "en_US.UTF-8"),
    ]

    private func attach(_ conn: RemoteConnection, gen: Int, reconnecting: Bool) async throws {
        let size = currentSize()
        let newShell: RemoteShell
        do {
            if profile.tmux.enabled {
                let cmd = TmuxLaunch.command(sessionName: profile.tmux.sessionName, startupCommand: profile.startupCommand)
                newShell = try await conn.openPtyExec(
                    command: cmd, cols: size.cols, rows: size.rows, term: "xterm-256color", env: Self.env)
            } else {
                newShell = try await conn.openShell(
                    cols: size.cols, rows: size.rows, term: "xterm-256color", env: Self.env)
            }
        } catch {
            await conn.disconnect()
            throw error
        }
        guard gen == generation else {
            await newShell.close()
            await conn.disconnect()
            throw Cancelled()
        }
        if !reconnecting { await installReconnector() }
        guard gen == generation else {
            await newShell.close()
            await conn.disconnect()
            throw Cancelled()
        }

        connection = conn
        shell = newShell
        let (stream, continuation) = AsyncStream<Command>.makeStream()
        commands = continuation
        writerTask = Task {
            for await command in stream {
                switch command {
                case .write(let data): try? await newShell.write(data)
                case .resize(let cols, let rows): try? await newShell.resize(cols: cols, rows: rows)
                }
            }
        }
        eventsTask = Task { [weak self] in
            var exitStatus: Int?
            for await event in newShell.events {
                guard let self else { return }
                switch event {
                case .data(let bytes):
                    if gen == self.generation { self.engine.feed(bytes) }
                case .exit(let status, _):
                    exitStatus = status.map { Int($0) }
                case .closed(let reason):
                    await self.shellClosed(gen: gen, reason: reason, exitStatus: exitStatus)
                    return
                }
            }
            await self?.shellClosed(gen: gen, reason: .local, exitStatus: exitStatus)
        }
        closedTask = Task { [weak self] in
            let reason = await conn.closed()
            await self?.connectionClosed(gen: gen, reason: reason)
        }

        isReconnecting = false
        lastReconnectError = nil
        state = .connected
        onConnected?()

        if reconnecting { redrawNudge(gen: gen) }
        if !profile.tmux.enabled, let startup = profile.startupCommand?.trimmingCharacters(in: .whitespacesAndNewlines),
           !startup.isEmpty, !reconnecting
        {
            sendInput(startup + "\r")
        }
    }

    /// After a reattach tmux needs a window-change to repaint everything: wiggle the height.
    private func redrawNudge(gen: Int) {
        let g = engine.gridSize
        guard g.isValid, g.rows > 1 else { return }
        commands?.yield(.resize(cols: UInt32(g.cols), rows: UInt32(g.rows - 1)))
        let delay = redrawNudgeDelay
        nudgeTask?.cancel()
        nudgeTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled, gen == self.generation else { return }
            self.commands?.yield(.resize(cols: UInt32(g.cols), rows: UInt32(g.rows)))
        }
    }

    // MARK: - Ending / dropping

    private func shellClosed(gen: Int, reason: CloseReason, exitStatus: Int?) async {
        guard gen == generation else { return }
        switch reason {
        case .local:
            return
        case .remote:
            // The remote program (shell / tmux client) ended normally: not a network problem.
            generation += 1
            await dropReconnector()
            await teardownTransport()
            state = .disconnected(exitStatus: exitStatus)
        default:
            await handleDrop(gen: gen)
        }
    }

    private func connectionClosed(gen: Int, reason: CloseReason) async {
        guard gen == generation, reason != .local else { return }
        await handleDrop(gen: gen)
    }

    private func handleDrop(gen: Int) async {
        guard gen == generation else { return }
        generation += 1
        isReconnecting = true
        reconnectAttempt = 1
        lastReconnectError = nil
        nudgeTask?.cancel()
        state = .reconnecting(attempt: 1, nextRetryAt: nil)
        let rc = reconnector
        await teardownTransport()
        if let rc {
            await rc.connectionDropped()
        } else {
            state = .failed(SessionError(kind: .network, message: "The connection was lost."))
        }
    }

    private func teardownTransport() async {
        eventsTask?.cancel(); eventsTask = nil
        closedTask?.cancel(); closedTask = nil
        commands?.finish(); commands = nil
        writerTask = nil
        let s = shell, c = connection
        shell = nil
        connection = nil
        await s?.close()
        await c?.disconnect()
    }

    // MARK: - Reconnect plumbing

    private func installReconnector() async {
        await dropReconnector()
        let (net, netCont) = AsyncStream<Void>.makeStream()
        let (fg, fgCont) = AsyncStream<Void>.makeStream()
        networkSignal = netCont
        foregroundSignal = fgCont
        let rc = ReconnectController(
            policy: makePolicy(), sleep: sleep,
            connect: { [weak self] in
                guard let self else { throw CancellationError() }
                try await self.reconnectOnce()
            },
            networkChanges: net, foreground: fg)
        reconnector = rc
        reconnectObserver = Task { [weak self] in
            for await s in rc.states {
                guard let self else { return }
                self.policyStateChanged(s, from: rc)
            }
        }
        await rc.adopt()
    }

    private func dropReconnector() async {
        reconnectObserver?.cancel(); reconnectObserver = nil
        networkSignal?.finish(); networkSignal = nil
        foregroundSignal?.finish(); foregroundSignal = nil
        let rc = reconnector
        reconnector = nil
        await rc?.cancel()
    }

    private func policyStateChanged(_ s: FfiReconnectState, from rc: ReconnectController) {
        guard isReconnecting, reconnector === rc else { return }
        switch s {
        case .connecting(let attempt):
            reconnectAttempt = Int(attempt)
            if case .hostKeyPrompt = state { return }
            state = .reconnecting(attempt: Int(attempt), nextRetryAt: nil)
        case .backoff(let attempt, let delayMs):
            reconnectAttempt = Int(attempt)
            state = .reconnecting(attempt: Int(attempt), nextRetryAt: now().addingTimeInterval(Double(delayMs) / 1000))
        case .gaveUp:
            let error = lastReconnectError ?? SessionError(kind: .network, message: "The connection was lost.")
            isReconnecting = false
            Task { [weak self] in
                await self?.dropReconnector()
                self?.state = .failed(error)
            }
        case .idle, .connected:
            break
        }
    }

    private func reconnectOnce() async throws {
        let gen = generation
        do {
            let auth = try await buildAuth()
            guard gen == generation else { throw Cancelled() }
            let conn = try await open(auth: auth)
            guard gen == generation else { await conn.disconnect(); throw Cancelled() }
            try await attach(conn, gen: gen, reconnecting: true)
        } catch is Cancelled {
            // The user cancelled a prompt or the session was replaced: stop reconnecting.
            if gen == generation { await disconnect() }
            throw CancellationError()
        } catch {
            lastReconnectError = SessionError(error)
            throw error
        }
    }
}

// MARK: - Callback bridges

private final class SessionVerifier: HostKeyVerifierCallback, @unchecked Sendable {
    private let tofu: TOFUVerifier
    private weak var controller: SessionController?

    init(tofu: TOFUVerifier, controller: SessionController) {
        self.tofu = tofu
        self.controller = controller
    }

    func verify(host: String, port: UInt16, publicKeyLine: String) async -> Bool {
        let ok = await tofu.verify(host: host, port: port, publicKeyLine: publicKeyLine)
        if ok { await controller?.hostKeyTrusted() }
        return ok
    }
}

private final class KbdBridge: KbdPrompterCallback, @unchecked Sendable {
    private weak var controller: SessionController?
    init(controller: SessionController) { self.controller = controller }

    func respond(name: String, instructions: String, prompts: [FfiKbdPrompt]) async -> [String]? {
        await controller?.askKeyboardInteractive(name: name, instructions: instructions, prompts: prompts)
    }
}
