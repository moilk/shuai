import Foundation
import Observation
import ShuaiCore

public enum TmuxError: Error, Equatable, Sendable {
    /// No live control channel / poller (not started, stopped, ended or unavailable).
    case notRunning
    /// The control channel closed before the command was answered.
    case channelClosed
    /// tmux answered with `%error` / exited non-zero; the text is tmux's message.
    case commandFailed(String)
    /// No PTY client of ours is known, so `switch-client` has nobody to move.
    case noPtyClient
    case invalidTarget(String)
}

/// Native view of one host's tmux server, kept in sync with a side channel.
///
/// Control mode: a second SSH channel on the same connection runs `tmux -C attach -t =SESSION:`
/// via `execStream` (no PTY needed). The first stdin line suppresses `%output` (`refresh-client
/// -f no-output`); the channel is drained continuously (stdout goes through the FFI
/// `TmuxController`, which turns the notification stream into a few events). Structural
/// notifications are debounced into one `list-panes -a -F ...` (sent over the same channel);
/// renames patch the tree directly. tmux older than 3.2 (no `no-output`) is polled with one-shot
/// `exec` instead. The monitor never writes to the terminal PTY.
///
/// Client targeting: commands issued here come from the *control* client, so anything that
/// concerns "what the terminal shows" (`switch-client`) must name the PTY client explicitly. Its
/// tty is found with `list-clients` (the control client's own pid, from `display-message -p
/// #{client_pid}`, identifies the control row; the PTY client is the other client of our
/// session, preferring the matching size). Once found the tty is sticky (the client keeps its tty
/// when it switches sessions) and `viewedSessionID` follows its row.
@MainActor @Observable
public final class TmuxMonitor {
    public enum State: Equatable, Sendable {
        case idle, starting
        /// Control channel up, topology live.
        case live
        /// Old tmux: topology refreshed by polling.
        case polling
        /// tmux is missing / unusable on this host.
        case unavailable(String)
        /// The control channel ended (session killed, channel lost, could not attach).
        case ended(String?)
        case stopped
    }

    public private(set) var state: State = .idle
    public private(set) var topology: FfiTopology?
    /// Incremented whenever `topology` changed; `lastChanges` is the diff of that change.
    public private(set) var changeCount = 0
    public private(set) var lastChanges: [FfiTopologyChange] = []
    /// tty of our terminal's tmux client (`/dev/ttys002`), once found.
    public private(set) var ptyClientTty: String?
    /// Session (`$1`) the terminal's client currently shows.
    public private(set) var viewedSessionID: String?
    public let sessionName: String

    @ObservationIgnored private let ptySize: @MainActor () -> (cols: UInt32, rows: UInt32)
    @ObservationIgnored private let debounce: Duration
    @ObservationIgnored private let pollInterval: Duration
    @ObservationIgnored private let attachRetries: Int
    @ObservationIgnored private let attachRetryDelay: Duration

    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var conn: RemoteConnection?
    @ObservationIgnored private var channel: Channel?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var refreshing = false
    @ObservationIgnored private var refreshAgain = false
    @ObservationIgnored private var controlPid: Int?
    @ObservationIgnored private var versionOutput = ""

    /// One control channel: exec stream, ordered stdin queue, reader task, pending replies.
    private final class Channel {
        let id: Int
        let exec: RemoteExec
        let controller: TmuxController
        let stdin: AsyncStream<String>.Continuation
        var writer: Task<Void, Never>?
        var reader: Task<Void, Never>?
        var pending: [UInt64: CheckedContinuation<[String], Error>] = [:]
        var closed = false

        init(id: Int, exec: RemoteExec, controller: TmuxController, stdin: AsyncStream<String>.Continuation) {
            self.id = id
            self.exec = exec
            self.controller = controller
            self.stdin = stdin
        }
    }

    @ObservationIgnored private var channelCounter = 0

    public init(
        sessionName: String,
        ptySize: @escaping @MainActor () -> (cols: UInt32, rows: UInt32) = { (80, 24) },
        debounce: Duration = .milliseconds(100), pollInterval: Duration = .seconds(2),
        attachRetries: Int = 8, attachRetryDelay: Duration = .milliseconds(150)
    ) {
        self.sessionName = sessionName
        self.ptySize = ptySize
        self.debounce = debounce
        self.pollInterval = pollInterval
        self.attachRetries = max(1, attachRetries)
        self.attachRetryDelay = attachRetryDelay
    }

    // MARK: - Lifecycle

    /// Probes tmux and starts the side channel (or the poller). Returns once the first topology was
    /// loaded or the attempt failed; a running monitor is restarted. Safe to call again after a
    /// reconnect with the new connection.
    public func start(on connection: RemoteConnection) async {
        await shutdown()
        guard !Task.isCancelled else { return }
        generation += 1
        let gen = generation
        conn = connection
        state = .starting
        controlPid = nil

        guard let version = await probeVersion(connection), gen == generation else {
            if gen == generation { state = .unavailable("tmux was not found on this host.") }
            return
        }
        versionOutput = version
        guard let caps = try? tmuxCapabilities(versionOutput: version), caps.controlMode else {
            state = .unavailable("This tmux version is not supported.")
            return
        }
        if caps.noOutput {
            await startControl(gen: gen, connection: connection)
        } else {
            state = .polling
            await refreshNow()
            guard gen == generation, state == .polling else { return }
            pollTask = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    try? await Task.sleep(for: self.pollInterval)
                    guard !Task.isCancelled, gen == self.generation else { return }
                    await self.refreshNow()
                }
            }
        }
    }

    public func stop() async {
        await shutdown()
        generation += 1
        state = .stopped
    }

    private func shutdown() async {
        pollTask?.cancel(); pollTask = nil
        refreshTask?.cancel(); refreshTask = nil
        refreshing = false
        refreshAgain = false
        let ch = channel
        channel = nil
        if let ch { await closeChannel(ch) }
    }

    private func probeVersion(_ connection: RemoteConnection) async -> String? {
        guard let result = try? await connection.exec(tmuxVersionCommand().shell), result.exitStatus == 0 else { return nil }
        let text = String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    // MARK: - Control channel

    private func startControl(gen: Int, connection: RemoteConnection) async {
        for attempt in 1 ... attachRetries {
            guard gen == generation else { return }
            do {
                let ch = try await openChannel(connection)
                guard gen == generation else { await closeChannel(ch); return }
                do {
                    // Doubles as the attach probe: it only gets an answer once the session exists.
                    let pid = try await run(tmuxDisplayMessage(format: "#{client_pid}"), on: ch)
                    guard gen == generation else { await closeChannel(ch); return }
                    channel = ch
                    controlPid = Int(pid.first?.trimmingCharacters(in: .whitespaces) ?? "")
                    state = .live
                    await refreshNow()
                    return
                } catch {
                    await closeChannel(ch)
                }
            } catch {
                // execStream itself failed (connection gone): nothing to retry against.
                guard gen == generation else { return }
                state = .ended(String(describing: error))
                return
            }
            guard attempt < attachRetries else { break }
            try? await Task.sleep(for: attachRetryDelay)
        }
        if gen == generation { state = .ended("Could not attach to tmux session \(sessionName).") }
    }

    private func openChannel(_ connection: RemoteConnection) async throws -> Channel {
        let controller = try TmuxController(session: sessionName, versionOutput: versionOutput)
        let exec = try await connection.execStream(controller.attachCommand().shell)
        channelCounter += 1
        let (lines, continuation) = AsyncStream<String>.makeStream()
        let ch = Channel(id: channelCounter, exec: exec, controller: controller, stdin: continuation)
        ch.writer = Task {
            for await line in lines { try? await exec.writeStdin(Data((line + "\n").utf8)) }
        }
        ch.reader = Task { [weak self] in
            for await event in exec.events {
                guard let self else { return }
                switch event {
                case .stdout(let bytes): self.handle(ch.controller.push(data: bytes), on: ch)
                case .closed(let reason): self.channelEnded(ch, reason: "Channel closed (\(reason)).")
                default: break
                }
                if ch.closed { return }
            }
            self?.channelEnded(ch, reason: "Channel closed.")
        }
        // Output suppression goes first, before anything can produce %output.
        for line in controller.onConnected() { continuation.yield(line) }
        return ch
    }

    private func closeChannel(_ ch: Channel) async {
        ch.closed = true
        ch.stdin.finish()
        ch.reader?.cancel()
        ch.writer?.cancel()
        failPending(ch, TmuxError.channelClosed)
        await ch.exec.close()
    }

    private func failPending(_ ch: Channel, _ error: Error) {
        let pending = ch.pending
        ch.pending = [:]
        for (_, c) in pending { c.resume(throwing: error) }
    }

    private func channelEnded(_ ch: Channel, reason: String?) {
        guard !ch.closed else { return }
        ch.closed = true
        ch.stdin.finish()
        failPending(ch, TmuxError.channelClosed)
        guard channel === ch else { return } // still attaching (the attach probe retries) or replaced
        channel = nil
        refreshTask?.cancel(); refreshTask = nil
        refreshing = false
        state = .ended(reason)
        Task { await ch.exec.close() }
    }

    private func handle(_ events: [FfiControllerEvent], on ch: Channel) {
        for event in events {
            switch event {
            case .needsRefresh:
                guard channel === ch, state == .live else { continue }
                scheduleRefresh()
            case .windowRenamed(let id, let name):
                patch { t in
                    for s in t.sessions.indices {
                        for w in t.sessions[s].windows.indices where t.sessions[s].windows[w].id == id {
                            t.sessions[s].windows[w].name = name
                        }
                    }
                } change: { t in
                    for s in t.sessions { for w in s.windows where w.id == id {
                        return .windowRenamed(sessionId: s.id, windowId: id, old: w.name, new: name)
                    } }
                    return nil
                }
            case .sessionRenamed(let id, let name):
                patch { t in
                    for s in t.sessions.indices where t.sessions[s].id == id { t.sessions[s].name = name }
                } change: { t in
                    t.sessions.first { $0.id == id }.map { .sessionRenamed(sessionId: id, old: $0.name, new: name) }
                }
            case .reply(let token, let ok, let lines):
                if let c = ch.pending.removeValue(forKey: token) {
                    if ok { c.resume(returning: lines) } else { c.resume(throwing: TmuxError.commandFailed(lines.joined(separator: "\n"))) }
                }
            case .exited(let reason):
                channelEnded(ch, reason: reason)
            }
        }
    }

    /// Applies a direct patch (rename) and publishes it like a refresh would.
    private func patch(_ apply: (inout FfiTopology) -> Void, change: (FfiTopology) -> FfiTopologyChange?) {
        guard var t = topology else { return }
        guard let c = change(t) else { return }
        apply(&t)
        topology = t
        lastChanges = [c]
        changeCount += 1
    }

    // MARK: - Commands

    /// Runs a tmux command and returns its output lines. Control mode: over the side channel;
    /// polling mode: one-shot exec.
    @discardableResult
    public func run(_ command: FfiTmuxCommand) async throws -> [String] {
        switch state {
        case .live:
            guard let ch = channel else { throw TmuxError.notRunning }
            return try await run(command, on: ch)
        case .polling:
            guard let conn else { throw TmuxError.notRunning }
            return try await execRun(command, on: conn)
        default:
            throw TmuxError.notRunning
        }
    }

    private func run(_ command: FfiTmuxCommand, on ch: Channel) async throws -> [String] {
        guard !ch.closed else { throw TmuxError.channelClosed }
        // Registering the reply and queueing the line happen in one synchronous step, so
        // concurrent callers cannot reorder (replies are matched first-in-first-out).
        let sent = ch.controller.send(command: command)
        return try await withCheckedThrowingContinuation { cont in
            ch.pending[sent.token] = cont
            ch.stdin.yield(sent.line)
        }
    }

    private func execRun(_ command: FfiTmuxCommand, on conn: RemoteConnection) async throws -> [String] {
        let r = try await conn.exec(command.shell)
        guard r.exitStatus == 0 else {
            let msg = String(decoding: r.stderr.isEmpty ? r.stdout : r.stderr, as: UTF8.self)
            throw TmuxError.commandFailed(msg.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return Self.lines(String(decoding: r.stdout, as: UTF8.self))
    }

    private static func lines(_ text: String) -> [String] {
        var l = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if l.last == "" { l.removeLast() }
        return l
    }

    // MARK: - Refresh

    private func scheduleRefresh() {
        if refreshing { refreshAgain = true; return }
        guard refreshTask == nil else { return } // a refresh is already queued: this burst joins it
        let gen = generation
        refreshTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.debounce)
            guard !Task.isCancelled, gen == self.generation else { return }
            self.refreshTask = nil
            await self.refreshNow()
        }
    }

    /// Re-reads the topology and the client list right now.
    public func refreshNow() async {
        guard state == .live || state == .polling else { return }
        if refreshing { refreshAgain = true; return }
        refreshing = true
        let gen = generation
        defer { if gen == generation { refreshing = false } }
        repeat {
            refreshAgain = false
            do {
                let panes = try await run(tmuxListPanesAll())
                let clients = try? await run(tmuxListClients())
                guard gen == generation else { return }
                apply(panesText: panes.joined(separator: "\n") + "\n", clientsText: clients.map { $0.joined(separator: "\n") + "\n" })
            } catch {
                // A failed refresh keeps the last tree (the channel's end is reported separately).
            }
        } while refreshAgain && gen == generation
    }

    private func apply(panesText: String, clientsText: String?) {
        if let new = try? parseTopology(text: panesText), new != topology {
            let changes = topology.flatMap { try? diffTopology(old: $0, new: new) } ?? []
            topology = new
            lastChanges = changes
            changeCount += 1
        }
        if let clientsText, let clients = try? parseClients(text: clientsText) { updateClient(clients) }
    }

    private func updateClient(_ clients: [FfiTmuxClient]) {
        if let tty = ptyClientTty, let row = clients.first(where: { $0.tty == tty && !$0.controlMode }) {
            viewedSessionID = row.sessionId
            return
        }
        let size = ptySize()
        let sz = FfiSize(cols: size.cols, rows: size.rows)
        let pid = controlPid.map { UInt32($0) }
        let tty = pickPtyClient(clients: clients, session: sessionName, controlPid: pid, size: sz)
            ?? pickPtyClientAnySession(clients: clients, controlPid: pid, size: sz)
        ptyClientTty = tty
        viewedSessionID = tty.flatMap { t in clients.first { $0.tty == t }?.sessionId }
    }

    #if DEBUG
    /// UI tests / previews: shows `topology` without any connection.
    public func debugSeed(topology: FfiTopology, viewedSessionID: String?) {
        self.topology = topology
        self.viewedSessionID = viewedSessionID
        changeCount += 1
    }
    #endif

    /// Forgets the PTY client (it was not found any more): the next refresh picks again.
    func clearPtyClient() { ptyClientTty = nil }
}
