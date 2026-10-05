import Foundation
import Testing
import ShuaiCore
@testable import ShuaiApp

private func notice(
    _ text: String = "hello",
    severity: Notice.Severity = .info,
    source: Notice.Source = .app,
    scope: Notice.Scope = .app,
    key: String? = nil,
    lifetime: Notice.Lifetime = .auto
) -> Notice {
    Notice(severity: severity, source: source, scope: scope, text: text, symbol: "info.circle",
           key: key ?? UUID().uuidString, lifetime: lifetime)
}

@Suite("Notice sanitize")
struct NoticeSanitizeTests {
    @Test func textIsSanitizedAndCapped() {
        let long = String(repeating: "a", count: 500)
        let n = Notice(severity: .info, source: .terminal, title: String(repeating: "t", count: 200),
                       text: long, symbol: "bell", key: "k")
        #expect(n.text.count == 300)
        #expect(n.text.hasSuffix("…"))
        #expect(n.title?.count == 80)
        #expect(Notice.sanitize("short", limit: 10) == "short")
        #expect(Notice.sanitize("abcdef", limit: 4) == "abc…")
        #expect(Notice.sanitize("👨‍👩‍👧👨‍👩‍👧👨‍👩‍👧", limit: 2) == "👨‍👩‍👧…")
    }

    @Test func bidiOverridesAreStripped() {
        let s = "a\u{202A}b\u{202B}c\u{202C}d\u{202D}e\u{202E}f\u{2066}g\u{2067}h\u{2068}i\u{2069}j"
        #expect(Notice.sanitize(s, limit: 100) == "abcdefghij")
    }

    @Test func controlCharsAndNewlinesCollapsed() {
        #expect(Notice.sanitize("a\u{1B}[31mb\u{07}\u{0}c", limit: 100) == "a[31mbc")
        #expect(Notice.sanitize("a\n\nb\tc\r\nd", limit: 100) == "a b c d")
        #expect(Notice.sanitize("x\u{85}y\u{9B}z", limit: 100) == "xyz")
        #expect(Notice.sanitize("   a    b   ", limit: 100) == "a b")
        #expect(Notice.sanitize("\n\t ", limit: 100) == "")
    }

    @Test func accessibilityIdentifierPerSourceMatchesLegacyIds() {
        func id(_ s: Notice.Source) -> String { notice(source: s).accessibilityIdentifier }
        #expect(id(.app) == "session-notice")
        #expect(id(.deepLink) == "session-notice")
        #expect(id(.session) == "session-notice")
        #expect(id(.tmux) == "session-notice")
        #expect(id(.terminal) == "notification-banner")
        #expect(id(.agent) == "agent-banner")
    }

    @Test func durationGrowsWithSeverityAndLength() {
        func d(_ sev: Notice.Severity, _ chars: Int, _ life: Notice.Lifetime = .auto) -> UInt64? {
            notice(String(repeating: "x", count: chars), severity: sev, lifetime: life).duration
        }
        #expect(d(.info, 10) == 5000)
        #expect(d(.success, 10) == 5000)
        #expect(d(.attention, 10) == 6000)
        #expect(d(.warning, 10) == 8000)
        #expect(d(.error, 10) == 10000)
        #expect(d(.info, 200) == 12000)
        #expect(d(.info, 300) == 15000)
        #expect(d(.error, 300) == 15000)
        #expect(d(.info, 10, .autoAfter(ms: 1234)) == 1234)
    }

    @Test func stickyHasNoDeadline() {
        let n = notice(lifetime: .sticky)
        #expect(n.duration == nil)
        var q = NoticeQueue()
        q.post(n, now: 0)
        #expect(q.nextDeadline == nil)
        q.expire(now: 10_000_000)
        #expect(q.visible.count == 1)
    }
}

@Suite("NoticeQueue")
struct NoticeQueueTests {
    @Test func visibleOrderedBySeverityThenRecency() {
        var q = NoticeQueue()
        q.post(notice("old info", severity: .info), now: 0)
        q.post(notice("error", severity: .error), now: 1)
        q.post(notice("new info", severity: .info), now: 2)
        #expect(q.visible.map(\.text) == ["error", "new info", "old info"])
    }

    @Test func atMostThreeVisibleWithHiddenCount() {
        var q = NoticeQueue()
        for i in 0..<5 { q.post(notice("n\(i)"), now: UInt64(i)) }
        #expect(q.visible.count == 3)
        #expect(q.hiddenCount == 2)
        #expect(q.visible.map(\.text) == ["n4", "n3", "n2"])
    }

    @Test func pendingPermissionCardsLimitVisibleToOne() {
        var q = NoticeQueue()
        q.post(notice("a"), now: 0)
        q.post(notice("b", severity: .warning), now: 0)
        q.post(notice("c"), now: 0)
        q.setPendingPermissionCards(2, now: 0)
        #expect(q.visible.map(\.text) == ["b"])
        #expect(q.hiddenCount == 2)
        q.setPendingPermissionCards(0, now: 0)
        #expect(q.visible.count == 3)
        #expect(q.hiddenCount == 0)
    }

    @Test func sameKeyReplacesAndRestartsTimer() {
        var q = NoticeQueue()
        q.post(notice("first", key: "k"), now: 0)
        #expect(q.nextDeadline == 5000)
        q.post(notice("second", key: "k"), now: 3000)
        #expect(q.visible.count == 1)
        #expect(q.visible[0].text == "second")
        #expect(q.visible[0].count == 1)
        #expect(q.nextDeadline == 8000)
    }

    @Test func identicalRepostIncrementsCount() {
        var q = NoticeQueue()
        let first = notice("same", key: "k")
        q.post(first, now: 0)
        q.post(notice("same", key: "k"), now: 1000)
        q.post(notice("same", key: "k"), now: 2000)
        #expect(q.visible.count == 1)
        #expect(q.visible[0].count == 3)
        #expect(q.visible[0].id == first.id)
        #expect(q.nextDeadline == 7000)
    }

    @Test func identicalRepostWithinOneSecondKeepsDeadline() {
        var q = NoticeQueue()
        q.post(notice("same", key: "k"), now: 0)
        #expect(q.nextDeadline == 5000)
        q.post(notice("same", key: "k"), now: 400)
        q.post(notice("same", key: "k"), now: 900)
        #expect(q.visible[0].count == 3)
        #expect(q.nextDeadline == 5000)
        // A repost a second after the previous one restarts the timer.
        q.post(notice("same", key: "k"), now: 1900)
        #expect(q.nextDeadline == 6900)
    }

    @Test func scopeHidesOtherHosts() {
        let a = UUID(), b = UUID()
        var q = NoticeQueue()
        q.post(notice("app"), now: 0)
        q.post(notice("host a", scope: .host(a)), now: 0)
        q.post(notice("host b", scope: .host(b)), now: 0)
        #expect(q.visible.map(\.text) == ["app"])
        q.setFocus(.host(a), now: 0)
        #expect(Set(q.visible.map(\.text)) == ["app", "host a"])
        #expect(q.hiddenCount == 0)
        q.setFocus(nil, now: 0)
        #expect(q.visible.map(\.text) == ["app"])
    }

    @Test func timerStartsWhenFirstVisible() {
        let a = UUID()
        var q = NoticeQueue()
        q.post(notice("hidden", scope: .host(a)), now: 0)
        #expect(q.nextDeadline == nil)
        q.setFocus(.host(a), now: 4000)
        #expect(q.nextDeadline == 9000)
        // Losing visibility keeps the armed deadline.
        q.setFocus(nil, now: 5000)
        #expect(q.nextDeadline == 9000)
        q.setFocus(.host(a), now: 6000)
        #expect(q.nextDeadline == 9000)
    }

    @Test func overflowFreedArmsHiddenNotice() {
        var q = NoticeQueue()
        for i in 0..<3 { q.post(notice("n\(i)", severity: .warning), now: 0) }
        q.post(notice("late", severity: .info), now: 0)
        #expect(q.hiddenCount == 1)
        #expect(q.nextDeadline == 8000)
        q.expire(now: 8000)
        #expect(q.visible.map(\.text) == ["late"])
        #expect(q.nextDeadline == 13000)
    }

    @Test func expireRemovesOnlyDueAutoNotices() {
        var q = NoticeQueue()
        q.post(notice("short", severity: .info), now: 0)
        q.post(notice("long", severity: .error), now: 0)
        q.post(notice("sticky", lifetime: .sticky), now: 0)
        q.expire(now: 5000)
        #expect(Set(q.visible.map(\.text)) == ["long", "sticky"])
        #expect(q.nextDeadline == 10000)
        q.expire(now: 10000)
        #expect(q.visible.map(\.text) == ["sticky"])
        #expect(q.nextDeadline == nil)
    }

    @Test func retractByKey() {
        var q = NoticeQueue()
        q.post(notice("a", key: "x"), now: 0)
        q.post(notice("b", key: "y"), now: 0)
        q.retract(key: "x", now: 0)
        #expect(q.visible.map(\.text) == ["b"])
    }

    @Test func dismissRemovesAndReturnsNotice() {
        var q = NoticeQueue()
        let n = notice("a")
        q.post(n, now: 0)
        let removed = q.dismiss(id: n.id, now: 0)
        #expect(removed?.id == n.id)
        #expect(q.visible.isEmpty)
        #expect(q.dismiss(id: n.id, now: 0) == nil)
    }

    @Test func removeAllForHost() {
        let a = UUID()
        var q = NoticeQueue()
        q.post(notice("app"), now: 0)
        q.post(notice("host", scope: .host(a)), now: 0)
        q.removeAll(scope: .host(a), now: 0)
        q.setFocus(.host(a), now: 0)
        #expect(q.visible.map(\.text) == ["app"])
    }

    @Test func capacityDropsOldestLowestSeverity() {
        var q = NoticeQueue()
        q.post(notice("keep error", severity: .error, scope: .host(UUID())), now: 0)
        q.post(notice("oldest info", severity: .info, scope: .host(UUID())), now: 0)
        for i in 0..<18 { q.post(notice("n\(i)", severity: .info, scope: .host(UUID())), now: 0) }
        #expect(q.count == 20)
        q.post(notice("overflow", severity: .warning, scope: .host(UUID())), now: 0)
        #expect(q.count == 20)
        let texts = q.allNotices.map(\.text)
        #expect(!texts.contains("oldest info"))
        #expect(texts.contains("keep error"))
        #expect(texts.contains("overflow"))
        #expect(texts.contains("n17"))
    }

    @Test func reconcileAddsAndRetracts() {
        var q = NoticeQueue()
        let a = notice("a", source: .agent, key: "a"), b = notice("b", source: .agent, key: "b")
        let other = notice("other", source: .tmux, key: "t")
        q.post(other, now: 0)
        q.reconcile(source: .agent, with: [a, b], now: 0)
        #expect(Set(q.visible.map(\.text)) == ["a", "b", "other"])
        q.reconcile(source: .agent, with: [b], now: 1)
        #expect(Set(q.visible.map(\.text)) == ["b", "other"])
        // An unchanged notice is not counted again.
        #expect(q.visible.first { $0.text == "b" }?.count == 1)
    }

    @Test func reconcileDoesNotResurrectDismissed() {
        var q = NoticeQueue()
        let a = notice("a", source: .agent, key: "a")
        q.reconcile(source: .agent, with: [a], now: 0)
        _ = q.dismiss(id: a.id, now: 1)
        q.reconcile(source: .agent, with: [a], now: 2)
        #expect(q.visible.isEmpty)
    }
}

@MainActor
@Suite("NoticeCenter")
struct NoticeCenterTests {
    final class Dismissed: @unchecked Sendable { var ids: [UUID] = [] }

    private func make(_ clock: FakeClock, _ dismissed: Dismissed = Dismissed()) -> NoticeCenter {
        NoticeCenter(now: { clock.now }, sleep: { try await clock.sleep($0) },
                     onDismiss: { dismissed.ids.append($0.id) })
    }

    @Test func autoNoticeExpiresAfterInjectedSleep() async {
        let clock = FakeClock()
        let center = make(clock)
        center.post(notice("hi"))
        #expect(await waitUntil { clock.sleeping == 1 })
        #expect(clock.requested == [5000])
        clock.advance(5000)
        #expect(await waitUntil { center.queue.visible.isEmpty })
        #expect(await waitUntil { clock.sleeping == 0 })
    }

    @Test func dismissCancelsTimer() async {
        let clock = FakeClock()
        let dismissed = Dismissed()
        let center = make(clock, dismissed)
        let n = notice("hi")
        center.post(n)
        #expect(await waitUntil { clock.sleeping == 1 })
        center.dismiss(id: n.id)
        #expect(await waitUntil { clock.sleeping == 0 })
        #expect(center.queue.visible.isEmpty)
        #expect(dismissed.ids == [n.id])
    }

    @Test func rearmIsSkippedWhenDeadlineUnchanged() async {
        let clock = FakeClock()
        let center = make(clock)
        center.post(notice("same", key: "k"))
        #expect(await waitUntil { clock.sleeping == 1 })
        for _ in 0..<20 { center.post(notice("same", key: "k")) }
        center.setFocus(nil)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(clock.requested == [5000])
        #expect(clock.sleeping == 1)
        #expect(center.queue.visible.first?.count == 21)
    }

    @Test func focusChangeArmsHiddenNotice() async {
        let clock = FakeClock()
        let center = make(clock)
        let host = UUID()
        center.post(notice("hidden", scope: .host(host)))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(clock.sleeping == 0)
        center.setFocus(.host(host))
        #expect(await waitUntil { clock.sleeping == 1 })
    }

    @Test func centerConformsToNoticePosting() {
        let center = make(FakeClock())
        let poster: NoticePosting = center
        poster.post(notice("x", key: "k"))
        #expect(center.queue.visible.count == 1)
        poster.retract(key: "k")
        #expect(center.queue.visible.isEmpty)
    }
}

// MARK: - review cases

/// A sleep that ignores cancellation, released by hand.
private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [CheckedContinuation<Void, Never>] = []
    var waiting: Int { lock.withLock { waiters.count } }
    func wait() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lock.withLock { waiters.append(c) }
        }
    }
    func releaseFirst() {
        let c: CheckedContinuation<Void, Never>? = lock.withLock { waiters.isEmpty ? nil : waiters.removeFirst() }
        c?.resume()
    }
}

@Suite("Notice review cases")
struct NoticeReviewTests {
    @Test func invisibleFormatCharsStripped() {
        let s = "a\u{200E}b\u{200F}c\u{061C}d\u{200B}e\u{2060}f\u{FEFF}g\u{E0041}h\u{00AD}i\u{180E}j\u{3164}k"
        #expect(Notice.sanitize(s, limit: 100) == "abcdefghijk")
        let family = "👨\u{200D}👩\u{200D}👧"
        #expect(Notice.sanitize(family, limit: 10) == family)
    }

    @Test func combiningMarksAreBounded() {
        let s = "a" + String(repeating: "\u{0301}", count: 10_000)
        let out = Notice.sanitize(s, limit: 300)
        #expect(out.unicodeScalars.count <= 8)
        #expect(out.unicodeScalars.first == "a")
    }

    @Test func hugeInputIsHandledAndCapped() {
        let s = String(repeating: "ab cd\n", count: 900_000)
        let out = Notice.sanitize(s, limit: 300)
        #expect(out.count == 300)
        #expect(out.hasSuffix("…"))
        #expect(out.hasPrefix("ab cd ab cd"))
    }

    @Test func truncationTrimsTrailingWhitespace() {
        #expect(Notice.sanitize("abc defgh", limit: 5) == "abc…")
    }

    @Test func emptyAfterSanitizeIsIgnored() {
        var q = NoticeQueue()
        q.post(notice("\u{200B}\n\u{202E}"), now: 0)
        #expect(q.count == 0)
    }

    @Test func sameKeyDifferentScopeKeepsBoth() {
        let a = UUID(), b = UUID()
        var q = NoticeQueue()
        q.post(notice("x", scope: .host(a), key: "k"), now: 0)
        q.post(notice("x", scope: .host(b), key: "k"), now: 0)
        #expect(q.count == 2)
        #expect(q.allNotices.allSatisfy { $0.count == 1 })
    }

    @Test func replaceKeepsId() {
        var q = NoticeQueue()
        let first = notice("one", key: "k")
        q.post(first, now: 0)
        q.post(notice("two", key: "k"), now: 1)
        #expect(q.visible.map(\.id) == [first.id])
    }

    @Test func reconcileDoesNotResurrectExpired() {
        var q = NoticeQueue()
        let a = notice("a", source: .agent, key: "a")
        q.reconcile(source: .agent, with: [a], now: 0)
        q.expire(now: 5000)
        #expect(q.visible.isEmpty)
        q.reconcile(source: .agent, with: [a], now: 6000)
        #expect(q.visible.isEmpty)
    }

    @Test func reconcileBypassesKeyDedupe() {
        var q = NoticeQueue()
        let a = notice("same", source: .agent, key: "k"), b = notice("same", source: .tmux, key: "k")
        q.post(b, now: 0)
        q.reconcile(source: .agent, with: [a], now: 0)
        #expect(q.count == 2)
        q.reconcile(source: .agent, with: [a], now: 1)
        q.reconcile(source: .agent, with: [a], now: 2)
        #expect(q.allNotices.allSatisfy { $0.count == 1 })
        #expect(q.count == 2)
    }

    @Test func dismissedStaysDismissedAfterRepeatedReconciles() {
        var q = NoticeQueue()
        let a = notice("a", source: .agent, key: "a"), b = notice("b", source: .agent, key: "b")
        q.reconcile(source: .agent, with: [a, b], now: 0)
        _ = q.dismiss(id: a.id, now: 1)
        for t in 2..<5 { q.reconcile(source: .agent, with: [a, b], now: UInt64(t)) }
        #expect(q.visible.map(\.text) == ["b"])
    }

    @Test func settledMemoryIsBounded() {
        var q = NoticeQueue()
        let all = (0..<70).map { notice("n\($0)", source: .agent, key: "k\($0)") }
        for n in all { q.post(n, now: 0); _ = q.dismiss(id: n.id, now: 0) }
        #expect(q.settledCount == 64)
        q.reconcile(source: .agent, with: [all[0]], now: 0)
        #expect(q.count == 1)
    }

    @Test func overflowingDeadlineNeverExpiresEarly() {
        var q = NoticeQueue()
        q.post(notice("x", lifetime: .autoAfter(ms: .max)), now: 1000)
        #expect(q.nextDeadline == .max)
        q.expire(now: 1_000_000_000)
        #expect(q.count == 1)
    }

    @Test func stickySurvivesCapacityPressure() {
        var q = NoticeQueue()
        q.post(notice("sticky", severity: .info, lifetime: .sticky), now: 0)
        for i in 0..<20 { q.post(notice("w\(i)", severity: .warning, scope: .host(UUID())), now: 0) }
        #expect(q.count == 20)
        #expect(q.allNotices.contains { $0.text == "sticky" })
    }
}

@MainActor
@Suite("NoticeCenter review cases")
struct NoticeCenterReviewTests {
    private func make(_ clock: FakeClock) -> NoticeCenter {
        NoticeCenter(now: { clock.now }, sleep: { try await clock.sleep($0) })
    }

    @Test func retractCancelsTimer() async {
        let clock = FakeClock()
        let center = make(clock)
        center.post(notice("hi", key: "k"))
        #expect(await waitUntil { clock.sleeping == 1 })
        center.retract(key: "k")
        #expect(await waitUntil { clock.sleeping == 0 })
    }

    @Test func removeAllCancelsTimer() async {
        let clock = FakeClock()
        let center = make(clock)
        let host = UUID()
        center.setFocus(.host(host))
        center.post(notice("hi", scope: .host(host)))
        #expect(await waitUntil { clock.sleeping == 1 })
        center.removeAll(scope: .host(host))
        #expect(await waitUntil { clock.sleeping == 0 })
    }

    @Test func earlierDeadlineRearms() async {
        let clock = FakeClock()
        let center = make(clock)
        center.post(notice("e", severity: .error))
        #expect(await waitUntil { clock.requested == [10000] })
        center.post(notice("i", severity: .info))
        #expect(await waitUntil { clock.requested == [10000, 5000] })
        #expect(await waitUntil { clock.sleeping == 1 })
    }

    @Test func longDelayIsClampedAndRearmed() async {
        let clock = FakeClock()
        let center = make(clock)
        let day: UInt64 = 86_400_000
        center.post(notice("long", lifetime: .autoAfter(ms: 3 * day)))
        #expect(await waitUntil { clock.requested == [day] })
        clock.advance(day)
        #expect(await waitUntil { clock.requested == [day, day] })
        #expect(center.queue.visible.count == 1)
    }

    @Test func staleTimerDoesNotFire() async {
        let gate = Gate()
        let time = Locked<UInt64>(0)
        let center = NoticeCenter(now: { time.get }, sleep: { _ in await gate.wait() })
        center.post(notice("a"))
        #expect(await waitUntil { gate.waiting == 1 })
        center.post(notice("b", severity: .error, lifetime: .autoAfter(ms: 100))) // earlier deadline: the timer is replaced
        #expect(await waitUntil { gate.waiting == 2 })
        time.with { $0 = 6000 }
        gate.releaseFirst()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(center.queue.visible.count == 2)
    }
}
