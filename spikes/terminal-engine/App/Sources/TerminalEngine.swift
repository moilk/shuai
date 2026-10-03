import UIKit

/// Preview of the production abstraction (M3 will extend it).
protocol TerminalEngine: AnyObject {
    func feed(_ bytes: Data)
    func resize(cols: Int, rows: Int)
    var onInput: ((Data) -> Void)? { get set }

    // Spike-only extras
    var view: UIView { get }
    var gridSize: (cols: Int, rows: Int) { get }
    /// Wait until fed bytes are parsed (Ghostty parses on a background queue).
    func drain() async
    /// Visible screen, one line per row, right-trimmed.
    func screenText() -> String
}
