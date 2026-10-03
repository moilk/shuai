import UIKit
import GhosttyTerminal

final class GhosttyEngine: NSObject, TerminalEngine, TerminalSurfaceGridResizeDelegate {
    let tv: TerminalView
    let session: InMemoryTerminalSession
    let controller: TerminalController
    var onInput: ((Data) -> Void)?
    var view: UIView { tv }
    private var wC: NSLayoutConstraint!
    private var hC: NSLayoutConstraint!
    private var target: (cols: Int, rows: Int)?
    private(set) var metrics: TerminalGridMetrics?
    private var inputBox = InputBox()
    final class InputBox { var handler: ((Data) -> Void)? }

    override init() {
        let box = inputBox
        session = InMemoryTerminalSession(
            write: { data in DispatchQueue.main.async { box.handler?(data) } },
            resize: { _ in })
        controller = TerminalController { b in
            b.withFontSize(10)
            b.withWindowPaddingX(0)
            b.withWindowPaddingY(0)
        }
        tv = TerminalView(frame: CGRect(x: 0, y: 0, width: 900, height: 700))
        super.init()
        inputBox.handler = { [weak self] d in self?.onInput?(d) }
        tv.translatesAutoresizingMaskIntoConstraints = false
        tv.delegate = self
        tv.controller = controller
        tv.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
        wC = tv.widthAnchor.constraint(equalToConstant: 900)
        hC = tv.heightAnchor.constraint(equalToConstant: 700)
        NSLayoutConstraint.activate([wC, hC])
    }

    var gridSize: (cols: Int, rows: Int) {
        guard let m = metrics else { return (0, 0) }
        return (Int(m.columns), Int(m.rows))
    }

    func feed(_ bytes: Data) { session.receive(bytes) }

    func drain() async {
        while session.pendingOutputByteCount > 0 { try? await Task.sleep(nanoseconds: 5_000_000) }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }

    func resize(cols: Int, rows: Int) { target = (cols, rows); adjust() }

    private func adjust() {
        guard let t = target, let m = metrics, m.cellWidthPixels > 0 else { return }
        let scale = tv.window?.screen.scale ?? UIScreen.main.scale
        let w = (CGFloat(m.cellWidthPixels) * CGFloat(t.cols) + 0.25 * CGFloat(m.cellWidthPixels)) / scale
        let h = (CGFloat(m.cellHeightPixels) * CGFloat(t.rows) + 0.25 * CGFloat(m.cellHeightPixels)) / scale
        if abs(wC.constant - w) > 0.01 || abs(hC.constant - h) > 0.01 {
            wC.constant = w; hC.constant = h
            tv.superview?.setNeedsLayout()
        }
    }

    func screenText() -> String {
        (session.readViewportText() ?? "").split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) }
            .joined(separator: "\n")
    }

    // Delegate
    func terminalDidResize(_ size: TerminalGridMetrics) { metrics = size; adjust() }
}
