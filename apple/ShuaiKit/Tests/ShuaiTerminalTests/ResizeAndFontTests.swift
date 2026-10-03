import Foundation
import Testing
@testable import ShuaiTerminal

/// Manual scheduler: collects scheduled blocks, fires them on demand.
@MainActor
private final class ManualScheduler {
    struct Item { var delay: TimeInterval; var block: @MainActor () -> Void; var cancelled = false }
    var items: [Item] = []

    func schedule(_ delay: TimeInterval, _ block: @escaping @MainActor () -> Void) -> @MainActor () -> Void {
        items.append(Item(delay: delay, block: block))
        let index = items.count - 1
        return { [unowned self] in items[index].cancelled = true }
    }

    func fireAll() {
        let pending = items
        items.removeAll()
        for i in pending where !i.cancelled { i.block() }
    }
}

@MainActor
@Suite("ResizeDebouncer")
struct ResizeDebouncerTests {
    @Test func firstSizeIsEmittedImmediately() {
        let s = ManualScheduler()
        var got: [TerminalGridSize] = []
        let d = ResizeDebouncer(delay: 0.2, schedule: s.schedule) { got.append($0) }
        d.submit(TerminalGridSize(cols: 120, rows: 40))
        #expect(got == [TerminalGridSize(cols: 120, rows: 40)])
    }

    @Test func burstCollapsesToLastSize() {
        let s = ManualScheduler()
        var got: [TerminalGridSize] = []
        let d = ResizeDebouncer(delay: 0.2, schedule: s.schedule) { got.append($0) }
        d.submit(TerminalGridSize(cols: 120, rows: 40))
        d.submit(TerminalGridSize(cols: 110, rows: 40))
        d.submit(TerminalGridSize(cols: 100, rows: 38))
        d.submit(TerminalGridSize(cols: 90, rows: 30))
        #expect(got.count == 1)
        s.fireAll()
        #expect(got == [TerminalGridSize(cols: 120, rows: 40), TerminalGridSize(cols: 90, rows: 30)])
    }

    @Test func usesConfiguredDelay() {
        let s = ManualScheduler()
        let d = ResizeDebouncer(delay: 0.35, schedule: s.schedule) { _ in }
        d.submit(TerminalGridSize(cols: 80, rows: 24))
        d.submit(TerminalGridSize(cols: 81, rows: 24))
        #expect(s.items.last?.delay == 0.35)
    }

    @Test func unchangedSizeIsNotReemitted() {
        let s = ManualScheduler()
        var got: [TerminalGridSize] = []
        let d = ResizeDebouncer(delay: 0.2, schedule: s.schedule) { got.append($0) }
        d.submit(TerminalGridSize(cols: 80, rows: 24))
        d.submit(TerminalGridSize(cols: 80, rows: 24))
        s.fireAll()
        #expect(got.count == 1)
    }

    @Test func returningToEmittedSizeWithinWindowEmitsNothing() {
        let s = ManualScheduler()
        var got: [TerminalGridSize] = []
        let d = ResizeDebouncer(delay: 0.2, schedule: s.schedule) { got.append($0) }
        d.submit(TerminalGridSize(cols: 80, rows: 24))
        d.submit(TerminalGridSize(cols: 70, rows: 24))
        d.submit(TerminalGridSize(cols: 80, rows: 24))
        s.fireAll()
        #expect(got.count == 1)
    }

    @Test func invalidSizesAreIgnored() {
        let s = ManualScheduler()
        var got: [TerminalGridSize] = []
        let d = ResizeDebouncer(delay: 0.2, schedule: s.schedule) { got.append($0) }
        d.submit(TerminalGridSize(cols: 0, rows: 24))
        d.submit(TerminalGridSize(cols: 80, rows: 0))
        s.fireAll()
        #expect(got.isEmpty)
    }

    @Test func laterChangesAfterSettlingAreDebouncedAgain() {
        let s = ManualScheduler()
        var got: [TerminalGridSize] = []
        let d = ResizeDebouncer(delay: 0.2, schedule: s.schedule) { got.append($0) }
        d.submit(TerminalGridSize(cols: 80, rows: 24))
        d.submit(TerminalGridSize(cols: 90, rows: 24))
        s.fireAll()
        d.submit(TerminalGridSize(cols: 100, rows: 24))
        #expect(got.count == 2)
        s.fireAll()
        #expect(got.last == TerminalGridSize(cols: 100, rows: 24))
    }
}

@Suite("FontSizeModel")
struct FontSizeModelTests {
    @Test func defaultsAndSteps() {
        var m = FontSizeModel()
        #expect(m.size == 14)
        #expect(m.increase() == 1)
        #expect(m.size == 15)
        #expect(m.decrease() == -1)
        #expect(m.decrease() == -1)
        #expect(m.size == 13)
    }

    @Test func clampsAtBoundsAndReportsZeroDelta() {
        var m = FontSizeModel(size: 40)
        #expect(m.increase() == 0)
        #expect(m.size == 40)
        var n = FontSizeModel(size: 6)
        #expect(n.decrease() == 0)
        #expect(n.size == 6)
    }

    @Test func resetReturnsDeltaToDefault() {
        var m = FontSizeModel(size: 20)
        #expect(m.reset() == -6)
        #expect(m.size == 14)
    }

    @Test func initClampsOutOfRange() {
        #expect(FontSizeModel(size: 2).size == 6)
        #expect(FontSizeModel(size: 200).size == 40)
    }
}
