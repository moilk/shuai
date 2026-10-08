import Testing

@testable import ShuaiApp

@Suite struct PaneBadgePresentationTests {
    /// Every badge has its own symbol, and none of them is a bare question mark (it reads as a
    /// missing glyph); waiting for input is a speech bubble with an ellipsis.
    @Test func symbolsAreDistinctAndNeedsInputIsAnEllipsisBubble() {
        let all: [PaneBadge] = [.working, .needsPermission, .needsInput, .done, .failed, .idle]
        #expect(Set(all.map(\.symbol)).count == all.count)
        #expect(PaneBadge.needsInput.symbol == "ellipsis.bubble")
        #expect(all.allSatisfy { !$0.symbol.contains("questionmark") })
    }
}
