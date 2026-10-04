import Foundation
import Observation
import ShuaiCore

public enum AgentMonitorState: Equatable, Sendable {
    /// Not attached to a connection (or the connection dropped; state is kept).
    case disconnected
    case connecting
    /// `shuai-agent watch` is streaming.
    case watching
    /// `~/.shuai/bin/shuai-agent` is missing on the host (exit 127).
    case notInstalled
    case failed(String)
}

public enum AnswerState: Equatable, Sendable {
    case allowing
    case denying
}

public enum RespondResult: Equatable, Sendable {
    /// The answer reached the host; the card clears when the agent reports it resolved.
    case sent
    /// The request was already settled (answered locally, timed out, ...): nothing was sent.
    case alreadyResolved
    case failed(String)
}

public struct PendingPermissionItem: Equatable, Sendable, Identifiable {
    public var id: String { request.requestId }
    public let key: FfiSessionKey
    public let request: FfiPendingPermission
    public let session: FfiAgentSession
}

/// Splits a byte stream into UTF-8 lines. A line longer than `maxLine` bytes is dropped (up to
/// its newline) so a runaway stream cannot grow the buffer without bound.
struct LineSplitter {
    static let maxLine = 1 << 20
    private var buffer = Data()
    private var discarding = false
    var bufferedBytes: Int { buffer.count }

    mutating func push(_ data: Data) -> [String] {
        buffer.append(data)
        var out: [String] = []
        var start = buffer.startIndex
        while let nl = buffer[start...].firstIndex(of: 0x0A) {
            if discarding {
                discarding = false
            } else if nl > start, nl - start <= Self.maxLine {
                out.append(String(decoding: buffer[start..<nl], as: UTF8.self))
            }
            start = buffer.index(after: nl)
        }
        buffer = Data(buffer[start...])
        if discarding || buffer.count > Self.maxLine {
            buffer = Data()
            discarding = true
        }
        return out
    }
}

/// Shared between the watch loop and its watchdog.
private final class WatchActivity: @unchecked Sendable {
    private let lock = NSLock()
    private var last = ContinuousClock.now
    private var fired = false
    func touch() { lock.lock(); last = .now; lock.unlock() }
    var idle: Duration { lock.lock(); defer { lock.unlock() }; return .now - last }
    func fire() { lock.lock(); fired = true; lock.unlock() }
    var timedOut: Bool { lock.lock(); defer { lock.unlock() }; return fired }
}

/// Follows one host's agent events: runs `shuai-agent watch --since <cursor>` over an exec
/// stream, feeds the lines to the (Rust) `AgentTracker` and publishes sessions, attention count
/// and live changes.
///
/// * Replay vs live: the agent prints a heartbeat, then replays events newer than the cursor,
///   then a `caught_up` marker. Everything before the marker is history (state only, no banners
///   or haptics). Agents that predate the marker are handled by treating the second heartbeat as
///   the boundary.
/// * Reconnect: call `attach(remote:)` again; the watch resumes at the tracker's last seq.
/// * The stream is drained continuously (a stalled exec channel would stall the whole SSH
///   session), see docs/design/architecture.md "Drain requirement".
/// * Every `reconcileInterval` the sessions are corrected from `claude agents --json`.
@MainActor @Observable
public final class AgentMonitor: PaneBadgeProvider {
    public let host: String
    public private(set) var state: AgentMonitorState = .disconnected
    /// This host's sessions, most urgent first.
    public private(set) var sessions: [FfiAgentSession] = []
    public private(set) var attentionCount = 0
    public private(set) var pendingPermissions: [PendingPermissionItem] = []
    /// Optimistic UI state of permission requests we answered and the agent has not confirmed.
    public private(set) var answering: [String: AnswerState] = [:]
    public private(set) var lastError: String?
    public private(set) var lastSeq: UInt64 = 0
    /// Presence: when the last heartbeat arrived.
    public private(set) var lastHeartbeat: Date?
    public private(set) var isReplaying = false
    public let banners: AttentionBannerQueue

    /// Called with every batch of changes from the live stream (never for replay/reconcile).
    @ObservationIgnored public var onLiveChanges: (@MainActor ([FfiTrackerChange]) -> Void)?
    /// Called after any state change (a hub can aggregate several monitors with it).
    @ObservationIgnored public var onChange: (@MainActor () -> Void)?

    @ObservationIgnored public let tracker: AgentTracker
    @ObservationIgnored private let reconcileInterval: Duration
    @ObservationIgnored private let heartbeatTimeout: Duration
    @ObservationIgnored private let now: @Sendable () -> UInt64
    @ObservationIgnored private var remote: AgentRemote?
    @ObservationIgnored private var claudePath: String?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var watchTask: Task<Void, Never>?
    @ObservationIgnored private var reconcileTask: Task<Void, Never>?
    @ObservationIgnored private var stream: AgentStream?

    public init(
        host: String,
        tracker: AgentTracker = AgentTracker(),
        banners: AttentionBannerQueue = AttentionBannerQueue(),
        reconcileInterval: Duration = .seconds(60),
        heartbeatTimeout: Duration = .seconds(25),
        now: @escaping @Sendable () -> UInt64 = { UInt64(Date().timeIntervalSince1970 * 1000) }
    ) {
        self.host = host
        self.tracker = tracker
        self.banners = banners
        self.reconcileInterval = reconcileInterval
        self.heartbeatTimeout = heartbeatTimeout
        self.now = now
    }

    // MARK: Connection lifecycle

    /// (Re)start watching over `remote`. `claudePath` (absolute, from the install probe) enables
    /// the periodic `claude agents --json` reconcile.
    public func attach(remote: AgentRemote, claudePath: String?) {
        stopTasks()
        generation += 1
        let gen = generation
        self.remote = remote
        self.claudePath = claudePath
        state = .connecting
        lastError = nil
        watchTask = Task { [weak self] in
            // A watch that went silent is torn down by its watchdog and restarted from the cursor.
            while !Task.isCancelled, let self, await self.runWatch(remote: remote, generation: gen) {}
        }
        reconcileTask = Task { [weak self] in
            await self?.reconcileLoop(remote: remote, claudePath: claudePath, generation: gen)
        }
    }

    /// Stop watching (connection closed / host disconnected). Sessions stay visible.
    public func detach() {
        stopTasks()
        generation += 1
        remote = nil
        state = .disconnected
        isReplaying = false
        publish()
    }

    private func stopTasks() {
        watchTask?.cancel()
        reconcileTask?.cancel()
        watchTask = nil
        reconcileTask = nil
        if let s = stream {
            stream = nil
            Task { await s.close() }
        }
    }

    // MARK: Watch loop

    /// Returns true when the watch was cut off by the heartbeat watchdog and should be restarted.
    private func runWatch(remote: AgentRemote, generation gen: Int) async -> Bool {
        let since = tracker.lastSeq(host: host) ?? 0
        let stream: AgentStream
        do {
            stream = try await remote.execStream(watchCommand(since: since))
        } catch {
            guard gen == generation else { return false }
            state = .failed(error.localizedDescription)
            publish()
            return false
        }
        guard gen == generation else { await stream.close(); return false }
        self.stream = stream
        let activity = WatchActivity()
        let timeout = heartbeatTimeout
        // The agent beats every 5 s; no bytes at all for `timeout` means the channel is dead.
        let watchdog = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: timeout / 4)
                guard !Task.isCancelled else { return }
                if activity.idle > timeout {
                    activity.fire()
                    await stream.close()
                    return
                }
            }
        }
        defer { watchdog.cancel() }

        var splitter = LineSplitter()
        var heartbeats = 0
        var exitStatus: Int?
        var sawExit = false
        var stderrText = ""
        isReplaying = true
        for await event in stream.events {
            guard gen == generation else { break }
            switch event {
            case .stdout(let data):
                activity.touch()
                var live: [FfiTrackerChange] = []
                for line in splitter.push(data) {
                    switch classifyWatchLine(line: line) {
                    case .heartbeat:
                        lastHeartbeat = Date()
                        heartbeats += 1
                        if isReplaying, heartbeats >= 2 { isReplaying = false }  // agent without caught_up
                        state = .watching
                    case .caughtUp:
                        isReplaying = false
                        state = .watching
                    case .event:
                        state = .watching
                        if isReplaying {
                            try? tracker.ingestReplay(line: line)
                        } else if let c = try? tracker.ingestJsonlLine(line: line) {
                            live += c
                        }
                    case .invalid:
                        break
                    }
                }
                publish()
                if !live.isEmpty { announce(live) }
            case .stderr(let data):
                if stderrText.count < 2000 { stderrText += String(decoding: data, as: UTF8.self) }
            case .exited(let status):
                sawExit = true
                exitStatus = status
            case .closed:
                break
            }
        }
        guard gen == generation else { return false }
        self.stream = nil
        isReplaying = false
        if activity.timedOut {
            state = .connecting
            publish()
            return true
        }
        if sawExit, exitStatus == 127 {
            state = .notInstalled
        } else if sawExit, exitStatus != 0 {
            let detail = stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
            state = .failed(detail.isEmpty ? "shuai-agent watch exited (\(exitStatus.map(String.init) ?? "signal"))" : detail)
        } else {
            state = .disconnected
        }
        publish()
        return false
    }

    private func announce(_ changes: [FfiTrackerChange]) {
        banners.enqueue(changes)
        onLiveChanges?(changes)
    }

    // MARK: Reconcile

    private func reconcileLoop(remote: AgentRemote, claudePath: String?, generation gen: Int) async {
        while !Task.isCancelled {
            try? await Task.sleep(for: reconcileInterval)
            guard !Task.isCancelled, gen == generation else { return }
            guard state == .watching, !isReplaying else { continue }
            if let claudePath {
                if let out = try? await remote.exec(claudeAgentsCommand(claudePath: claudePath)), out.ok,
                    gen == generation
                {
                    _ = try? tracker.applyClaudeAgentsJson(host: host, json: out.stdout, nowMs: now())
                }
                guard gen == generation else { return }
            }
            // Bounded memory on a long-running watch, with or without the claude CLI.
            _ = tracker.pruneEnded(nowMs: now(), ttlMs: 60 * 60 * 1000)
            publish()
        }
    }

    /// Mark sessions whose tmux pane vanished as ended. Call with a topology freshly read from
    /// this host.
    public func reconcile(with topology: FfiTopology) {
        _ = tracker.reconcileWithLivePanes(host: host, topology: topology, nowMs: now())
        publish()
    }

    // MARK: Permission flow

    /// Answer a permission request over exec (`shuai-agent respond`). The card shows an optimistic
    /// "answering" state; it clears when the agent's `permission_resolved` arrives. If the request
    /// was settled elsewhere first (answered in the terminal, timed out) nothing is sent, and a
    /// late send error is not reported.
    @discardableResult
    public func respond(requestId: String, allow: Bool, message: String? = nil) async -> RespondResult {
        let command: String
        do {
            command = try permissionResponseCommand(requestId: requestId, allow: allow, message: message)
        } catch {
            return fail("\(error)")
        }
        guard isPending(requestId), answering[requestId] == nil else { return .alreadyResolved }  // double tap: one answer
        guard let remote else { return fail("Not connected to \(host)") }
        answering[requestId] = allow ? .allowing : .denying
        onChange?()
        do {
            let out = try await remote.exec(command)
            if out.ok { return .sent }
            let err = out.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return settleFailure(requestId, err.isEmpty ? "shuai-agent respond failed (\(out.exitStatus.map(String.init) ?? "signal"))" : err)
        } catch {
            return settleFailure(requestId, error.localizedDescription)
        }
    }

    private func settleFailure(_ requestId: String, _ message: String) -> RespondResult {
        answering[requestId] = nil
        onChange?()
        if !isPending(requestId) { return .alreadyResolved }
        return fail(message)
    }

    private func fail(_ message: String) -> RespondResult {
        lastError = message
        return .failed(message)
    }

    private func isPending(_ requestId: String) -> Bool {
        pendingPermissions.contains { $0.request.requestId == requestId }
    }

    public func clearError() { lastError = nil }

    // MARK: Publishing

    private func publish() {
        let mine = tracker.sessions().filter { $0.host == host }
        sessions = mine
        attentionCount = mine.filter { $0.needsAttention }.count
        pendingPermissions = mine.compactMap { s in
            s.pendingPermission.map {
                PendingPermissionItem(
                    key: FfiSessionKey(host: s.host, sessionId: s.sessionId), request: $0, session: s)
            }
        }
        let pendingIDs = Set(pendingPermissions.map(\.request.requestId))
        answering = answering.filter { pendingIDs.contains($0.key) }
        lastSeq = tracker.lastSeq(host: host) ?? 0
        onChange?()
    }

    // MARK: PaneBadgeProvider

    public func badge(host: String, pane: String) -> PaneBadge? {
        guard let b = tracker.badgeForPane(host: host, pane: pane) else { return nil }
        return PaneBadge(b)
    }

    /// Next session wanting the user (⌘⇧A), after `current`.
    public func nextNeedingAttention(after current: FfiSessionKey?) -> FfiAgentSession? {
        tracker.nextNeedingAttention(after: current)
    }

    public func markSeen(_ key: FfiSessionKey) {
        if tracker.markSeen(key: key) { publish() }
    }
}

extension PaneBadge {
    init(_ b: FfiBadge) {
        switch b {
        case .idle: self = .idle
        case .working: self = .working
        case .done: self = .done
        case .failed: self = .failed
        case .needsInput: self = .needsInput
        case .needsPermission: self = .needsPermission
        }
    }
}
