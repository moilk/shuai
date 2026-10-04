import Foundation

/// Lets the terminal engine's replies to the remote's device queries (DA1 `CSI c`, DA2 `CSI > c`,
/// XTVERSION `CSI > q`) through only when they are wanted.
///
/// tmux 3.6 accepts each of these replies once, and only shortly after it asked (about 5 s). A reply that is
/// late (the engine had no surface yet, the main thread was busy, ...), repeated or from a previous attach is
/// not recognised as a reply: tmux types it into the pane as text (`62;22;52c`, `1;10;0c`, `>|ghostty ...`),
/// where a shell prints "command not found" and a Claude Code prompt collects junk. So every reply must be
/// matched with an unanswered query that was seen in the remote output recently; anything else is dropped.
/// Writes that are not one of these three replies (keys, paste, other reports) are never touched.
public final class DeviceReplyGuard: @unchecked Sendable {
    private enum Kind: Hashable { case da1, da2, xtversion }

    private let maxAge: TimeInterval
    private let lock = NSLock()
    private var pending: [Kind: [Date]] = [:]
    private var carry: [UInt8] = []

    /// `maxAge`: how long a query stays answerable. Keep it below tmux's own request timeout (5 s).
    public init(maxAge: TimeInterval = 3) { self.maxAge = maxAge }

    /// Records the queries contained in remote output (sequences split across chunks are handled).
    public func noteOutput(_ data: Data, at now: Date) {
        lock.lock(); defer { lock.unlock() }
        let b = carry + data
        carry = []
        let esc: UInt8 = 0x1B
        var i = 0
        while i < b.count {
            guard b[i] == esc else { i += 1; continue }
            var j = i + 1
            guard j < b.count else { carry = Array(b[i...]); break }
            guard b[j] == UInt8(ascii: "[") else { i += 1; continue }
            j += 1
            var gt = false
            if j < b.count, b[j] == UInt8(ascii: ">") { gt = true; j += 1 }
            if j < b.count, b[j] == UInt8(ascii: "0") { j += 1 }
            guard j < b.count else { carry = Array(b[i...]); break }
            switch (gt, b[j]) {
            case (false, UInt8(ascii: "c")): add(.da1, now)
            case (true, UInt8(ascii: "c")): add(.da2, now)
            case (true, UInt8(ascii: "q")): add(.xtversion, now)
            default: break
            }
            i = j + 1
        }
    }

    /// Whether `data` (one write the engine produced) may go to the remote.
    public func admit(_ data: Data, at now: Date) -> Bool {
        guard let kind = Self.classify(data) else { return true }
        lock.lock(); defer { lock.unlock() }
        var list = (pending[kind] ?? []).filter { now.timeIntervalSince($0) <= maxAge }
        defer { pending[kind] = list }
        guard !list.isEmpty else { return false }
        list.removeFirst()
        return true
    }

    /// Forgets every outstanding query (a new shell was opened: replies to the old one's queries are stale).
    public func reset() {
        lock.lock(); defer { lock.unlock() }
        pending = [:]
        carry = []
    }

    private func add(_ kind: Kind, _ now: Date) {
        var list = (pending[kind] ?? []).filter { now.timeIntervalSince($0) <= maxAge }
        list.append(now)
        pending[kind] = Array(list.suffix(16))
    }

    private static func classify(_ data: Data) -> Kind? {
        let b = [UInt8](data)
        guard b.count >= 4, b[0] == 0x1B else { return nil }
        func params(_ range: Range<Int>) -> Bool {
            b[range].allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || $0 == UInt8(ascii: ";") }
        }
        if b[1] == UInt8(ascii: "["), b.last == UInt8(ascii: "c"), params(3 ..< b.count - 1) {
            if b[2] == UInt8(ascii: "?") { return .da1 }
            if b[2] == UInt8(ascii: ">") { return .da2 }
        }
        if b[1] == UInt8(ascii: "P"), b[2] == UInt8(ascii: ">"), b[3] == UInt8(ascii: "|"), b.count >= 6,
           b[b.count - 2] == 0x1B, b[b.count - 1] == UInt8(ascii: "\\")
        {
            return .xtversion
        }
        return nil
    }
}
