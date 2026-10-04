import Foundation
import Testing
@testable import ShuaiTerminal

private let esc = "\u{1B}"
private func d(_ s: String) -> Data { Data(s.utf8) }
private let da1Reply = d("\(esc)[?62;22;52c")
private let da2Reply = d("\(esc)[>1;10;0c")
private let xtReply = d("\(esc)P>|ghostty 1.3.2\(esc)\\")
private let t0 = Date(timeIntervalSince1970: 1_000)

/// tmux 3.6 only accepts the DA1/DA2/XTVERSION replies it asked for, once, within ~5 s; anything else is
/// typed into the pane as text ("62;22;52c"). The guard drops replies nobody asked for or that arrive late.
@Suite struct DeviceReplyGuardTests {
    @Test func replyWithoutQueryIsDropped() {
        let g = DeviceReplyGuard()
        #expect(!g.admit(da1Reply, at: t0))
        #expect(!g.admit(da2Reply, at: t0))
        #expect(!g.admit(xtReply, at: t0))
    }

    @Test func eachQueryAdmitsExactlyOneReplyOfItsKind() {
        let g = DeviceReplyGuard()
        g.noteOutput(d("\(esc)[c\(esc)[>c\(esc)[>q"), at: t0)
        #expect(g.admit(da1Reply, at: t0))
        #expect(!g.admit(da1Reply, at: t0), "duplicate DA1 reply")
        #expect(g.admit(da2Reply, at: t0))
        #expect(g.admit(xtReply, at: t0))
        #expect(!g.admit(xtReply, at: t0))
    }

    @Test func zeroParameterFormsAreQueriesToo() {
        let g = DeviceReplyGuard()
        g.noteOutput(d("\(esc)[0c\(esc)[>0c\(esc)[>0q"), at: t0)
        #expect(g.admit(da1Reply, at: t0) && g.admit(da2Reply, at: t0) && g.admit(xtReply, at: t0))
    }

    @Test func lateReplyIsDropped() {
        let g = DeviceReplyGuard(maxAge: 3)
        g.noteOutput(d("\(esc)[c"), at: t0)
        #expect(!g.admit(da1Reply, at: t0.addingTimeInterval(6)))
        // The stale query does not linger to swallow a later, legitimate pair either.
        g.noteOutput(d("\(esc)[c"), at: t0.addingTimeInterval(7))
        #expect(g.admit(da1Reply, at: t0.addingTimeInterval(7.1)))
    }

    @Test func queriesSplitAcrossChunksAreRecognised() {
        let g = DeviceReplyGuard()
        g.noteOutput(d("text\(esc)"), at: t0)
        g.noteOutput(d("[>"), at: t0)
        g.noteOutput(d("0c more"), at: t0)
        #expect(g.admit(da2Reply, at: t0))
        #expect(!g.admit(da1Reply, at: t0))
    }

    @Test func otherSequencesAreNotQueries() {
        let g = DeviceReplyGuard()
        g.noteOutput(d("\(esc)[1;5H\(esc)[?25h\(esc)[2J abc c"), at: t0)
        #expect(!g.admit(da1Reply, at: t0))
    }

    @Test func resetForgetsPendingQueries() {
        let g = DeviceReplyGuard()
        g.noteOutput(d("\(esc)[c"), at: t0)
        g.reset()
        #expect(!g.admit(da1Reply, at: t0), "reply to a previous attach's query")
    }

    @Test func everythingElseIsAdmittedUntouched() {
        let g = DeviceReplyGuard()
        for s in ["1", "\r", "\(esc)", "\(esc)[A", "\(esc)[49u", "\(esc)]11;rgb:1e1e/1e1e/2e2e\(esc)\\",
                  "\(esc)[?997;2n", "\(esc)[8;24;80t", "echo hi\r", "\(esc)[200~paste\(esc)[201~"] {
            #expect(g.admit(d(s), at: t0), "\(s.debugDescription)")
        }
    }
}
