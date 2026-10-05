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
    /// OSC 52 / unsafe paste awaiting the user's decision.
    public var pendingClipboard: ClipboardRequest?
    /// Text of the sticky notice posted when tmux is missing on the host.
    public static let tmuxMissingNotice = "tmux not found on host \u{2014} using plain shell (sessions won't persist)"
    /// A tmux that fails to start prints at most a short error; anything longer is a real session.
    static let tmuxProbeBytes = 1024
    /// Fired after every successful attach (initial and reconnects).
    @ObservationIgnored public var onConnected: (() -> Void)?
    /// The live connection as an `AgentRemote` (agent monitor, installer); nil while there is no transport.
    public private(set) var agentRemote: AgentRemote?
    /// Called with the remote after every successful attach and with nil when the transport goes away.
    @ObservationIgnored public var onAgentRemoteChange: ((AgentRemote?) -> Void)?

    public var windowTitle: String { title.isEmpty ? profile.name : title }

    /// tmux side channel (topology for the sidebar, window/pane actions). Started on every
    /// successful tmux attach, stopped when the transport goes away.
    public let tmux: TmuxMonitor
    public let tmuxActions: TmuxActions

    @ObservationIgnored var stateLog: [SessionState] = [.idle]
    @ObservationIgnored private var tmuxStartTask: Task<Void, Never>?

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
    @ObservationIgnored private let notices: (any NoticePosting)?
    /// Set by the registry when the controller is removed or replaced: it posts nothing afterwards.
    @ObservationIgnored private var isRetired = false

    // Live transport
    private enum Command: Sendable {
        case write(Data)
        case resize(cols: UInt32, rows: UInt32)
    }
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var connection: RemoteConnection?
    @ObservationIgnored private var shell: RemoteShell?
    @ObservationIgnored private var commands: AsyncStream<Command>.Continuation?
    /// Non-nil while the tmux -> plain shell switch is in flight: keystrokes typed meanwhile wait here
    /// and are replayed into the new shell (resizes are dropped; the new shell opens at the current size).
    @ObservationIgnored private var inputDuringSwitch: [Data]?
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
    /// The user dismissed the lazily shown password prompt (the SSH layer then reports a failed auth).
    @ObservationIgnored private var passwordCancelled = false
    /// tmux was not found on this host; later (re)connects open a plain shell right away.
    @ObservationIgnored private var tmuxUnavailable = false
    /// tmux is missing on this host (plain shell fallback): no tmux tree will ever arrive.
    public var tmuxMissing: Bool { tmuxUnavailable }

    private struct Cancelled: Error {}
    @ObservationIgnored private let replyGuard = DeviceReplyGuard()

    public init(
        profile: HostProfile,
        engine: any TerminalEngine,
        factory: ConnectionFactory,
        keys: KeyStore,
        passwords: PasswordStore,
        knownHosts: KnownHostsStore,
        notices: (any NoticePosting)? = nil,
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
        self.notices = notices
        let monitor = TmuxMonitor(sessionName: profile.tmux.sessionName, ptySize: { [engine] in
            let g = engine.gridSize
            return g.isValid ? (UInt32(g.cols), UInt32(g.rows)) : (80, 24)
        })
        tmux = monitor
        tmuxActions = TmuxActions(monitor: monitor, notices: notices.map { NoticeRoute(hostID: profile.id, poster: $0) })
        wireEngine()
    }

    // MARK: - Engine wiring

    private func wireEngine() {
        engine.onInput = { [weak self] data in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Replies to DA1/DA2/XTVERSION that nobody asked for (or that arrive late / twice) would be typed
                // into the pane by tmux; everything else (keys, other reports) is written as one contiguous write.
                guard self.replyGuard.admit(data, at: self.now()) else {
                    Self.byteTap("X", data)
                    return
                }
                self.enqueue(.write(data))
            }
        }
        engine.onResize = { [weak self] grid in
            MainActor.assumeIsolated {
                guard grid.isValid else { return }
                self?.enqueue(.resize(cols: UInt32(grid.cols), rows: UInt32(grid.rows)))
            }
        }
        engine.onTitleChange = { [weak self] t in MainActor.assumeIsolated { self?.title = t } }
        engine.onNotification = { [weak self] n in MainActor.assumeIsolated { self?.postTerminalNotification(n) } }
        engine.onClipboardRequest = { [weak self] r in MainActor.assumeIsolated { self?.pendingClipboard = r } }
    }

    private var tmuxMissingKey: String { "tmux-missing:\(profile.id.uuidString)" }
    private var oscKey: String { "osc:\(profile.id.uuidString)" }

    /// The host entry is gone or replaced: withdraw this controller's notices and post no more.
    public func retire() {
        notices?.retract(key: tmuxMissingKey)
        notices?.retract(key: oscKey)
        notices?.retract(key: TmuxActions.errorKey(hostID: profile.id))
        isRetired = true
        tmuxActions.retire()
    }

    /// OSC 9/777 from the remote: untrusted, attributed to the host (`Notice.terminal`). One key
    /// per host, so a flood coalesces into a single notice.
    private func postTerminalNotification(_ n: TerminalNotification) {
        guard !isRetired,
              let notice = Notice.terminal(title: n.title, body: n.body, hostName: profile.name, hostID: profile.id)
        else { return }
        notices?.post(notice)
    }

    /// Types text into the remote (debug scripting, tests).
    public func sendInput(_ text: String) { enqueue(.write(Data(text.utf8))) }

    private func enqueue(_ command: Command) {
        if let commands {
            commands.yield(command)
        } else if inputDuringSwitch != nil, case .write(let data) = command {
            inputDuringSwitch?.append(data)
        }
    }

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
        tmuxUnavailable = false
        notices?.retract(key: tmuxMissingKey)
        passwordCancelled = false
        state = .connecting
        do {
            let auth = try buildAuth()
            let conn = try await open(auth: auth)
            guard gen == generation else { await conn.disconnect(); return }
            try await attach(conn, gen: gen, reconnecting: false)
        } catch is Cancelled {
            if gen == generation { state = .disconnected(exitStatus: nil) }
        } catch {
            guard gen == generation else { return }
            await dropReconnector()
            noteAuthOutcome(error)
            if passwordCancelled {
                passwordCancelled = false
                state = .disconnected(exitStatus: nil)
            } else {
                state = .failed(SessionError(error))
            }
        }
    }

    /// A rejected password must not be offered again silently.
    private func noteAuthOutcome(_ error: Error) {
        if SessionError(error).kind == .authFailed { sessionPassword = nil }
    }

    /// User-initiated disconnect (also gives up a reconnect). Forgets a typed `.ask` password.
    public func disconnect() async {
        sessionPassword = nil
        await endSession()
    }

    private func endSession() async {
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
        await endSession() // keeps a typed password: an explicit reconnect is not a new login
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

    /// Builds the credential list without any user interaction: a password that has to be typed is
    /// requested lazily by the SSH layer (`PasswordBridge`), i.e. only after the host key was trusted.
    private func buildAuth() throws -> [FfiAuth] {
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
                auth.append(.passwordPrompt(prompter: PasswordBridge(controller: self)))
            }
        case .ask:
            auth.append(.passwordPrompt(prompter: PasswordBridge(controller: self)))
        }
        auth.append(.keyboardInteractive(prompter: KbdBridge(controller: self)))
        return auth
    }

    fileprivate func passwordFromUser() async -> String? {
        if let sessionPassword { return sessionPassword }
        guard let pw = await askPassword() else {
            passwordCancelled = true
            return nil
        }
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
        let useTmux = profile.tmux.enabled && !tmuxUnavailable
        let newShell: RemoteShell
        do {
            newShell = try await openRemoteShell(on: conn, tmux: useTmux)
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
        startShell(newShell, gen: gen, tmuxAttempt: useTmux)
        closedTask = Task { [weak self] in
            let reason = await conn.closed()
            await self?.connectionClosed(gen: gen, reason: reason)
        }

        isReconnecting = false
        lastReconnectError = nil
        state = .connected
        onConnected?()
        let remote = ConnectionAgentRemote(conn)
        agentRemote = remote
        onAgentRemoteChange?(remote)
        if useTmux { startTmuxMonitor(on: conn) }

        if reconnecting { redrawNudge(gen: gen) }
        if !useTmux, !reconnecting { typeStartupCommand() }
    }

    private func startTmuxMonitor(on conn: RemoteConnection) {
        tmuxStartTask?.cancel()
        let monitor = tmux
        tmuxStartTask = Task { await monitor.start(on: conn) }
    }

    private func stopTmuxMonitor() async {
        tmuxStartTask?.cancel(); tmuxStartTask = nil
        if tmux.state != .idle { await tmux.stop() }
    }

    private func openRemoteShell(on conn: RemoteConnection, tmux: Bool) async throws -> RemoteShell {
        let size = currentSize()
        if tmux {
            let cmd = TmuxLaunch.command(sessionName: profile.tmux.sessionName, startupCommand: profile.startupCommand)
            return try await conn.openPtyExec(command: cmd, cols: size.cols, rows: size.rows, term: "xterm-256color", env: Self.env)
        }
        return try await conn.openShell(cols: size.cols, rows: size.rows, term: "xterm-256color", env: Self.env)
    }

    private func typeStartupCommand() {
        if let startup = profile.startupCommand?.trimmingCharacters(in: .whitespacesAndNewlines), !startup.isEmpty {
            sendInput(startup + "\r")
        }
    }

    /// Wires a freshly opened shell to the engine: ordered writer queue + event pump.
    /// `tmuxAttempt` marks a shell that runs `tmux new -A` so a missing tmux can be detected.
    private func startShell(_ newShell: RemoteShell, gen: Int, tmuxAttempt: Bool) {
        shell = newShell
        replyGuard.reset()
        let (stream, continuation) = AsyncStream<Command>.makeStream()
        commands = continuation
        writerTask = Task {
            for await command in stream {
                switch command {
                case .write(let data):
                    Self.byteTap("W", data)
                    try? await newShell.write(data)
                case .resize(let cols, let rows): try? await newShell.resize(cols: cols, rows: rows)
                }
            }
        }
        eventsTask = Task { [weak self] in
            var exitStatus: Int?
            var received = 0
            var missingHint = false
            for await event in newShell.events {
                guard let self else { return }
                switch event {
                case .data(let bytes):
                    if tmuxAttempt, received <= Self.tmuxProbeBytes {
                        received += bytes.count
                        missingHint = missingHint || Self.looksLikeMissingTmux(bytes)
                    }
                    Self.byteTap("R", bytes)
                    self.replyGuard.noteOutput(bytes, at: self.now())
                    if gen == self.generation { self.engine.feed(bytes) }
                case .exit(let status, _):
                    exitStatus = status.map { Int($0) }
                case .closed(let reason):
                    let tmuxMissing = tmuxAttempt && reason == .remote && received <= Self.tmuxProbeBytes
                        && (exitStatus == 127 || missingHint)
                    await self.shellClosed(gen: gen, reason: reason, exitStatus: exitStatus, tmuxMissing: tmuxMissing)
                    return
                }
            }
            await self?.shellClosed(gen: gen, reason: .local, exitStatus: exitStatus, tmuxMissing: false)
        }
    }

    #if DEBUG
    private static let tapEnabled = ProcessInfo.processInfo.arguments.contains("-debugByteTap")
    #endif
    /// DEBUG-only (`-debugByteTap`): logs timestamp, length and hex of every channel write (W) / read (R).
    static func byteTap(_ dir: String, _ data: Data) {
        #if DEBUG
        guard tapEnabled else { return }
        let hex = data.prefix(96).map { String(format: "%02x", $0) }.joined(separator: " ")
        NSLog("[tap] %@ t=%.3f len=%d %@", dir, Date().timeIntervalSince1970, data.count, hex)
        #endif
    }

    private static func looksLikeMissingTmux(_ bytes: Data) -> Bool {
        let text = String(decoding: bytes, as: UTF8.self).lowercased()
        return text.contains("command not found") || (text.contains("tmux") && text.contains("not found"))
    }

    /// tmux is not installed: keep the connection, swap the dead PTY exec for a plain login shell.
    private func fallBackToPlainShell(gen: Int) async {
        guard gen == generation, let conn = connection else { return }
        tmuxUnavailable = true
        if !isRetired { notices?.post(Notice(
            severity: .warning, source: .session, scope: .host(profile.id), text: Self.tmuxMissingNotice,
            symbol: "exclamationmark.triangle", key: tmuxMissingKey, lifetime: .sticky)) }
        inputDuringSwitch = []
        defer { inputDuringSwitch = nil }
        await stopTmuxMonitor()
        commands?.finish(); commands = nil
        writerTask = nil
        eventsTask = nil
        let old = shell
        shell = nil
        await old?.close()
        guard gen == generation else { return }
        do {
            let plain = try await openRemoteShell(on: conn, tmux: false)
            guard gen == generation else { await plain.close(); return }
            startShell(plain, gen: gen, tmuxAttempt: false)
            typeStartupCommand()
            for data in inputDuringSwitch ?? [] { enqueue(.write(data)) }
        } catch {
            guard gen == generation else { return }
            generation += 1
            await dropReconnector()
            await teardownTransport()
            state = .failed(SessionError(error))
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

    private func shellClosed(gen: Int, reason: CloseReason, exitStatus: Int?, tmuxMissing: Bool) async {
        guard gen == generation else { return }
        switch reason {
        case .local:
            return
        case .remote where tmuxMissing:
            // Not on this task: it must stay free of cancellation while the fallback shell opens.
            Task { [weak self] in await self?.fallBackToPlainShell(gen: gen) }
        case .remote:
            sessionPassword = nil
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
        if agentRemote != nil {
            agentRemote = nil
            onAgentRemoteChange?(nil)
        }
        await stopTmuxMonitor()
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
            sessionPassword = nil
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
        passwordCancelled = false
        do {
            let auth = try buildAuth()
            let conn = try await open(auth: auth)
            guard gen == generation else { await conn.disconnect(); throw Cancelled() }
            try await attach(conn, gen: gen, reconnecting: true)
        } catch is Cancelled {
            // The user cancelled a prompt or the session was replaced: stop reconnecting.
            if gen == generation { await disconnect() }
            throw CancellationError()
        } catch {
            if passwordCancelled, gen == generation {
                // The user dismissed the password prompt: stop reconnecting.
                await disconnect()
                throw CancellationError()
            }
            noteAuthOutcome(error)
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

private final class PasswordBridge: PasswordPromptCallback, @unchecked Sendable {
    private weak var controller: SessionController?
    init(controller: SessionController) { self.controller = controller }

    func password() async -> String? { await controller?.passwordFromUser() }
}

private final class KbdBridge: KbdPrompterCallback, @unchecked Sendable {
    private weak var controller: SessionController?
    init(controller: SessionController) { self.controller = controller }

    func respond(name: String, instructions: String, prompts: [FfiKbdPrompt]) async -> [String]? {
        await controller?.askKeyboardInteractive(name: name, instructions: instructions, prompts: prompts)
    }
}
