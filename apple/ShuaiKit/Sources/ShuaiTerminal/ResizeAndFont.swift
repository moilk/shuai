import Foundation

public struct TerminalGridSize: Sendable, Hashable {
    public var cols: Int
    public var rows: Int
    public init(cols: Int, rows: Int) {
        self.cols = cols
        self.rows = rows
    }

    public var isValid: Bool { cols > 0 && rows > 0 }
}

/// Collapses bursts of grid-size changes (rotation, Stage Manager drags, keyboard show/hide) into one
/// callback so the SSH `window-change` is sent once. The first valid size is emitted immediately
/// (the PTY needs it right away); later changes are trailing-edge debounced.
@MainActor
public final class ResizeDebouncer {
    public typealias Scheduler = (TimeInterval, @escaping @MainActor () -> Void) -> @MainActor () -> Void

    private let delay: TimeInterval
    private let schedule: Scheduler
    private let onResize: (TerminalGridSize) -> Void
    private var lastEmitted: TerminalGridSize?
    private var cancelPending: (@MainActor () -> Void)?

    public init(
        delay: TimeInterval = 0.15,
        schedule: @escaping Scheduler = ResizeDebouncer.mainQueueScheduler,
        onResize: @escaping (TerminalGridSize) -> Void
    ) {
        self.delay = delay
        self.schedule = schedule
        self.onResize = onResize
    }

    public static let mainQueueScheduler: Scheduler = { delay, block in
        let item = DispatchWorkItem { MainActor.assumeIsolated { block() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        return { item.cancel() }
    }

    public func submit(_ size: TerminalGridSize) {
        guard size.isValid else { return }
        cancelPending?()
        cancelPending = nil
        guard let last = lastEmitted else {
            emit(size)
            return
        }
        guard size != last else { return }
        cancelPending = schedule(delay) { [weak self] in
            guard let self else { return }
            cancelPending = nil
            if size != lastEmitted { emit(size) }
        }
    }

    private func emit(_ size: TerminalGridSize) {
        lastEmitted = size
        onResize(size)
    }
}

/// Font size state for ⌘+ / ⌘− / ⌘0. Applying the returned delta to the renderer keeps it in sync.
public struct FontSizeModel: Sendable, Equatable {
    public static let defaultSize = 14
    public static let range = 6 ... 40

    public private(set) var size: Int

    public init(size: Int = FontSizeModel.defaultSize) {
        self.size = min(max(size, Self.range.lowerBound), Self.range.upperBound)
    }

    /// Returns the delta actually applied (0 when clamped).
    @discardableResult
    public mutating func increase() -> Int { set(size + 1) }

    @discardableResult
    public mutating func decrease() -> Int { set(size - 1) }

    @discardableResult
    public mutating func reset() -> Int { set(Self.defaultSize) }

    private mutating func set(_ new: Int) -> Int {
        let clamped = min(max(new, Self.range.lowerBound), Self.range.upperBound)
        let delta = clamped - size
        size = clamped
        return delta
    }
}

/// Scrollback sizing. Ghostty's `scrollback-limit` is in bytes (per surface), not lines; a cell is 8 bytes,
/// so lines are converted with a typical iPad terminal width. The default (10k lines) is ~12.8 MB.
public enum ScrollbackPolicy {
    public static let defaultLines = 10_000
    public static let assumedColumns = 160
    public static let bytesPerCell = 8

    public static func limitBytes(lines: Int) -> Int {
        max(lines, 0) * assumedColumns * bytesPerCell
    }
}
