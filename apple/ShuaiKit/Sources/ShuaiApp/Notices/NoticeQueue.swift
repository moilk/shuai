import Foundation

/// The pure state machine behind the notice stack: dedupe, ordering, visibility limits and
/// expiry deadlines. It has no clock; every call that can change what is visible takes `now`
/// in milliseconds, and `NoticeCenter` turns `nextDeadline` into a timer.
public struct NoticeQueue: Sendable {
    public static let capacity = 20
    public static let maxVisible = 3
    static let dismissedMemory = 64

    private struct Entry: Sendable {
        var notice: Notice
        let seq: UInt64
        /// Set when the notice first becomes visible; the expiry timer starts there.
        var visibleSince: UInt64?
        var deadline: UInt64?
    }

    private var entries: [Entry] = []
    private var nextSeq: UInt64 = 0
    private var focus: Notice.Scope?
    private var pendingPermissionCards = 0
    private var dismissed: [UUID] = []

    public init() {}

    // MARK: - queries

    /// Notices on screen, most important first.
    public var visible: [Notice] {
        Array(eligible.prefix(maxVisibleNow)).map(\.notice)
    }

    /// Eligible notices that do not fit on screen.
    public var hiddenCount: Int { max(0, eligible.count - maxVisibleNow) }

    /// Earliest armed expiry, if any.
    public var nextDeadline: UInt64? { entries.compactMap(\.deadline).min() }

    /// Number of held notices, visible or not.
    public var count: Int { entries.count }

    /// Every held notice, oldest first.
    public var allNotices: [Notice] { entries.map(\.notice) }

    private var maxVisibleNow: Int { pendingPermissionCards > 0 ? 1 : Self.maxVisible }

    private var eligible: [Entry] {
        entries
            .filter { $0.notice.scope == .app || $0.notice.scope == focus }
            .sorted {
                $0.notice.severity != $1.notice.severity
                    ? $0.notice.severity > $1.notice.severity
                    : $0.seq > $1.seq
            }
    }

    // MARK: - mutations

    public mutating func post(_ notice: Notice, now: UInt64) {
        if let i = entries.firstIndex(where: { $0.notice.key == notice.key }) {
            var e = entries[i]
            if Self.sameContent(e.notice, notice) {
                e.notice.count += 1
            } else {
                e.notice = Self.reidentified(notice, as: e.notice.id)
            }
            e.visibleSince = nil
            e.deadline = nil
            entries[i] = e
        } else {
            entries.append(Entry(notice: notice, seq: nextSeq, visibleSince: nil, deadline: nil))
            nextSeq += 1
            if entries.count > Self.capacity,
               let drop = entries.indices.min(by: {
                   (entries[$0].notice.severity, entries[$0].seq) < (entries[$1].notice.severity, entries[$1].seq)
               }) {
                entries.remove(at: drop)
            }
        }
        arm(now)
    }

    public mutating func retract(key: String, now: UInt64) {
        entries.removeAll { $0.notice.key == key }
        arm(now)
    }

    /// Removes the notice because the user dismissed it; reconcile will not bring it back.
    @discardableResult
    public mutating func dismiss(id: UUID, now: UInt64) -> Notice? {
        guard let i = entries.firstIndex(where: { $0.notice.id == id }) else { return nil }
        let removed = entries.remove(at: i).notice
        dismissed.append(id)
        if dismissed.count > Self.dismissedMemory { dismissed.removeFirst(dismissed.count - Self.dismissedMemory) }
        arm(now)
        return removed
    }

    public mutating func removeAll(scope: Notice.Scope, now: UInt64) {
        entries.removeAll { $0.notice.scope == scope }
        arm(now)
    }

    /// `nil` focuses app-level notices only.
    public mutating func setFocus(_ scope: Notice.Scope?, now: UInt64) {
        focus = scope
        arm(now)
    }

    public mutating func setPendingPermissionCards(_ n: Int, now: UInt64) {
        pendingPermissionCards = max(0, n)
        arm(now)
    }

    /// Makes the notices of `source` equal `notices`: adds unknown ones, retracts those no longer
    /// present, and never re-adds an id the user dismissed.
    public mutating func reconcile(source: Notice.Source, with notices: [Notice], now: UInt64) {
        let incoming = Set(notices.map(\.id))
        entries.removeAll { $0.notice.source == source && !incoming.contains($0.notice.id) }
        for n in notices where !dismissed.contains(n.id) && !entries.contains(where: { $0.notice.id == n.id }) {
            post(n, now: now)
        }
        arm(now)
    }

    /// Removes auto notices whose deadline has passed.
    public mutating func expire(now: UInt64) {
        entries.removeAll { ($0.deadline ?? .max) <= now }
        arm(now)
    }

    // MARK: - internals

    /// Starts the timer of every visible notice that has none yet.
    private mutating func arm(_ now: UInt64) {
        let ids = visible.map(\.id)
        for id in ids {
            guard let i = entries.firstIndex(where: { $0.notice.id == id }),
                  entries[i].visibleSince == nil else { continue }
            entries[i].visibleSince = now
            entries[i].deadline = entries[i].notice.duration.map { now &+ $0 }
        }
    }

    private static func sameContent(_ a: Notice, _ b: Notice) -> Bool {
        a.severity == b.severity && a.source == b.source && a.scope == b.scope
            && a.title == b.title && a.text == b.text && a.symbol == b.symbol
            && a.action == b.action && a.lifetime == b.lifetime
    }

    private static func reidentified(_ n: Notice, as id: UUID) -> Notice {
        Notice(id: id, severity: n.severity, source: n.source, scope: n.scope, title: n.title,
               text: n.text, symbol: n.symbol, action: n.action, key: n.key, lifetime: n.lifetime)
    }
}
