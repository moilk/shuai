#if canImport(GhosttyTerminal) && canImport(UIKit)
import Foundation
import Testing
import UIKit
@testable import ShuaiTerminal

/// Runs against the real libghostty surface; needs the iOS simulator
/// (`xcodebuild test -scheme ShuaiKit-Package -destination 'platform=iOS Simulator,...'`).
@MainActor
final class EngineHarness {
    let engine: GhosttyEngine
    let window: UIWindow
    var input = Data()
    var titles: [String] = []
    var bells = 0
    var notifications: [TerminalNotification] = []
    var clipboardRequests: [ClipboardRequest] = []
    var resizes: [TerminalGridSize] = []

    init(cols: Int = 100, rows: Int = 30) async {
        engine = GhosttyEngine()
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1200, height: 900))
        window.rootViewController = UIViewController()
        window.rootViewController?.view.addSubview(engine.view)
        window.makeKeyAndVisible()
        engine.onInput = { [unowned self] in input.append($0) }
        engine.onTitleChange = { [unowned self] in titles.append($0) }
        engine.onBell = { [unowned self] in bells += 1 }
        engine.onNotification = { [unowned self] in notifications.append($0) }
        engine.onClipboardRequest = { [unowned self] in clipboardRequests.append($0) }
        engine.onResize = { [unowned self] in resizes.append($0) }
        engine.resize(cols: cols, rows: rows)
        window.rootViewController?.view.layoutIfNeeded()
        await engine.settle()
        window.rootViewController?.view.layoutIfNeeded()
        await engine.settle()
    }

    func feed(_ s: String) async {
        engine.feed(Data(s.utf8))
        await engine.settle()
    }

    var inputString: String { String(decoding: input, as: UTF8.self) }
    func clearInput() { input.removeAll() }
}

@MainActor
@Suite("GhosttyEngine", .serialized)
struct GhosttyEngineTests {
    // MARK: grid / feed

    @Test func fixedGridSizeIsReported() async {
        let h = await EngineHarness(cols: 120, rows: 40)
        #expect(h.engine.gridSize == TerminalGridSize(cols: 120, rows: 40))
        #expect(h.resizes.last == TerminalGridSize(cols: 120, rows: 40))
    }

    @Test func feedRendersTextIncludingCJK() async {
        let h = await EngineHarness()
        await h.feed("hello 你好 world\r\n")
        let text = h.engine.readScreenText() ?? ""
        #expect(text.contains("hello 你好 world"))
    }

    // MARK: queries answered by the engine are routed to onInput

    @Test func answersDECRQM2026SoClaudeCodeEnablesSynchronizedOutput() async {
        let h = await EngineHarness()
        await h.feed("\u{1B}[?2026$p")
        // DECRPM: ESC [ ? 2026 ; Ps $ y with Ps 1 (set) or 2 (reset) = "recognized".
        #expect(h.inputString == "\u{1B}[?2026;2$y")
        h.clearInput()
        await h.feed("\u{1B}[?2026h\u{1B}[?2026$p")
        #expect(h.inputString == "\u{1B}[?2026;1$y")
        await h.feed("\u{1B}[?2026l")
    }

    @Test func answersPrimaryDeviceAttributes() async {
        let h = await EngineHarness()
        await h.feed("\u{1B}[c")
        #expect(h.inputString.hasPrefix("\u{1B}[?"))
        #expect(h.inputString.hasSuffix("c"))
    }

    @Test func answersKittyKeyboardQuery() async {
        let h = await EngineHarness()
        await h.feed("\u{1B}[?u")
        #expect(h.inputString == "\u{1B}[?0u")
        h.clearInput()
        await h.feed("\u{1B}[>1u\u{1B}[?u")
        #expect(h.inputString == "\u{1B}[?1u")
    }

    @Test func answersDECRQMForBracketedPaste() async {
        let h = await EngineHarness()
        await h.feed("\u{1B}[?2004$p")
        #expect(h.inputString == "\u{1B}[?2004;2$y")
    }

    // MARK: events

    @Test func titleChange() async {
        let h = await EngineHarness()
        await h.feed("\u{1B}]2;my title\u{07}")
        #expect(h.engine.title == "my title")
        #expect(h.titles.last == "my title")
    }

    @Test func bell() async {
        let h = await EngineHarness()
        await h.feed("\u{07}")
        #expect(h.bells == 1)
    }

    @Test func osc9Notification() async {
        let h = await EngineHarness()
        await h.feed("\u{1B}]9;Build finished\u{07}")
        #expect(h.notifications.count == 1)
        #expect(h.notifications.first?.body == "Build finished")
    }

    @Test func osc777Notification() async {
        let h = await EngineHarness()
        await h.feed("\u{1B}]777;notify;Claude Code;Needs your approval\u{07}")
        #expect(h.notifications.first == TerminalNotification(title: "Claude Code", body: "Needs your approval"))
    }

    @Test func osc52WriteRequiresAppConfirmation() async {
        let h = await EngineHarness()
        UIPasteboard.general.string = "untouched"
        await h.feed("\u{1B}]52;c;\(Data("secret".utf8).base64EncodedString())\u{07}")
        #expect(h.clipboardRequests.count == 1)
        #expect(h.clipboardRequests.first?.kind == .osc52Write)
        #expect(h.clipboardRequests.first?.contents == "secret")
        #expect(UIPasteboard.general.string == "untouched")
        h.clipboardRequests.first?.respond(allow: false)
        await h.engine.settle()
        #expect(UIPasteboard.general.string == "untouched")
    }

    @Test func osc52WriteAllowedLandsOnPasteboard() async {
        let h = await EngineHarness()
        UIPasteboard.general.string = "untouched"
        await h.feed("\u{1B}]52;c;\(Data("approved".utf8).base64EncodedString())\u{07}")
        h.clipboardRequests.first?.respond(allow: true)
        await h.engine.settle()
        #expect(UIPasteboard.general.string == "approved")
    }

    // MARK: paste and keys

    @Test func pasteIsBracketedOnlyWhenRemoteEnabledIt() async {
        let h = await EngineHarness()
        h.engine.paste("one\ntwo")
        await h.engine.settle()
        #expect(!h.inputString.contains("\u{1B}[200~"))
        h.clearInput()
        await h.feed("\u{1B}[?2004h")
        h.engine.paste("one\ntwo")
        await h.engine.settle()
        #expect(h.inputString == "\u{1B}[200~one\ntwo\u{1B}[201~")
    }

    @Test func keyStrokesUseGhosttyEncoderAndRespectCursorKeyMode() async {
        let h = await EngineHarness()
        h.engine.sendKey(KeyStroke(.arrow(.up)))
        await h.engine.settle()
        #expect(h.inputString == "\u{1B}[A")
        h.clearInput()
        await h.feed("\u{1B}[?1h")
        h.engine.sendKey(KeyStroke(.arrow(.up)))
        await h.engine.settle()
        #expect(h.inputString == "\u{1B}OA")
    }

    @Test func shiftTabIsCSIZ() async {
        let h = await EngineHarness()
        h.engine.sendKey(KeyStroke(.tab, .shift))
        await h.engine.settle()
        #expect(h.inputString == "\u{1B}[Z")
    }

    @Test func ctrlCAndEscape() async {
        let h = await EngineHarness()
        h.engine.sendKey(KeyStroke(.character("c"), .ctrl))
        h.engine.sendKey(KeyStroke(.escape))
        await h.engine.settle()
        #expect(h.input == Data([0x03, 0x1B]))
    }

    @Test func altSendsEscapePrefix() async {
        let h = await EngineHarness()
        h.engine.sendKey(KeyStroke(.character("b"), .alt))
        await h.engine.settle()
        #expect(h.input == Data([0x1B, 0x62]))
    }

    @Test func kittyKeyboardProtocolIsHonouredWhenRemoteEnablesIt() async {
        let h = await EngineHarness()
        await h.feed("\u{1B}[>1u")
        h.engine.sendKey(KeyStroke(.escape))
        await h.engine.settle()
        #expect(h.inputString == "\u{1B}[27u")
    }

    @Test func nonUSCharactersFallBackToUTF8() async {
        let h = await EngineHarness()
        h.engine.sendKey(KeyStroke(.character("你")))
        await h.engine.settle()
        #expect(h.input == Data("你".utf8))
    }

    // MARK: mouse

    @Test func mouseReportingFlagFollowsRemoteMode() async {
        let h = await EngineHarness()
        #expect(!h.engine.isMouseReportingEnabled)
        await h.feed("\u{1B}[?1000h\u{1B}[?1006h")
        #expect(h.engine.isMouseReportingEnabled)
    }

    // MARK: IME (UITextInput)

    @Test func markedTextDoesNotReachTheRemoteUntilCommitted() async {
        let h = await EngineHarness()
        let v = h.engine.view
        v.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0))
        v.setMarkedText("ni hao", selectedRange: NSRange(location: 6, length: 0))
        await h.engine.settle()
        #expect(h.input.isEmpty)
        #expect(v.markedTextRange != nil)
        v.insertText("你好")
        await h.engine.settle()
        #expect(h.input == Data("你好".utf8))
        #expect(!h.inputString.contains("\r"))
        #expect(v.markedTextRange == nil)
    }

    @Test func backspaceEditsCompositionNotRemote() async {
        let h = await EngineHarness()
        let v = h.engine.view
        v.setMarkedText("nih", selectedRange: NSRange(location: 3, length: 0))
        v.deleteBackward()
        await h.engine.settle()
        #expect(h.input.isEmpty)
        #expect(v.markedTextRange != nil)
        #expect(v.markedTextRange.flatMap { v.text(in: $0) } == "ni")
    }

    @Test func caretAndCandidateRectsAreAtTheCursorCell() async {
        let h = await EngineHarness()
        await h.feed("\u{1B}[10;20H") // cursor to row 10 col 20
        let v = h.engine.view
        v.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0))
        let caret = v.caretRect(for: v.endOfDocument)
        let first = v.firstRect(for: v.textRange(from: v.beginningOfDocument, to: v.endOfDocument)!)
        #expect(caret.minX > 50 && caret.minY > 50, "caret must be inside the grid, got \(caret)")
        #expect(first.height > 0 && first.height < 100)
        #expect(first != v.bounds)
    }

    // MARK: fixture

    @Test func replaysRecordedClaudeSession() async throws {
        let h = await EngineHarness(cols: 120, rows: 40)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("fixtures/recordings/claude-cjk-120x40.out"))
        for chunk in stride(from: 0, to: data.count, by: 4096) {
            h.engine.feed(data.subdata(in: chunk ..< min(chunk + 4096, data.count)))
        }
        await h.engine.settle()
        #expect(h.engine.gridSize == TerminalGridSize(cols: 120, rows: 40))
        // Kitty keyboard flags pushed by the recording are in effect afterwards or popped; the query must answer.
        h.clearInput()
        await h.feed("\u{1B}[?u")
        #expect(h.inputString.hasPrefix("\u{1B}[?"))
    }
}
#endif
