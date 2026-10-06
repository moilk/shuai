import Foundation
@testable import ShuaiApp

/// Records what a source posts and retracts, in order.
@MainActor
final class RecordingNoticeSink: NoticePosting {
    enum Event: Equatable {
        case post(Notice)
        case retract(String)
    }

    private(set) var events: [Event] = []

    func post(_ n: Notice) { events.append(.post(n)) }
    func retract(key: String) { events.append(.retract(key)) }

    var posted: [Notice] { events.compactMap { if case .post(let n) = $0 { n } else { nil } } }
    var retractedKeys: [String] { events.compactMap { if case .retract(let k) = $0 { k } else { nil } } }

    /// Notices still standing: the latest post per (key, scope) unless its key was retracted
    /// after it was posted.
    var active: [Notice] {
        var live: [Notice] = []
        for e in events {
            switch e {
            case .post(let n):
                live.removeAll { $0.key == n.key && $0.scope == n.scope }
                live.append(n)
            case .retract(let key):
                live.removeAll { $0.key == key }
            }
        }
        return live
    }
}
