import Foundation

/// Mirror of SwiftUI's `NavigationSplitViewVisibility` (ShuaiApp does not import SwiftUI). The app
/// target maps `.all`, `.doubleColumn`, `.detailOnly` and `.automatic` one to one.
public enum SidebarVisibility: Equatable, Sendable {
    case all, doubleColumn, detailOnly, automatic
}

/// Remembers the column visibility from before full screen so leaving restores it, unless the user
/// changed the columns while in full screen.
public struct FullScreenState: Equatable, Sendable {
    private var previous: SidebarVisibility?

    public init() {}

    /// Returns the visibility to apply on entering full screen.
    public mutating func enter(current: SidebarVisibility) -> SidebarVisibility {
        // Entering twice keeps the first stored value (the second `current` is already detail-only).
        if previous == nil { previous = current }
        return .detailOnly
    }

    /// Returns the visibility to apply on leaving full screen.
    public mutating func exit(current: SidebarVisibility) -> SidebarVisibility {
        defer { previous = nil }
        guard let previous, current == .detailOnly else { return current }
        return previous
    }
}
