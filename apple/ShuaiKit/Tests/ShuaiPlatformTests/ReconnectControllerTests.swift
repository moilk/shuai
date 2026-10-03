import Foundation
import Testing
import ShuaiCore
@testable import ShuaiPlatform

/// Deterministic clock: `sleep` suspends until `advance` moves time past the deadline.
private final class FakeClock: @unchecked Sendable {
    private struct Sleeper {
        let id: Int
        let deadline: UInt64
        let cont: CheckedContinuation<Void, Error>
    }
    private let lock = NSLock()
    private var nowMs: UInt64 = 0
    private var sleepers: [Sleeper] = []
    private var nextId = 0
    private var _requested: [UInt64] = []

    var now: UInt64 { lock.lock(); defer { lock.unlock() }; return nowMs }
    var requested: [UInt64] { lock.lock(); defer { lock.unlock() }; return _requested }
    var sleeping: Int { lock.lock(); defer { lock.unlock() }; return sleepers.count }

    func sleep(_ ms: UInt64) async throws {
        let id: Int = lock.withLock { nextId += 1; return nextId }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                lock.lock()
                _requested.append(ms)
                if Task.isCancelled {
                    lock.unlock()
                    c.resume(throwing: CancellationError())
                    return
                }
                sleepers.append(Sleeper(id: id, deadline: nowMs + ms, cont: c))
                lock.unlock()
            }
        } onCancel: {
            lock.lock()
            let s = sleepers.first { $0.id == id }
            sleepers.removeAll { $0.id == id }
            lock.unlock()
            s?.cont.resume(throwing: CancellationError())
        }
    }

    func advance(_ ms: UInt64) {
        lock.lock()
        nowMs += ms
        let due = sleepers.filter { $0.deadline <= nowMs }
        sleepers.removeAll { $0.deadline <= nowMs }
        lock.unlock()
        for s in due { s.cont.resume() }
    }
}

/// Connect attempts the test completes by hand.
private final class Attempts: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [CheckedContinuation<Void, Error>] = []
    private var _started = 0
    var started: Int { lock.withLock { _started } }

    func attempt() async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            lock.lock(); _started += 1; pending.append(c); lock.unlock()
        }
    }
    func finish(_ result: Result<Void, Error>) {
        let c: CheckedContinuation<Void, Error>? = lock.withLock { pending.isEmpty ? nil : pending.removeFirst() }
        c?.resume(with: result)
    }
}

private actor Recorder {
    var states: [FfiReconnectState] = []
    func add(_ s: FfiReconnectState) { states.append(s) }
}

private struct Harness {
    let clock = FakeClock()
    let attempts = Attempts()
    let recorder = Recorder()
    let network: AsyncStream<Void>.Continuation
    let foreground: AsyncStream<Void>.Continuation
    let controller: ReconnectController

    init(maxAttempts: UInt32? = nil) {
        let (netStream, net) = AsyncStream<Void>.makeStream()
        let (fgStream, fg) = AsyncStream<Void>.makeStream()
        network = net
        foreground = fg
        let clock = clock, attempts = attempts
        controller = ReconnectController(
            policy: ReconnectPolicy(maxAttempts: maxAttempts, jitter: false),
            now: { clock.now },
            sleep: { try await clock.sleep($0) },
            connect: { try await attempts.attempt() },
            networkChanges: netStream,
            foreground: fgStream)
        let recorder = recorder, states = controller.states
        Task { for await s in states { await recorder.add(s) } }
    }

    func waitFor(_ s: FfiReconnectState, timeout: Duration = .seconds(5)) async -> Bool {
        let c = ContinuousClock(); let end = c.now + timeout
        while c.now < end {
            if await recorder.states.last == s { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }
    func waitUntil(timeout: Duration = .seconds(5), _ cond: @Sendable () -> Bool) async -> Bool {
        let c = ContinuousClock(); let end = c.now + timeout
        while c.now < end {
            if cond() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return cond()
    }
}

@Suite(.timeLimit(.minutes(1))) struct ReconnectControllerTests {
    @Test func connectsOnFirstTry() async {
        let h = Harness()
        await h.controller.start()
        #expect(await h.waitFor(.connecting(attempt: 1)))
        h.attempts.finish(.success(()))
        #expect(await h.waitFor(.connected(attempt: 1)))
        #expect(h.clock.requested.isEmpty)
    }

    @Test func retriesWithExponentialBackoffOnTheInjectedClock() async {
        let h = Harness()
        await h.controller.start()
        #expect(await h.waitUntil { h.attempts.started == 1 })
        h.attempts.finish(.failure(FfiSshError.Connect(message: "down")))
        #expect(await h.waitFor(.backoff(attempt: 1, delayMs: 1000)))
        #expect(await h.waitUntil { h.clock.sleeping == 1 })
        h.clock.advance(999)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(h.attempts.started == 1, "must not retry before the delay elapsed")
        h.clock.advance(1)
        #expect(await h.waitUntil { h.attempts.started == 2 })
        #expect(await h.waitFor(.connecting(attempt: 2)))
        h.attempts.finish(.failure(FfiSshError.Timeout))
        #expect(await h.waitFor(.backoff(attempt: 2, delayMs: 2000)))
        #expect(h.clock.requested == [1000, 2000])
        #expect(await h.waitUntil { h.clock.sleeping == 1 })
        h.clock.advance(2000)
        #expect(await h.waitUntil { h.attempts.started == 3 })
        h.attempts.finish(.success(()))
        #expect(await h.waitFor(.connected(attempt: 3)))
    }

    @Test func authFailureGivesUpWithoutSleeping() async {
        let h = Harness()
        await h.controller.start()
        #expect(await h.waitUntil { h.attempts.started == 1 })
        h.attempts.finish(.failure(FfiSshError.AuthFailed(triedMethods: ["password"])))
        #expect(await h.waitFor(.gaveUp))
        #expect(h.clock.requested.isEmpty)
    }

    @Test func hostKeyRejectionGivesUp() async {
        let h = Harness()
        await h.controller.start()
        #expect(await h.waitUntil { h.attempts.started == 1 })
        h.attempts.finish(.failure(FfiSshError.HostKeyRejected))
        #expect(await h.waitFor(.gaveUp))
    }

    @Test func networkChangeDuringBackoffRetriesImmediately() async {
        let h = Harness()
        await h.controller.start()
        #expect(await h.waitUntil { h.attempts.started == 1 })
        h.attempts.finish(.failure(FfiSshError.Disconnected))
        #expect(await h.waitFor(.backoff(attempt: 1, delayMs: 1000)))
        #expect(await h.waitUntil { h.clock.sleeping == 1 })
        h.network.yield()
        #expect(await h.waitUntil { h.attempts.started == 2 })
        #expect(await h.waitFor(.connecting(attempt: 1)))
        #expect(h.clock.sleeping == 0, "backoff sleep must be cancelled")
    }

    @Test func foregroundDuringConnectingRestartsTheAttemptAndIgnoresTheStaleResult() async {
        let h = Harness()
        await h.controller.start()
        #expect(await h.waitUntil { h.attempts.started == 1 })
        h.foreground.yield()
        #expect(await h.waitUntil { h.attempts.started == 2 })
        // The first (stale) attempt fails late: it must not disturb the restarted one.
        h.attempts.finish(.failure(FfiSshError.Timeout))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await h.recorder.states.last == .connecting(attempt: 1))
        h.attempts.finish(.success(()))
        #expect(await h.waitFor(.connected(attempt: 1)))
    }

    @Test func foregroundWhileConnectedDoesNothing() async {
        let h = Harness()
        await h.controller.start()
        #expect(await h.waitUntil { h.attempts.started == 1 })
        h.attempts.finish(.success(()))
        #expect(await h.waitFor(.connected(attempt: 1)))
        h.foreground.yield()
        h.network.yield()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(h.attempts.started == 1)
        #expect(await h.recorder.states.last == .connected(attempt: 1))
    }

    @Test func stableConnectionDropReconnectsImmediately() async {
        let h = Harness()
        await h.controller.start()
        #expect(await h.waitUntil { h.attempts.started == 1 })
        h.attempts.finish(.success(()))
        #expect(await h.waitFor(.connected(attempt: 1)))
        h.clock.advance(60_000)
        await h.controller.connectionDropped()
        #expect(await h.waitUntil { h.attempts.started == 2 })
        #expect(h.clock.requested.isEmpty)
    }

    @Test func quickDropBacksOffForAtLeastTheMinimumDelay() async {
        let h = Harness()
        await h.controller.start()
        #expect(await h.waitUntil { h.attempts.started == 1 })
        h.attempts.finish(.success(()))
        #expect(await h.waitFor(.connected(attempt: 1)))
        h.clock.advance(100)
        await h.controller.connectionDropped()
        #expect(await h.waitFor(.backoff(attempt: 1, delayMs: 1000)))
        #expect(await h.waitUntil { h.clock.sleeping == 1 })
    }

    @Test func cancelStopsEverythingAndReturnsToIdle() async {
        let h = Harness()
        await h.controller.start()
        #expect(await h.waitUntil { h.attempts.started == 1 })
        h.attempts.finish(.failure(FfiSshError.Timeout))
        #expect(await h.waitUntil { h.clock.sleeping == 1 })
        await h.controller.cancel()
        #expect(await h.waitFor(.idle))
        #expect(h.clock.sleeping == 0)
        h.network.yield()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(h.attempts.started == 1, "events after cancel are ignored")
    }

    @Test func maxAttemptsGivesUp() async {
        let h = Harness(maxAttempts: 1)
        await h.controller.start()
        #expect(await h.waitUntil { h.attempts.started == 1 })
        h.attempts.finish(.failure(FfiSshError.Timeout))
        #expect(await h.waitFor(.gaveUp))
    }

    @Test func errorsAreClassifiedForThePolicy() {
        #expect(ReconnectController.classify(FfiSshError.Timeout) == .timeout)
        #expect(ReconnectController.classify(FfiSshError.Connect(message: "x")) == .network)
        #expect(ReconnectController.classify(FfiSshError.Disconnected) == .network)
        #expect(ReconnectController.classify(FfiSshError.AuthFailed(triedMethods: [])) == .authFailed)
        #expect(ReconnectController.classify(FfiSshError.HostKeyRejected) == .hostKeyRejected)
        #expect(ReconnectController.classify(FfiSshError.InvalidKey(message: "x")) == .authFailed)
        #expect(ReconnectController.classify(FfiSshError.Protocol(message: "x")) == .other)
        #expect(ReconnectController.classify(CancellationError()) == .other)
    }
}
