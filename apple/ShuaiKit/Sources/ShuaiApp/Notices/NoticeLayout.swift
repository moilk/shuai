import CoreGraphics

/// Where the connection strip and notices go relative to the permission cards, which are drawn on
/// top in a trailing column. Pure so the narrow-width rules are unit tested.
public enum NoticeLayout {
    public enum Placement: Equatable, Sendable { case top, bottom }

    static let cardColumn: CGFloat = 380
    static let gap: CGFloat = 10
    /// Least width the notices need to stay readable beside the cards.
    static let minNoticeWidth: CGFloat = 280

    private static func fits(_ width: CGFloat) -> Bool {
        width - (min(cardColumn, width) + gap) >= minNoticeWidth
    }

    /// Trailing space the card column takes from the top stack: 0 without cards, or when too little
    /// would remain for notices (they then move to the bottom instead).
    public static func reservedTrailing(width: CGFloat, cardsPending: Bool) -> CGFloat {
        cardsPending && fits(width) ? min(cardColumn, width) + gap : 0
    }

    public static func placement(width: CGFloat, cardsPending: Bool) -> Placement {
        cardsPending && !fits(width) ? .bottom : .top
    }
}
