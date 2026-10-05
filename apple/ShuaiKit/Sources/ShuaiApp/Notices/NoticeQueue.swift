import Foundation

/// The pure state machine behind the notice stack: dedupe, ordering, visibility limits and
/// expiry deadlines. It has no clock; every call that can change what is visible takes `now`
/// in milliseconds, and `NoticeCenter` turns `nextDeadline` into a timer.
public struct NoticeQueue: Sendable {
    public static let capacity = 20
    public static let maxVisible = 3
    static let settledMemory = 64

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
    /// Ids that were dismissed or expired; `reconcile` never adds them again. Bounded.
    private var settled: [UUID] = []

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

    var settledCount: Int { settled.count }

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

    /// Posts a notice. A notice whose sanitized text is empty is ignored. One with the same key
    /// and scope as a held notice replaces it (different content) or bumps its count (identical).
    public mutating func post(_ notice: Notice, now: UInt64) {
        guard !notice.text.isEmpty else { return }
        if let i = entries.firstIndex(where: { $0.notice.key == notice.key && $0.notice.scope == notice.scope }) {
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
            insert(notice)
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
        settle(id)
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

    /// Makes the notices of `source` equal `notices`, matched by id: adds unknown ones, retracts
    /// those no longer present, and never adds an id that was dismissed or has expired. Keys
    /// within one list are the caller's responsibility; key dedupe does not apply here.
    public mutating func reconcile(source: Notice.Source, with notices: [Notice], now: UInt64) {
        #if DEBUG
        assert(Set(notices.map { "\($0.scope)|\($0.key)" }).count == notices.count,
               "reconcile list contains duplicate keys")
        #endif
        let incoming = Set(notices.map(\.id))
        entries.removeAll { $0.notice.source == source && !incoming.contains($0.notice.id) }
        for n in notices
        where !n.text.isEmpty && !settled.contains(n.id) && !entries.contains(where: { $0.notice.id == n.id }) {
            insert(n)
        }
        arm(now)
    }

    /// Removes auto notices whose deadline has passed.
    public mutating func expire(now: UInt64) {
        for e in entries where e.deadline.map({ $0 <= now }) ?? false { settle(e.notice.id) }
        entries.removeAll { $0.deadline.map { $0 <= now } ?? false }
        arm(now)
    }

    // MARK: - internals

    private mutating func settle(_ id: UUID) {
        settled.append(id)
        if settled.count > Self.settledMemory { settled.removeFirst(settled.count - Self.settledMemory) }
    }

    /// Appends a new entry; when the queue is full the lowest-ranked notice (non-sticky first,
    /// then lowest severity, then oldest) is dropped, which is the new one if it ranks lower.
    private mutating func insert(_ notice: Notice) {
        if entries.count >= Self.capacity,
           let v = entries.indices.min(by: { rank(entries[$0]) < rank(entries[$1]) }) {
            let incoming = (notice.lifetime == .sticky ? 1 : 0, notice.severity.rawValue, UInt64.max)
            if rank(entries[v]) > incoming { return }
            entries.remove(at: v)
        }
        entries.append(Entry(notice: notice, seq: nextSeq, visibleSince: nil, deadline: nil))
        nextSeq += 1
    }

    private func rank(_ e: Entry) -> (Int, Int, UInt64) {
        (e.notice.lifetime == .sticky ? 1 : 0, e.notice.severity.rawValue, e.seq)
    }

    /// Starts the timer of every visible notice that has none yet.
    private mutating func arm(_ now: UInt64) {
        let ids = visible.map(\.id)
        for id in ids {
            guard let i = entries.firstIndex(where: { $0.notice.id == id }),
                  entries[i].visibleSince == nil else { continue }
            entries[i].visibleSince = now
            entries[i].deadline = entries[i].notice.duration.map {
                let (sum, overflow) = now.addingReportingOverflow($0)
                return overflow ? UInt64.max : sum
            }
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
