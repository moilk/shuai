import Foundation
import ShuaiCore

/// Drives the Rust `ReconnectPolicy` state machine: feeds it events (connect results, drops,
/// network changes, app foregrounding, user cancel) and performs the actions it returns
/// (start/restart an attempt, sleep for a backoff, cancel). The clock and the sleep are
/// injectable so tests run on a fake clock; network/foreground notifications arrive as
/// `AsyncStream`s (wire them to `NWPathMonitor` / `UIApplication.willEnterForeground`).
///
/// The controller does not own the connection: `connect` performs one attempt (and stores the
/// resulting `Connection` wherever the app keeps it) and throws on failure. When the live
/// connection ends, call ``connectionDropped()`` (e.g. after `Connection.closed()` resolves).
public actor ReconnectController {
    public typealias Attempt = @Sendable () async throws -> Void

    /// Policy state after every transition.
    public nonisolated let states: AsyncStream<FfiReconnectState>
    private let statesContinuation: AsyncStream<FfiReconnectState>.Continuation

    private let policy: ReconnectPolicy
    private let now: @Sendable () -> UInt64
    private let sleep: @Sendable (UInt64) async throws -> Void
    private let connect: Attempt
    private let networkChanges: AsyncStream<Void>?
    private let foreground: AsyncStream<Void>?

    private var attemptTask: Task<Void, Never>?
    private var backoffTask: Task<Void, Never>?
    private var listeners: [Task<Void, Never>] = []
    /// Identifies the current attempt/backoff; results of superseded ones are ignored.
    private var generation = 0
    private var connectedAtMs: UInt64?
    private var started = false

    /// - Parameters:
    ///   - now: monotonic clock in milliseconds (used to measure how long a connection lived).
    ///   - sleep: sleeps for the given milliseconds, throwing on cancellation.
    public init(
        policy: ReconnectPolicy,
        now: @escaping @Sendable () -> UInt64 = ReconnectController.monotonicMs,
        sleep: @escaping @Sendable (UInt64) async throws -> Void = { try await Task.sleep(for: .milliseconds($0)) },
        connect: @escaping Attempt,
        networkChanges: AsyncStream<Void>? = nil,
        foreground: AsyncStream<Void>? = nil
    ) {
        self.policy = policy
        self.now = now
        self.sleep = sleep
        self.connect = connect
        self.networkChanges = networkChanges
        self.foreground = foreground
        (states, statesContinuation) = AsyncStream<FfiReconnectState>.makeStream()
    }

    deinit {
        attemptTask?.cancel()
        backoffTask?.cancel()
        listeners.forEach { $0.cancel() }
        statesContinuation.finish()
    }

    @Sendable public static func monotonicMs() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds / 1_000_000
    }

    /// Maps a connect failure to the policy's failure kinds.
    public static func classify(_ error: Error) -> FfiFailureKind {
        guard let e = error as? FfiSshError else { return .other }
        switch e {
        case .Connect, .Disconnected, .ChannelClosed: return .network
        case .Timeout: return .timeout
        case .AuthFailed, .InvalidKey: return .authFailed
        case .HostKeyRejected: return .hostKeyRejected
        default: return .other
        }
    }

    /// Starts connecting (and listening for network/foreground events).
    public func start() {
        startListening()
        handle(.connect)
    }

    /// An already established connection (made by the caller) is live: the policy moves to
    /// `connected` without starting an attempt, so a later ``connectionDropped()`` reconnects
    /// with the right uptime accounting. Also starts listening for network/foreground events.
    public func adopt() {
        startListening()
        stopTimers()
        for event in [FfiReconnectEvent.connect, .connectOk] {
            _ = policy.transition(event: event)
            statesContinuation.yield(policy.state())
        }
        connectedAtMs = now()
    }

    private func startListening() {
        guard !started else { return }
        started = true
        listen(networkChanges, as: .networkChanged)
        listen(foreground, as: .appForegrounded)
    }

    /// The live connection ended unexpectedly.
    public func connectionDropped() {
        let uptime = connectedAtMs.map { now() &- $0 } ?? 0
        connectedAtMs = nil
        handle(.dropped(uptimeMs: uptime))
    }

    /// The user gave up: stops attempts and backoff timers.
    public func cancel() {
        handle(.userCancel)
    }

    // MARK: - internals

    private func listen(_ stream: AsyncStream<Void>?, as event: FfiReconnectEvent) {
        guard let stream else { return }
        listeners.append(Task { [weak self] in
            for await _ in stream {
                guard let self else { return }
                await self.handle(event)
            }
        })
    }

    private func handle(_ event: FfiReconnectEvent) {
        let action = policy.transition(event: event)
        statesContinuation.yield(policy.state())
        perform(action)
    }

    private func perform(_ action: FfiReconnectAction) {
        switch action {
        case .none:
            break
        case .startConnect:
            stopTimers()
            beginAttempt()
        case .restartConnect:
            stopTimers()
            beginAttempt()
        case .scheduleRetry(let delayMs):
            stopTimers()
            beginBackoff(delayMs)
        case .cancel:
            stopTimers()
            connectedAtMs = nil
        }
    }

    private func stopTimers() {
        generation += 1
        attemptTask?.cancel(); attemptTask = nil
        backoffTask?.cancel(); backoffTask = nil
    }

    private func beginAttempt() {
        let gen = generation
        let connect = connect
        attemptTask = Task { [weak self] in
            do {
                try await connect()
                await self?.attemptSucceeded(gen)
            } catch {
                await self?.attemptFailed(gen, error)
            }
        }
    }

    private func attemptSucceeded(_ gen: Int) {
        guard gen == generation else { return }
        attemptTask = nil
        connectedAtMs = now()
        handle(.connectOk)
    }

    private func attemptFailed(_ gen: Int, _ error: Error) {
        guard gen == generation else { return }
        attemptTask = nil
        handle(.connectFailed(kind: Self.classify(error)))
    }

    private func beginBackoff(_ delayMs: UInt64) {
        let gen = generation
        let sleep = sleep
        backoffTask = Task { [weak self] in
            do { try await sleep(delayMs) } catch { return }
            await self?.backoffElapsed(gen)
        }
    }

    private func backoffElapsed(_ gen: Int) {
        guard gen == generation else { return }
        backoffTask = nil
        handle(.backoffElapsed)
    }
}
