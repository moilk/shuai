import UIKit

final class ViewController: UIViewController, UITextFieldDelegate {
    let seg = UISegmentedControl(items: ["Ghostty", "SwiftTerm"])
    let status = UILabel()
    let host = UIView()
    let field = UITextField()
    let fixture = Fixture.load()
    var engine: TerminalEngine!
    var replayTask: Task<Void, Never>?
    let defaults = UserDefaults.standard

    override func viewDidLoad() {
        super.viewDidLoad()
        overrideUserInterfaceStyle = .dark
        view.backgroundColor = .systemBackground
        seg.selectedSegmentIndex = defaults.string(forKey: "engine") == "swiftterm" ? 1 : 0
        seg.addTarget(self, action: #selector(engineChanged), for: .valueChanged)
        status.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        status.numberOfLines = 2
        let btns = UIStackView(arrangedSubviews: [
            button("Instant") { [weak self] in self?.replay(timed: false) },
            button("Timed") { [weak self] in self?.replay(timed: true) },
            button("Reset") { [weak self] in self?.engine.feed(Data("\u{1b}c".utf8)) },
        ])
        btns.spacing = 8
        field.borderStyle = .roundedRect
        field.placeholder = "type here (IME test, echo to terminal)"
        field.delegate = self
        field.returnKeyType = .send
        let top = UIStackView(arrangedSubviews: [seg, btns, field])
        top.axis = .horizontal; top.spacing = 12; top.alignment = .center
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        for v in [top, status, host] { v.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(v) }
        host.backgroundColor = .black
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            top.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            top.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            status.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 6),
            status.leadingAnchor.constraint(equalTo: top.leadingAnchor),
            status.trailingAnchor.constraint(equalTo: top.trailingAnchor),
            host.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 6),
            host.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
        ])
        installEngine()
        if defaults.string(forKey: "auto") != nil { Task { await autoRun() } }
    }

    func button(_ t: String, _ a: @escaping () -> Void) -> UIButton {
        UIButton(type: .system, primaryAction: UIAction(title: t) { _ in a() })
    }

    @objc func engineChanged() { installEngine() }

    func installEngine() {
        replayTask?.cancel()
        engine?.view.removeFromSuperview()
        engine = seg.selectedSegmentIndex == 0 ? GhosttyEngine() : SwiftTermEngine()
        let v = engine.view
        host.addSubview(v)
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: host.topAnchor),
            v.leadingAnchor.constraint(equalTo: host.leadingAnchor),
        ])
        engine.onInput = { [weak self] data in
            // Local echo: what the terminal view would send to the remote.
            var out = data
            if data == Data([0x0D]) { out = Data([0x0D, 0x0A]) }
            if data.first != 0x1B { self?.engine.feed(out) }  // don't echo escape-sequence replies
            self?.status.text = "onInput: \(data.map { String(format: "%02x", $0) }.joined(separator: " ").prefix(120))"
        }
        engine.resize(cols: 120, rows: 40)
        refreshStatus()
    }

    func refreshStatus() {
        let g = engine.gridSize
        status.text = "engine=\(seg.selectedSegmentIndex == 0 ? "ghostty" : "swiftterm") grid=\(g.cols)x\(g.rows)"
    }

    func replay(timed: Bool) {
        replayTask?.cancel()
        if !timed { engine.feed(fixture.all); refreshStatus(); return }
        let e = engine!
        engine.feed(fixture.header)
        replayTask = Task { @MainActor in
            for c in fixture.chunks {
                try? await Task.sleep(nanoseconds: UInt64(min(c.delay, 2.0) * 1e9))
                if Task.isCancelled { return }
                e.feed(c.bytes)
            }
            e.feed(fixture.footer)
        }
    }

    func textFieldShouldReturn(_ tf: UITextField) -> Bool {
        engine.feed(Data((tf.text ?? "").utf8)); engine.feed(Data("\r\n".utf8)); tf.text = ""; return true
    }

    // MARK: automation (launch args: -auto dump|bench -engine ghostty|swiftterm -prefix 1)
    func autoRun() async {
        let eng = defaults.string(forKey: "engine") ?? "ghostty"
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        engine.resize(cols: 120, rows: 40)
        for _ in 0..<30 {
            try? await Task.sleep(nanoseconds: 200_000_000)
            let g = engine.gridSize
            if g.cols == 120 && g.rows == 40 { break }
            engine.resize(cols: 120, rows: 40)
        }
        try? await Task.sleep(nanoseconds: 500_000_000)
        refreshStatus()
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        var report: [String: Any] = ["engine": eng, "grid": "\(engine.gridSize.cols)x\(engine.gridSize.rows)"]
        let mode = defaults.string(forKey: "auto")!
        let prefix = defaults.bool(forKey: "prefix")
        let data: Data = prefix
            ? try! Data(contentsOf: Bundle.main.url(forResource: "pre-exit", withExtension: "out")!)
            : fixture.all
        report["footprintBeforeMB"] = Self.footprintMB()
        if mode == "dump" || mode == "both" {
            engine.feed(data)
            await engine.drain()
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            try? engine.screenText().write(to: docs.appendingPathComponent("dump-\(eng)\(prefix ? "-pre" : "").txt"), atomically: true, encoding: .utf8)
            report["footprintAfterReplayMB"] = Self.footprintMB()
        }
        if mode == "bench" || mode == "both" {
            let n = 50
            let t0 = CFAbsoluteTimeGetCurrent()
            for _ in 0..<n { engine.feed(fixture.all) }
            let tFeed = CFAbsoluteTimeGetCurrent() - t0
            await engine.drain()
            let t1 = CFAbsoluteTimeGetCurrent() - t0
            report["bench_N"] = n
            report["bench_bytes_each"] = fixture.all.count
            report["bench_feedCallsSec"] = tFeed
            report["bench_totalUntilParsedSec"] = t1
            report["bench_MBps"] = Double(n * fixture.all.count) / 1e6 / t1
            report["footprintAfterBenchMB"] = Self.footprintMB()
        }
        let j = try! JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try? j.write(to: docs.appendingPathComponent("report-\(eng).json"))
        status.text = "auto done " + String(data: j, encoding: .utf8)!.replacingOccurrences(of: "\n", with: " ")
    }

    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }
}
