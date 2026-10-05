import Testing
@testable import ShuaiApp

@Suite("Notice layout")
struct NoticeLayoutTests {
    @Test func noCardsReservesNothing() {
        #expect(NoticeLayout.reservedTrailing(width: 1000, cardsPending: false) == 0)
        #expect(NoticeLayout.placement(width: 300, cardsPending: false) == .top)
    }

    @Test func wideAreaReservesTheCardColumnPlusGap() {
        #expect(NoticeLayout.reservedTrailing(width: 1000, cardsPending: true) == 390)
        #expect(NoticeLayout.placement(width: 1000, cardsPending: true) == .top)
    }

    @Test func exactlyEnoughRoomStillReserves() {
        #expect(NoticeLayout.reservedTrailing(width: 390 + 280, cardsPending: true) == 390)
        #expect(NoticeLayout.placement(width: 390 + 280, cardsPending: true) == .top)
    }

    @Test func tooNarrowReservesNothingAndMovesToTheBottom() {
        for w in [320.0, 390, 500, 669] {
            #expect(NoticeLayout.reservedTrailing(width: w, cardsPending: true) == 0)
            #expect(NoticeLayout.placement(width: w, cardsPending: true) == .bottom)
        }
    }

    @Test func reservedSpaceNeverExceedsTheWidth() {
        for w in stride(from: 0.0, through: 1200, by: 10) {
            #expect(NoticeLayout.reservedTrailing(width: w, cardsPending: true) <= w)
        }
    }
}
