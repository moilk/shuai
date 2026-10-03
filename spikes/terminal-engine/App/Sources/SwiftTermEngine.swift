import UIKit
import SwiftTerm

final class SwiftTermEngine: NSObject, TerminalEngine, TerminalViewDelegate {
    let tv: TerminalView
    var onInput: ((Data) -> Void)?
    var view: UIView { tv }
    private var wC: NSLayoutConstraint!
    private var hC: NSLayoutConstraint!

    override init() {
        tv = TerminalView(frame: CGRect(x: 0, y: 0, width: 900, height: 700))
        super.init()
        tv.translatesAutoresizingMaskIntoConstraints = false
        tv.terminalDelegate = self
        tv.font = UIFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        wC = tv.widthAnchor.constraint(equalToConstant: 900)
        hC = tv.heightAnchor.constraint(equalToConstant: 700)
        NSLayoutConstraint.activate([wC, hC])
    }

    var gridSize: (cols: Int, rows: Int) { let t = tv.getTerminal(); return (t.cols, t.rows) }

    func feed(_ bytes: Data) { tv.feed(byteArray: ArraySlice([UInt8](bytes))) }
    func drain() async {}

    func resize(cols: Int, rows: Int) {
        tv.getTerminal().resize(cols: cols, rows: rows)
        let s = tv.getOptimalFrameSize()
        wC.constant = s.width; hC.constant = s.height
        tv.setNeedsLayout()
    }

    func screenText() -> String {
        let t = tv.getTerminal()
        var out: [String] = []
        for r in 0..<t.rows {
            let line = t.getLine(row: r)?.translateToString(trimRight: true, skipNullCellsFollowingWide: true, characterProvider: { t.getCharacter(for: $0) }) ?? ""
            out.append(line)
        }
        return out.joined(separator: "\n")
    }

    // TerminalViewDelegate
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func send(source: TerminalView, data: ArraySlice<UInt8>) { onInput?(Data(data)) }
    func scrolled(source: TerminalView, position: Double) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
    func clipboardCopy(source: TerminalView, content: Data) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
