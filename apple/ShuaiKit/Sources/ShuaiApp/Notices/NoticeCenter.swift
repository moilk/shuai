import Foundation
import Observation

/// What sources need from the center: post a notice, or retract it by key.
@MainActor
public protocol NoticePosting: AnyObject {
    func post(_ n: Notice)
    func retract(key: String)
}

/// Owns the notice queue and the single expiry timer. Views read `queue.visible` and own no
/// timers. Notice text is never logged.
@MainActor @Observable
public final class NoticeCenter: NoticePosting {
    public private(set) var queue = NoticeQueue()

    private static let maxSleepMs: UInt64 = 86_400_000

    @ObservationIgnored private let now: @Sendable () -> UInt64
    @ObservationIgnored private let sleep: @Sendable (UInt64) async throws -> Void
    @ObservationIgnored private let onDismiss: ((Notice) -> Void)?
    @ObservationIgnored private let onExpire: ((Notice) -> Void)?
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    /// Deadline the running timer sleeps towards; lets `rearm` keep it when nothing changed.
    @ObservationIgnored private var armedDeadline: UInt64?

    /// - Parameters:
    ///   - now: monotonic clock in milliseconds.
    ///   - sleep: sleeps for the given milliseconds, throwing on cancellation.
    ///   - onDismiss: called when the user dismisses a notice (not on expiry or retraction).
    ///   - onExpire: called for each notice that expires on its own.
    public init(
        now: @escaping @Sendable () -> UInt64,
        sleep: @escaping @Sendable (UInt64) async throws -> Void,
        onDismiss: ((Notice) -> Void)? = nil,
        onExpire: ((Notice) -> Void)? = nil
    ) {
        self.now = now
        self.sleep = sleep
        self.onDismiss = onDismiss
        self.onExpire = onExpire
    }

    deinit { timer?.cancel() }

    public func post(_ n: Notice) {
        queue.post(n, now: now())
        rearm()
    }

    public func retract(key: String) {
        queue.retract(key: key, now: now())
        rearm()
    }

    public func dismiss(id: UUID) {
        if let removed = queue.dismiss(id: id, now: now()) { onDismiss?(removed) }
        rearm()
    }

    public func removeAll(scope: Notice.Scope) {
        queue.removeAll(scope: scope, now: now())
        rearm()
    }

    public func reconcile(source: Notice.Source, with notices: [Notice]) {
        queue.reconcile(source: source, with: notices, now: now())
        rearm()
    }

    public func setFocus(_ scope: Notice.Scope?) {
        queue.setFocus(scope, now: now())
        rearm()
    }

    public func setPendingPermissionCards(_ n: Int) {
        queue.setPendingPermissionCards(n, now: now())
        rearm()
    }

    // MARK: - timer

    private func rearm() {
        let deadline = queue.nextDeadline
        if timer != nil, deadline == armedDeadline { return }
        generation += 1
        timer?.cancel()
        timer = nil
        armedDeadline = nil
        guard let deadline else { return }
        armedDeadline = deadline
        let gen = generation
        let current = now()
        // Clamped; `fire` re-arms for the remainder when it wakes before the deadline.
        let delay = min(Self.maxSleepMs, deadline > current ? deadline - current : 0)
        let sleep = sleep
        timer = Task { [weak self] in
            do { try await sleep(delay) } catch { return }
            self?.fire(gen)
        }
    }

    private func fire(_ gen: Int) {
        guard gen == generation else { return }
        timer = nil
        armedDeadline = nil
        for n in queue.expire(now: now()) { onExpire?(n) }
        rearm()
    }
}
