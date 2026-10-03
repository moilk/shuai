#if canImport(GhosttyTerminal) && canImport(UIKit)
import SwiftUI
import UIKit

/// SwiftUI host for a `GhosttyEngine`'s terminal view. The engine owns the view; this only embeds it.
public struct TerminalViewRepresentable: UIViewRepresentable {
    public let engine: GhosttyEngine
    public var autoFocus: Bool
    public var showsFloatingAccessoryBar: Bool

    public init(engine: GhosttyEngine, autoFocus: Bool = true, showsFloatingAccessoryBar: Bool = false) {
        self.engine = engine
        self.autoFocus = autoFocus
        self.showsFloatingAccessoryBar = showsFloatingAccessoryBar
    }

    public func makeUIView(context _: Context) -> TerminalView {
        let view = engine.view
        view.autoFocus = autoFocus
        view.showsFloatingAccessoryBar = showsFloatingAccessoryBar
        return view
    }

    public func updateUIView(_ view: TerminalView, context _: Context) {
        view.autoFocus = autoFocus
        if view.showsFloatingAccessoryBar != showsFloatingAccessoryBar {
            view.showsFloatingAccessoryBar = showsFloatingAccessoryBar
        }
    }
}
#endif
