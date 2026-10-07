import Testing
@testable import ShuaiApp

@Suite("FullScreenState")
struct FullScreenStateTests {
    @Test func enterCollapsesSidebar() {
        var s = FullScreenState()
        #expect(s.enter(current: .all) == .detailOnly)
    }
    @Test func exitRestoresPreviousVisibility() {
        var s = FullScreenState()
        _ = s.enter(current: .doubleColumn)
        #expect(s.exit(current: .detailOnly) == .doubleColumn)
    }
    @Test func exitKeepsUserChangeMadeDuringFullScreen() {
        var s = FullScreenState()
        _ = s.enter(current: .doubleColumn)
        #expect(s.exit(current: .all) == .all)
        // Nothing stored any more: a second exit leaves the visibility alone.
        #expect(s.exit(current: .detailOnly) == .detailOnly)
    }
}
