import Testing
@testable import ShuaiTerminal

@Suite("AccessoryBarMetrics")
struct AccessoryBarMetricsTests {
    /// Approximate line height of a monospaced font at `size` points.
    private func lineHeight(_ size: Double) -> Double { (size * 1.2).rounded(.up) }

    private func row(scale: Double) -> Double {
        AccessoryBarMetrics.rowHeight(lineHeight: lineHeight(AccessoryBarMetrics.size(forScale: scale)), scale: scale)
    }

    private let scales: [Double] = [0.8, 1, 1.1, 1.25, 1.5, 2, 2.5, 3.1]

    @Test func defaultRowMeetsTheMinimum() {
        let size = AccessoryBarMetrics.size(forScale: 1)
        #expect(size == AccessoryBarMetrics.baseFontSize)
        let row = AccessoryBarMetrics.rowHeight(lineHeight: lineHeight(size), scale: 1)
        #expect(row >= 44)
        #expect(row == AccessoryBarMetrics.minRowHeight)
    }

    @Test func rowsGrowWithContentSize() {
        // The capped font alone never outgrows 44 pt, so the minimum itself scales with the text.
        #expect(row(scale: 1.5) > row(scale: 1))
        #expect(row(scale: 1.25) > row(scale: 1))
        #expect(row(scale: 10) == AccessoryBarMetrics.minRowHeight * AccessoryBarMetrics.maxFontSize / AccessoryBarMetrics.baseFontSize)
        #expect(AccessoryBarMetrics.rowHeight(lineHeight: 60) == 60 + AccessoryBarMetrics.rowPadding)
    }

    @Test func fontCappedAtAccessibilitySizes() {
        #expect(AccessoryBarMetrics.size(forScale: 3.1) == AccessoryBarMetrics.maxFontSize)
        #expect(AccessoryBarMetrics.size(forScale: 10) == AccessoryBarMetrics.maxFontSize)
        #expect(AccessoryBarMetrics.size(forScale: 1.2) < AccessoryBarMetrics.maxFontSize)
    }

    @Test func dockedHeightIsTwoRowsPlusPadding() {
        #expect(AccessoryBarMetrics.dockedHeight(rowHeight: 44) == 2 * 44 + 4 + 8)
        #expect(AccessoryBarMetrics.dockedHeight(rowHeight: 44) == 100)
        #expect(AccessoryBarMetrics.dockedHeight(rowHeight: 60) == 132)
    }

    @Test func floatingHeightMeetsMinimum() {
        #expect(AccessoryBarMetrics.floatingHeight(rowHeight: AccessoryBarMetrics.minRowHeight) >= 44)
        #expect(AccessoryBarMetrics.floatingHeight(rowHeight: 44) == 44 + 8)
    }

    @Test func heightsAreMonotonicInScale() {
        var previousDocked = 0.0
        var previousFloating = 0.0
        for scale in scales {
            let rowHeight = row(scale: scale)
            let docked = AccessoryBarMetrics.dockedHeight(rowHeight: rowHeight)
            let floating = AccessoryBarMetrics.floatingHeight(rowHeight: rowHeight)
            #expect(docked >= previousDocked)
            #expect(floating >= previousFloating)
            previousDocked = docked
            previousFloating = floating
        }
    }
}
