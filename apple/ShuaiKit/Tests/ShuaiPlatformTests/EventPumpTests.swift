import Foundation
import Testing
@testable import ShuaiPlatform

private struct Ev: PumpEvent, Equatable {
    var bytes: [UInt8]
    var mergeable = true
    var isTerminal = false
    var byteCost: Int { max(bytes.count, 1) }

    func merged(with next: Ev, maxBytes: Int) -> Ev? {
        guard mergeable, next.mergeable, !isTerminal, !next.isTerminal,
              bytes.count + next.bytes.count <= maxBytes else { return nil }
        return Ev(bytes: bytes + next.bytes)
    }
}

private actor Counter {
    var n = 0
    func bump() { n += 1 }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var v = false
    func set() { lock.lock(); v = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return v }
}

private func eventually(timeout: Duration = .seconds(5), _ cond: @Sendable () async -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if await cond() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await cond()
}

@Suite(.timeLimit(.minutes(1))) struct EventQueueTests {
    @Test func adjacentChunksAreCoalescedWhileConsumerIsBehind() async {
        let q = EventQueue<Ev>(capacityBytes: 1 << 20, maxMergedBytes: 1 << 20)
        for i in 0..<10 { await q.push(Ev(bytes: [UInt8(i), UInt8(i), UInt8(i)])) }
        await q.finish()
        let first = await q.pop()
        #expect(first?.bytes.count == 30)
        #expect(first?.bytes.prefix(6) == [0, 0, 0, 1, 1, 1])
        #expect(await q.pop() == nil)
    }

    @Test func coalescingRespectsTheMergeLimitAndKeepsEveryByteInOrder() async {
        let q = EventQueue<Ev>(capacityBytes: 1 << 20, maxMergedBytes: 250)
        var expected: [UInt8] = []
        for i in 0..<10 {
            let chunk = [UInt8](repeating: UInt8(i), count: 100)
            expected += chunk
            await q.push(Ev(bytes: chunk))
        }
        await q.finish()
        var got: [UInt8] = []
        var events = 0
        while let e = await q.pop() {
            #expect(e.bytes.count <= 250)
            got += e.bytes
            events += 1
        }
        #expect(got == expected)
        #expect(events >= 4)
    }

    @Test func terminalEventsAreNeverMerged() async {
        let q = EventQueue<Ev>(capacityBytes: 1 << 20, maxMergedBytes: 1 << 20)
        await q.push(Ev(bytes: [1]))
        await q.push(Ev(bytes: [], isTerminal: true))
        await q.finish()
        #expect(await q.pop()?.bytes == [1])
        #expect(await q.pop()?.isTerminal == true)
        #expect(await q.pop() == nil)
    }

    @Test func producerWaitsWhenBufferIsFullAndNothingIsDropped() async {
        let q = EventQueue<Ev>(capacityBytes: 1000, maxMergedBytes: 1000)
        let pushed = Counter()
        let producer = Task {
            for i in 0..<500 {
                await q.push(Ev(bytes: [UInt8(i % 256)] + [UInt8](repeating: 0, count: 99), mergeable: false))
                await pushed.bump()
            }
            await q.finish()
        }
        try? await Task.sleep(for: .milliseconds(150))
        // 1000 bytes / 100 per event = 10 buffered, plus the one whose push is suspended.
        #expect(await pushed.n <= 11)
        var seen = 0
        while let e = await q.pop() {
            #expect(e.bytes[0] == UInt8(seen % 256))
            seen += 1
        }
        #expect(seen == 500)
        await producer.value
    }

    @Test func cancelWakesABlockedProducerAndDiscardsBuffer() async {
        let q = EventQueue<Ev>(capacityBytes: 100, maxMergedBytes: 100)
        let done = Flag()
        let producer = Task {
            for _ in 0..<100 { await q.push(Ev(bytes: [UInt8](repeating: 1, count: 100), mergeable: false)) }
            done.set()
        }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(!done.isSet)
        await q.cancel()
        await producer.value
        #expect(done.isSet)
        #expect(await q.pop() == nil)
    }

    @Test func finishWakesAWaitingConsumer() async {
        let q = EventQueue<Ev>(capacityBytes: 100, maxMergedBytes: 100)
        let consumer = Task { await q.pop() }
        try? await Task.sleep(for: .milliseconds(30))
        await q.finish()
        #expect(await consumer.value == nil)
    }
}

@Suite(.timeLimit(.minutes(1))) struct PumpCoreTests {
    private func source(count: Int, size: Int, produced: Counter? = nil) -> @Sendable () async -> Ev {
        let state = Counter()
        return {
            let i = await state.n
            await state.bump()
            await produced?.bump()
            if i >= count { return Ev(bytes: [], isTerminal: true) }
            return Ev(bytes: [UInt8](repeating: UInt8(i % 256), count: size), mergeable: false)
        }
    }

    @Test func deliversEverythingInOrderThroughASmallBuffer() async throws {
        let core = PumpCore<Ev>(
            capacityBytes: 500, maxMergedBytes: 500, owner: nil,
            next: source(count: 200, size: 100), close: {})
        var seen = 0
        for try await e in core.events {
            if e.isTerminal { break }
            #expect(e.bytes[0] == UInt8(seen % 256))
            seen += 1
            if seen % 50 == 0 { try await Task.sleep(for: .milliseconds(5)) }
        }
        #expect(seen == 200)
    }

    @Test func slowConsumerBoundsTheMemoryTheProducerCanBuffer() async throws {
        let produced = Counter()
        let core = PumpCore<Ev>(
            capacityBytes: 1000, maxMergedBytes: 1000, owner: nil,
            next: source(count: 10_000, size: 100, produced: produced), close: {})
        try await Task.sleep(for: .milliseconds(200))
        #expect(await produced.n <= 13)  // ~10 buffered + in flight
        _ = core
    }

    @Test func streamEndsAfterTheTerminalEvent() async throws {
        let core = PumpCore<Ev>(
            capacityBytes: 1 << 20, maxMergedBytes: 1 << 20, owner: nil,
            next: source(count: 3, size: 4), close: {})
        var events: [Ev] = []
        for try await e in core.events { events.append(e) }
        #expect(events.last?.isTerminal == true)
        #expect(events.dropLast().flatMap(\.bytes).count == 12)
    }

    @Test func releasingEverythingStopsThePumpAndClosesTheStream() async {
        let closed = Flag()
        let produced = Counter()
        var core: PumpCore<Ev>? = PumpCore<Ev>(
            capacityBytes: 1000, maxMergedBytes: 1000, owner: nil,
            next: {
                await produced.bump()
                try? await Task.sleep(for: .milliseconds(5))
                return Ev(bytes: [1], mergeable: false)
            },
            close: { closed.set() })
        _ = await eventually { await produced.n > 0 }
        core = nil
        #expect(await eventually { closed.isSet })
        let a = await produced.n
        try? await Task.sleep(for: .milliseconds(100))
        let b = await produced.n
        #expect(b - a <= 2, "pump kept running after dealloc")
        _ = core
    }

    @Test func consumerCancellationShutsDownTheCore() async {
        let closed = Flag()
        let core = PumpCore<Ev>(
            capacityBytes: 100, maxMergedBytes: 100, owner: nil,
            next: {
                try? await Task.sleep(for: .milliseconds(5))
                return Ev(bytes: [1], mergeable: false)
            },
            close: { closed.set() })
        let events = core.events
        let consumer = Task { for try await _ in events {} }
        try? await Task.sleep(for: .milliseconds(50))
        consumer.cancel()
        _ = try? await consumer.value
        #expect(await eventually { closed.isSet })
    }

    @Test func coreKeepsItsOwnerAliveAndReleasesItOnShutdown() async {
        final class Owner {}
        weak var weakOwner: Owner?
        var core: PumpCore<Ev>?
        do {
            let owner = Owner()
            weakOwner = owner
            core = PumpCore<Ev>(
                capacityBytes: 100, maxMergedBytes: 100, owner: owner,
                next: {
                    try? await Task.sleep(for: .milliseconds(5))
                    return Ev(bytes: [1], mergeable: false)
                },
                close: {})
        }
        #expect(weakOwner != nil)
        core = nil
        #expect(await eventually { weakOwner == nil })
        _ = core
    }
}
