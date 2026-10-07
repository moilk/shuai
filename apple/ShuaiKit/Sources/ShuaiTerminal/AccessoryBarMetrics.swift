import Foundation

/// Sizes of the keyboard accessory bar. Pure values (no UIKit): the view passes in the Dynamic
/// Type scale and the measured line height.
public enum AccessoryBarMetrics {
    public static let baseFontSize: Double = 15
    /// Largest key font, so the two rows stay usable at accessibility sizes.
    public static let maxFontSize: Double = 22
    /// Minimum tap target height of a key row.
    public static let minRowHeight: Double = 44
    /// Vertical room added around a line of text inside a row.
    public static let rowPadding: Double = 8
    /// Space between the two docked rows.
    public static let rowSpacing: Double = 4
    /// Top and bottom inset of the bar (each side).
    public static let barInset: Double = 4

    /// Key font size for a Dynamic Type scale (1 = default size), capped at `maxFontSize`.
    public static func size(forScale scale: Double) -> Double {
        min(baseFontSize * max(scale, 0), maxFontSize)
    }

    /// Row height: the text plus padding, never below the 44 pt minimum. The minimum scales with
    /// the (capped) Dynamic Type scale, since a font capped at 22 pt alone never outgrows 44 pt.
    public static func rowHeight(lineHeight: Double, scale: Double = 1) -> Double {
        let cappedScale = min(max(scale, 1), maxFontSize / baseFontSize)
        return max(minRowHeight * cappedScale, lineHeight + rowPadding)
    }

    /// Two rows, the gap between them and the insets above and below.
    public static func dockedHeight(rowHeight: Double) -> Double {
        2 * rowHeight + rowSpacing + 2 * barInset
    }

    public static func floatingHeight(rowHeight: Double) -> Double {
        rowHeight + 2 * barInset
    }
}
