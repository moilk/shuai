#if canImport(GhosttyTerminal) && canImport(UIKit)
import Foundation
import GhosttyTerminal
import Testing
import UIKit
@testable import ShuaiTerminal

private func footprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
}

@MainActor
@Suite("GhosttyEngine hardening", .serialized)
struct GhosttyEngineHardeningTests {
    // MARK: theme

    @Test func themeIsDarkEvenWhenSystemAppearanceIsLight() async {
        let h = await EngineHarness()
        h.window.overrideUserInterfaceStyle = .light
        h.window.rootViewController?.view.layoutIfNeeded()
        await h.engine.settle()
        let cfg = h.engine.controller.renderedConfig
        #expect(cfg.contains("background = #2C2525"), "\(cfg)")
        #expect(cfg.contains("foreground = #FFF1F3"))
        #expect(cfg.contains("palette = 4=#F38D70"))
        #expect(h.engine.controller.backgroundColor == TerminalColor(red: 0x2C, green: 0x25, blue: 0x25))
        #expect(h.engine.view.overrideUserInterfaceStyle == .dark)
    }

    @Test func themeCanBeSwitchedLive() async {
        let h = await EngineHarness()
        h.engine.apply(theme: .claudeLight)
        await h.engine.settle()
        #expect(h.engine.controller.renderedConfig.contains("background = #FFFFFF"))
        #expect(h.engine.view.overrideUserInterfaceStyle == .light)
        h.engine.apply(theme: .claudeDark)
        await h.engine.settle()
        #expect(h.engine.controller.renderedConfig.contains("background = #1E1E2E"))
    }

    @Test func scrollbackLimitIsConfigured() async {
        let h = await EngineHarness()
        #expect(h.engine.controller.renderedConfig
            .contains("scrollback-limit = \(ScrollbackPolicy.limitBytes(lines: 10_000))"))
    }

    // MARK: threading

    @Test func allCallbacksArriveOnTheMainThread() async {
        let h = await EngineHarness()
        var threads: [Bool] = []
        h.engine.onInput = { _ in threads.append(Thread.isMainThread) }
        h.engine.onTitleChange = { _ in threads.append(Thread.isMainThread) }
        h.engine.onBell = { threads.append(Thread.isMainThread) }
        h.engine.onNotification = { _ in threads.append(Thread.isMainThread) }
        h.engine.onResize = { _ in threads.append(Thread.isMainThread) }
        await h.feed("\u{1B}[c\u{1B}]0;t\u{07}\u{07}\u{1B}]9;hi\u{07}")
        h.engine.resize(cols: 90, rows: 30)
        h.window.rootViewController?.view.layoutIfNeeded()
        await h.engine.settle()
        #expect(threads.count >= 4)
        #expect(!threads.contains(false))
    }

    // MARK: clipboard shortcuts

    @Test func pasteIsDeliveredExactlyOnce() async {
        let h = await EngineHarness()
        await h.feed("\u{1B}[?2004h")
        // (UIPasteboard reads are not authorized in the test host, so drive the paste path directly.)
        h.engine.paste("once")
        await h.engine.settle()
        let count = h.inputString.components(separatedBy: "once").count - 1
        #expect(count == 1, "\(h.inputString.debugDescription)")
        #expect(h.inputString.components(separatedBy: "\u{1B}[200~").count - 1 == 1)
    }

    @Test func viewRegistersNoCommandKeyCommands() async {
        // Cmd+C / Cmd+V reach copy:/paste: through the responder chain; an extra UIKeyCommand for them
        // would deliver every shortcut twice.
        let h = await EngineHarness()
        let cmds = h.engine.view.keyCommands ?? []
        #expect(!cmds.contains { $0.modifierFlags.contains(.command) && ["c", "v"].contains($0.input?.lowercased() ?? "") })
    }

    // MARK: sticky modifiers on the software keyboard path

    @Test func stickyCtrlLetterTypedOnSoftwareKeyboardSendsControlByte() async {
        let h = await EngineHarness()
        h.engine.view.dockedAccessoryBar.tap(.ctrl)
        h.engine.view.insertText("c")
        await h.engine.settle()
        #expect(h.input == Data([0x03]), "\(h.input as NSData)")
        // One-shot is spent: the next letter is plain.
        h.clearInput()
        h.engine.view.insertText("c")
        await h.engine.settle()
        #expect(h.input == Data("c".utf8))
    }

    @Test func stickyAltLetterTypedOnSoftwareKeyboardSendsEscapePrefix() async {
        let h = await EngineHarness()
        h.engine.view.dockedAccessoryBar.tap(.alt)
        h.engine.view.insertText("b")
        await h.engine.settle()
        #expect(h.input == Data([0x1B, 0x62]), "\(h.input as NSData)")
    }

    // MARK: resize

    @Test func gridNeverCollapsesToZero() async {
        let h = await EngineHarness()
        h.engine.resize(cols: 0, rows: 0)
        h.window.rootViewController?.view.layoutIfNeeded()
        await h.engine.settle()
        #expect(h.engine.gridSize.isValid)
        #expect(h.resizes.allSatisfy { $0.isValid })
    }

    @Test func resizeBurstIsDebouncedToTheFinalGrid() async throws {
        let h = await EngineHarness(cols: 100, rows: 30, resizeDebounce: 0.3)
        let before = h.resizes.count
        // Rotation / Stage Manager drag / keyboard show-hide: many layouts in quick succession.
        for (c, r) in [(90, 30), (80, 26), (70, 22), (60, 20)] {
            h.engine.resize(cols: c, rows: r)
            h.window.rootViewController?.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(h.resizes.count == before, "no window-change during the burst")
        try await Task.sleep(for: .milliseconds(600))
        #expect(h.resizes.count == before + 1)
        #expect(h.resizes.last == TerminalGridSize(cols: 60, rows: 20))
        #expect(h.engine.gridSize == TerminalGridSize(cols: 60, rows: 20))
        #expect(h.resizes.allSatisfy { $0.isValid })
    }

    // MARK: memory

    @Test func replayingTheFixture200TimesDoesNotGrowWithoutBound() async throws {
        let h = await EngineHarness(cols: 120, rows: 40)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("fixtures/recordings/claude-cjk-120x40-pre-exit.out"))
        var warm = 0.0
        for i in 1 ... 200 {
            h.engine.feed(data)
            if i % 10 == 0 { await h.engine.settle() }
            if i == 40 { warm = footprintMB() }
        }
        await h.engine.settle()
        let end = footprintMB()
        // Scrollback is capped (10k lines ~ 13 MB); without a cap 200 x 46 KB of output keeps growing.
        #expect(end - warm < 60, "footprint \(warm) MB -> \(end) MB")
        #expect(h.engine.gridSize == TerminalGridSize(cols: 120, rows: 40))
        #expect(!(h.engine.readScreenText() ?? "").isEmpty)
    }
}
#endif
