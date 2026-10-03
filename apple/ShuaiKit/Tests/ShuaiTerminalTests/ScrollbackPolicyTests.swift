import Testing
@testable import ShuaiTerminal

@Suite("ScrollbackPolicy")
struct ScrollbackPolicyTests {
    @Test func defaultIsTenThousandLines() {
        #expect(ScrollbackPolicy.defaultLines == 10_000)
    }

    @Test func limitScalesWithLinesAndNeverNegative() {
        #expect(ScrollbackPolicy.limitBytes(lines: 10_000) == 10_000 * 160 * 8)
        #expect(ScrollbackPolicy.limitBytes(lines: 0) == 0)
        #expect(ScrollbackPolicy.limitBytes(lines: -5) == 0)
        #expect(ScrollbackPolicy.limitBytes(lines: 2_000) < ScrollbackPolicy.limitBytes(lines: 4_000))
    }
}
