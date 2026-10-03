import Foundation
import ShuaiCore

// Back-pressure design (read together with the shuai-ssh crate docs)
// ------------------------------------------------------------------
// shuai-ssh requires every open channel to be drained continuously: if nobody reads a channel,
// its buffer fills and the *whole* SSH session (all channels, keepalives) stalls. So the pump
// task that reads from Rust must keep running even while the UI is busy -- but an unbounded
// Swift buffer lets `cat hugefile` while the UI is not consuming grow without limit.
//
// Terminal bytes must never be dropped, therefore:
//   1. Adjacent data chunks are coalesced in the buffer (fewer, larger events; far less
//      per-event overhead for a consumer that is behind).
//   2. The buffer is bounded in bytes (`Connection.defaultStreamBufferBytes`, 64 MiB per
//      stream). When it is full the pump stops reading from Rust until the consumer catches
//      up. That back-pressure propagates through the SSH window to the server, which is what
//      we want for a stuck UI -- but it also stalls the other channels and the keepalive of
//      this session until the consumer resumes. 64 MiB is deliberately generous so that this
//      only happens when a consumer is genuinely wedged, not during ordinary bursts.

/// An event that can flow through an ``EventQueue``.
protocol PumpEvent: Sendable {
    /// Approximate memory the event occupies (at least 1).
    var byteCost: Int { get }
    /// Last event of a stream (`.closed`).
    var isTerminal: Bool { get }
    /// Returns `self` followed by `next` as one event, or nil if they cannot be merged
    /// (different kinds, a terminal event, or the result would exceed `maxBytes`).
    func merged(with next: Self, maxBytes: Int) -> Self?
}

/// Single-producer / single-consumer queue bounded in bytes, with tail coalescing.
actor EventQueue<E: PumpEvent> {
    private var buffer: [E] = []
    private var head = 0
    private var bytes = 0
    private let capacityBytes: Int
    private let maxMergedBytes: Int
    private var finished = false
    private var cancelled = false
    private var waitingConsumer: CheckedContinuation<E?, Never>?
    private var waitingProducers: [CheckedContinuation<Void, Never>] = []

    init(capacityBytes: Int, maxMergedBytes: Int = 256 * 1024) {
        self.capacityBytes = max(capacityBytes, 1)
        self.maxMergedBytes = maxMergedBytes
    }

    /// Enqueues `event`; suspends while the buffer holds `capacityBytes` or more.
    func push(_ event: E) async {
        if cancelled { return }
        if let consumer = waitingConsumer {
            waitingConsumer = nil
            consumer.resume(returning: event)
            return
        }
        if head < buffer.count, let merged = buffer[buffer.count - 1].merged(with: event, maxBytes: maxMergedBytes) {
            bytes += merged.byteCost - buffer[buffer.count - 1].byteCost
            buffer[buffer.count - 1] = merged
        } else {
            buffer.append(event)
            bytes += event.byteCost
        }
        while bytes >= capacityBytes && !cancelled {
            await withCheckedContinuation { waitingProducers.append($0) }
        }
    }

    /// Next event; nil once the queue is finished (or cancelled) and drained.
    func pop() async -> E? {
        if head < buffer.count {
            let e = buffer[head]
            head += 1
            bytes -= e.byteCost
            if head == buffer.count {
                buffer.removeAll(keepingCapacity: true)
                head = 0
            } else if head > 1024 && head * 2 > buffer.count {
                buffer.removeFirst(head)
                head = 0
            }
            if bytes < capacityBytes { wakeProducers() }
            return e
        }
        if finished || cancelled { return nil }
        return await withCheckedContinuation { waitingConsumer = $0 }
    }

    /// No more events will be pushed; the consumer drains what is buffered, then gets nil.
    func finish() {
        finished = true
        if let c = waitingConsumer {
            waitingConsumer = nil
            c.resume(returning: nil)
        }
    }

    /// The consumer is gone: discard everything and release a blocked producer.
    func cancel() {
        cancelled = true
        buffer.removeAll()
        head = 0
        bytes = 0
        if let c = waitingConsumer {
            waitingConsumer = nil
            c.resume(returning: nil)
        }
        wakeProducers()
    }

    private func wakeProducers() {
        let ps = waitingProducers
        waitingProducers.removeAll()
        for p in ps { p.resume() }
    }
}

/// Owns a pump task and the queue it feeds; shuts both (and the underlying Rust stream) down
/// when the consumer cancels or when the last reference goes away.
///
/// Reference graph (no cycles): `Shell`/`ExecSession` -> core; the `events` stream closures ->
/// core; core -> task, queue, owner. The task captures only the queue and the `next`
/// closure, never the core, so dropping every reference to the core really deinitialises it.
final class PumpCore<E: PumpEvent>: @unchecked Sendable {
    let queue: EventQueue<E>
    private let task: Task<Void, Never>
    private let close: @Sendable () async -> Void
    /// Keeps e.g. the `Connection` alive while a stream of it is in use.
    private let owner: AnyObject?
    private let lock = NSLock()
    private var isShutDown = false
    private var _events: AsyncThrowingStream<E, Error>?

    init(
        capacityBytes: Int,
        maxMergedBytes: Int = 256 * 1024,
        owner: AnyObject?,
        next: @escaping @Sendable () async -> E,
        close: @escaping @Sendable () async -> Void
    ) {
        let queue = EventQueue<E>(capacityBytes: capacityBytes, maxMergedBytes: maxMergedBytes)
        self.queue = queue
        self.close = close
        self.owner = owner
        self.task = Task.detached {
            while !Task.isCancelled {
                let event = await next()
                await queue.push(event)
                if event.isTerminal { break }
            }
            await queue.finish()
        }
    }

    /// Events in order, ending after the terminal event. Cancelling the consumer shuts the
    /// core down. (The stream references the core, so keep either alive to keep it running.)
    var events: AsyncThrowingStream<E, Error> {
        lock.lock(); defer { lock.unlock() }
        if let e = _events { return e }
        let e = AsyncThrowingStream<E, Error>(
            unfolding: { [self] in await queue.pop() },
            onCancel: { [self] in shutdown() })
        _events = e
        return e
    }

    func shutdown() {
        lock.lock()
        if isShutDown { lock.unlock(); return }
        isShutDown = true
        lock.unlock()
        task.cancel()
        let queue = queue, close = close
        Task.detached {
            await queue.cancel()
            await close()
        }
    }

    deinit {
        // `_events` closures hold `self`, so reaching deinit means no stream is alive either.
        shutdown()
    }
}

extension ShellEvent: PumpEvent {
    var byteCost: Int {
        if case .data(let b) = self { return max(b.count, 1) }
        return 64
    }
    var isTerminal: Bool {
        if case .closed = self { return true }
        return false
    }
    func merged(with next: ShellEvent, maxBytes: Int) -> ShellEvent? {
        guard case .data(let a) = self, case .data(let b) = next, a.count + b.count <= maxBytes else { return nil }
        return .data(bytes: a + b)
    }
}

extension ExecEvent: PumpEvent {
    var byteCost: Int {
        switch self {
        case .stdout(let b), .stderr(let b): return max(b.count, 1)
        default: return 64
        }
    }
    var isTerminal: Bool {
        if case .closed = self { return true }
        return false
    }
    func merged(with next: ExecEvent, maxBytes: Int) -> ExecEvent? {
        switch (self, next) {
        case (.stdout(let a), .stdout(let b)) where a.count + b.count <= maxBytes: return .stdout(bytes: a + b)
        case (.stderr(let a), .stderr(let b)) where a.count + b.count <= maxBytes: return .stderr(bytes: a + b)
        default: return nil
        }
    }
}
