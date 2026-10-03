import Foundation
import Testing
@testable import ShuaiTerminal

@Suite("AccessoryBarModel: sticky modifiers")
struct AccessoryBarStickyTests {
    @Test func startsInactive() {
        let m = AccessoryBarModel()
        #expect(m.ctrl == .off)
        #expect(m.alt == .off)
        #expect(!m.hasActiveModifiers)
    }

    @Test func tapCyclesOffOneShotLockedOff() {
        var m = AccessoryBarModel()
        #expect(m.press(.ctrl).isEmpty)
        #expect(m.ctrl == .oneShot)
        #expect(m.press(.ctrl).isEmpty)
        #expect(m.ctrl == .locked)
        #expect(m.press(.ctrl).isEmpty)
        #expect(m.ctrl == .off)
    }

    @Test func ctrlAndAltAreIndependent() {
        var m = AccessoryBarModel()
        _ = m.press(.ctrl)
        _ = m.press(.alt)
        #expect(m.ctrl == .oneShot)
        #expect(m.alt == .oneShot)
        #expect(m.hasActiveModifiers)
    }

    @Test func oneShotAppliesToNextKeyThenClears() {
        var m = AccessoryBarModel()
        _ = m.press(.ctrl)
        #expect(m.press(.symbol("c")) == [KeyStroke(.character("c"), .ctrl)])
        #expect(m.ctrl == .off)
        #expect(m.press(.symbol("c")) == [KeyStroke(.character("c"))])
    }

    @Test func lockedPersistsAcrossKeys() {
        var m = AccessoryBarModel()
        _ = m.press(.ctrl)
        _ = m.press(.ctrl)
        #expect(m.press(.symbol("a")) == [KeyStroke(.character("a"), .ctrl)])
        #expect(m.press(.symbol("e")) == [KeyStroke(.character("e"), .ctrl)])
        #expect(m.ctrl == .locked)
    }

    @Test func ctrlAndAltCombine() {
        var m = AccessoryBarModel()
        _ = m.press(.ctrl)
        _ = m.press(.alt)
        #expect(m.press(.arrow(.left)) == [KeyStroke(.arrow(.left), [.ctrl, .alt])])
        #expect(!m.hasActiveModifiers)
    }

    @Test func appliesToExternalSoftwareKeyboardText() {
        var m = AccessoryBarModel()
        _ = m.press(.ctrl)
        #expect(m.apply(to: KeyStroke(.character("d"))) == KeyStroke(.character("d"), .ctrl))
        #expect(m.ctrl == .off)
        #expect(m.apply(to: KeyStroke(.character("d"))) == KeyStroke(.character("d")))
    }

    @Test func resetClearsEverything() {
        var m = AccessoryBarModel()
        _ = m.press(.ctrl)
        _ = m.press(.ctrl)
        _ = m.press(.alt)
        m.reset()
        #expect(!m.hasActiveModifiers)
    }
}

@Suite("AccessoryBarModel: keys")
struct AccessoryBarKeyTests {
    @Test func basicKeys() {
        var m = AccessoryBarModel()
        #expect(m.press(.esc) == [KeyStroke(.escape)])
        #expect(m.press(.tab) == [KeyStroke(.tab)])
        #expect(m.press(.up) == [KeyStroke(.arrow(.up))])
        #expect(m.press(.down) == [KeyStroke(.arrow(.down))])
        #expect(m.press(.left) == [KeyStroke(.arrow(.left))])
        #expect(m.press(.right) == [KeyStroke(.arrow(.right))])
        #expect(m.press(.symbol("/")) == [KeyStroke(.character("/"))])
        #expect(m.press(.symbol("|")) == [KeyStroke(.character("|"))])
        #expect(m.press(.symbol("~")) == [KeyStroke(.character("~"))])
        #expect(m.press(.symbol("-")) == [KeyStroke(.character("-"))])
    }

    @Test func arrowsAreRepeatableOthersAreNot() {
        for b in [AccessoryButton.up, .down, .left, .right] {
            #expect(AccessoryBarModel.isRepeatable(b))
        }
        for b in [AccessoryButton.esc, .tab, .ctrl, .alt, .symbol("/"), .claudeYes, .claudeCtrlC] {
            #expect(!AccessoryBarModel.isRepeatable(b))
        }
    }

    @Test func stickyCtrlWithEscapeProducesModifiedEscape() {
        var m = AccessoryBarModel()
        _ = m.press(.alt)
        #expect(m.press(.esc) == [KeyStroke(.escape, .alt)])
    }

    @Test func standardRowContainsRequestedKeys() {
        let row = AccessoryButton.standardRow
        for b in [AccessoryButton.esc, .ctrl, .alt, .tab, .up, .down, .left, .right,
                  .symbol("/"), .symbol("|"), .symbol("~"), .symbol("-")] {
            #expect(row.contains(b))
        }
    }
}

@Suite("AccessoryBarModel: Claude strip")
struct AccessoryBarClaudeTests {
    @Test func yesNoAlways() {
        var m = AccessoryBarModel()
        #expect(m.press(.claudeYes) == [KeyStroke(.character("1"))])
        #expect(m.press(.claudeAlways) == [KeyStroke(.character("2"))])
        #expect(m.press(.claudeNo) == [KeyStroke(.escape)])
    }

    @Test func modeCycleIsShiftTab() {
        var m = AccessoryBarModel()
        #expect(m.press(.claudeModeCycle) == [KeyStroke(.tab, .shift)])
        #expect(m.bytes(for: .claudeModeCycle) == Data([0x1B, 0x5B, 0x5A]))
    }

    @Test func interruptAndCtrlC() {
        var m = AccessoryBarModel()
        #expect(m.press(.claudeInterrupt) == [KeyStroke(.escape)])
        #expect(m.press(.claudeCtrlC) == [KeyStroke(.character("c"), .ctrl)])
        #expect(m.bytes(for: .claudeCtrlC) == Data([0x03]))
    }

    @Test func slashCommands() {
        var m = AccessoryBarModel()
        #expect(m.press(.claudeSlash) == [KeyStroke(.character("/"))])
    }

    @Test func claudeKeysIgnoreAndKeepStickyModifiers() {
        var m = AccessoryBarModel()
        _ = m.press(.ctrl)
        #expect(m.press(.claudeYes) == [KeyStroke(.character("1"))])
        #expect(m.ctrl == .oneShot)
    }

    @Test func claudeStripLayout() {
        let strip = AccessoryButton.claudeStrip
        #expect(strip == [.claudeYes, .claudeAlways, .claudeNo, .claudeModeCycle,
                          .claudeInterrupt, .claudeCtrlC, .claudeSlash])
    }

    @Test func bytesHelperEncodesViaKeyEncoder() {
        var m = AccessoryBarModel()
        #expect(m.bytes(for: .esc) == Data([0x1B]))
        #expect(m.bytes(for: .up) == Data([0x1B, 0x5B, 0x41]))
        #expect(m.bytes(for: .up, options: KeyEncoderOptions(applicationCursorKeys: true))
            == Data([0x1B, 0x4F, 0x41]))
        _ = m.press(.ctrl)
        #expect(m.bytes(for: .symbol("c")) == Data([0x03]))
        #expect(m.bytes(for: .ctrl).isEmpty)
    }
}
