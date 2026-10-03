#if DEBUG
import SwiftUI
import ShuaiTerminal

/// DEBUG-only playground for the terminal view: replays the recorded Claude Code session
/// (fixtures/recordings/claude-cjk-120x40.out) or echoes typed input back (to test IME by hand).
struct TerminalDebugScreen: View {
    enum Mode: String, CaseIterable, Identifiable {
        case replay = "Replay Claude"
        case echo = "Echo"
        var id: String { rawValue }
    }

    @State private var engine = GhosttyEngine(fontSize: 10)
    @State private var mode: Mode = .replay
    @State private var lastInput = ""
    @State private var gridText = ""
    @State private var showFloatingBar = false
    @State private var pendingClipboard: ClipboardRequest?
    @State private var lastEvent = ""
    @State private var fixedSize: CGSize?
    @State private var pendingReplay = false

    var body: some View {
        VStack(spacing: 0) {
            controls
            TerminalViewRepresentable(engine: engine, showsFloatingAccessoryBar: showFloatingBar)
                .frame(width: fixedSize?.width, height: fixedSize?.height)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .accessibilityIdentifier("terminal-view")
            Text("grid \(gridText) | input \(lastInput) | \(lastEvent)")
                .font(.caption.monospaced())
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
        }
        .navigationTitle("Terminal")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: configure)
        .alert("Remote wants to write the clipboard", isPresented: Binding(
            get: { pendingClipboard != nil },
            set: { if !$0 { pendingClipboard?.respond(allow: false); pendingClipboard = nil } }
        )) {
            Button("Allow") { pendingClipboard?.respond(allow: true); pendingClipboard = nil }
            Button("Deny", role: .cancel) { pendingClipboard?.respond(allow: false); pendingClipboard = nil }
        } message: {
            Text(String((pendingClipboard?.contents ?? "").prefix(200)))
        }
    }

    private var controls: some View {
        HStack {
            Picker("Mode", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 320)
            .onChange(of: mode) { _, new in run(new) }
            Button("Reset") { engine.feed(Data("\u{1B}c".utf8)); run(mode) }
            Toggle("Float bar", isOn: $showFloatingBar).fixedSize()
            Spacer()
        }
        .padding(8)
    }

    private func configure() {
        engine.onInput = { data in
            lastInput = data.map { String(format: "%02x", $0) }.joined(separator: " ")
            if mode == .echo { engine.feed(EchoTransform.transform(data)) }
        }
        engine.onResize = {
            gridText = "\($0.cols)x\($0.rows)"
            if fixedSize == nil || $0.cols != 120 { fixedSize = engine.pointSize(cols: 120, rows: 40) }
            if pendingReplay && $0.cols == 120 && $0.rows == 40 { replay() }
        }
        engine.onTitleChange = { lastEvent = "title: \($0)" }
        engine.onBell = { lastEvent = "bell" }
        engine.onNotification = { lastEvent = "notify: \($0.title) / \($0.body)" }
        engine.onHyperlink = { lastEvent = "link: \($0.absoluteString)" }
        engine.onClipboardRequest = { pendingClipboard = $0 }
        run(mode)
    }

    private func run(_ mode: Mode) {
        switch mode {
        case .replay:
            // The recording is 120x40; replay once the view has exactly that grid.
            pendingReplay = true
            if engine.gridSize.cols == 120 && engine.gridSize.rows == 40 { replay() }
        case .echo:
            engine.feed(Data("\u{1B}[2J\u{1B}[HEcho mode: typed bytes are echoed (^X = control). Try Pinyin: nihao.\r\n".utf8))
        }
    }

    private func replay() {
        pendingReplay = false
        guard let url = Bundle.main.url(forResource: "claude-cjk-120x40-pre-exit", withExtension: "out"),
              let data = try? Data(contentsOf: url) else {
            engine.feed(Data("fixture missing\r\n".utf8))
            return
        }
        engine.feed(data)
    }
}
#endif