import Foundation
import Testing
@testable import ShuaiTerminal

private func enc(
    _ key: Key,
    _ mods: KeyModifiers = [],
    app: Bool = false,
    altEsc: Bool = true
) -> [UInt8]? {
    KeyEncoder.encode(
        KeyStroke(key, mods),
        options: KeyEncoderOptions(applicationCursorKeys: app, altSendsEscape: altEsc)
    ).map { [UInt8]($0) }
}

private func esc(_ s: String) -> [UInt8] { [0x1B] + Array(s.utf8) }

@Suite("KeyEncoder: printable and control")
struct KeyEncoderTextTests {
    @Test func plainCharacters() {
        #expect(enc(.character("a")) == [0x61])
        #expect(enc(.character("Z")) == [0x5A])
        #expect(enc(.character("/")) == [0x2F])
        #expect(enc(.character("|")) == [0x7C])
        #expect(enc(.character("~")) == [0x7E])
        #expect(enc(.character("-")) == [0x2D])
        #expect(enc(.character("1")) == [0x31])
        #expect(enc(.space) == [0x20])
    }

    @Test func unicodeCharactersAreUTF8() {
        #expect(enc(.character("你")) == [0xE4, 0xBD, 0xA0])
        #expect(enc(.character("é")) == [0xC3, 0xA9])
        #expect(enc(.character("😀")) == [0xF0, 0x9F, 0x98, 0x80])
    }

    @Test(arguments: Array("abcdefghijklmnopqrstuvwxyz").enumerated().map { ($0.offset, $0.element) })
    func ctrlLetters(_ index: Int, _ ch: Character) {
        #expect(enc(.character(ch), .ctrl) == [UInt8(index + 1)])
        #expect(enc(.character(Character(ch.uppercased())), .ctrl) == [UInt8(index + 1)])
        #expect(enc(.character(ch), [.ctrl, .shift]) == [UInt8(index + 1)])
    }

    @Test func ctrlPunctuation() {
        #expect(enc(.character("["), .ctrl) == [0x1B])
        #expect(enc(.character("\\"), .ctrl) == [0x1C])
        #expect(enc(.character("]"), .ctrl) == [0x1D])
        #expect(enc(.character("^"), .ctrl) == [0x1E])
        #expect(enc(.character("_"), .ctrl) == [0x1F])
        #expect(enc(.character("-"), .ctrl) == [0x1F])
        #expect(enc(.character("@"), .ctrl) == [0x00])
        #expect(enc(.character("2"), .ctrl) == [0x00])
        #expect(enc(.space, .ctrl) == [0x00])
        #expect(enc(.character("?"), .ctrl) == [0x7F])
    }

    @Test func ctrlOnNonControllableCharPassesThrough() {
        #expect(enc(.character("1"), .ctrl) == [0x31])
        #expect(enc(.character("你"), .ctrl) == [0xE4, 0xBD, 0xA0])
    }

    @Test func altSendsEscapePrefix() {
        #expect(enc(.character("b"), .alt) == esc("b"))
        #expect(enc(.character("f"), .alt) == esc("f"))
        #expect(enc(.character("."), .alt) == esc("."))
        #expect(enc(.character("你"), .alt) == [0x1B, 0xE4, 0xBD, 0xA0])
        #expect(enc(.space, .alt) == [0x1B, 0x20])
    }

    @Test func altCombinedWithCtrl() {
        #expect(enc(.character("c"), [.alt, .ctrl]) == [0x1B, 0x03])
    }

    @Test func altDisabledSendsPlainCharacter() {
        #expect(enc(.character("b"), .alt, altEsc: false) == [0x62])
        #expect(enc(.character("c"), [.alt, .ctrl], altEsc: false) == [0x03])
        // Modifier parameters on CSI sequences are unaffected by the Meta setting.
        #expect(enc(.arrow(.left), .alt, altEsc: false) == esc("[1;3D"))
    }

    @Test func commandChordsAreNotEncoded() {
        #expect(enc(.character("c"), .meta) == nil)
        #expect(enc(.arrow(.up), .meta) == nil)
        #expect(enc(.enter, .meta) == nil)
    }
}

@Suite("KeyEncoder: editing keys")
struct KeyEncoderEditingTests {
    @Test func enterTabBackspaceEscape() {
        #expect(enc(.enter) == [0x0D])
        #expect(enc(.enter, .alt) == [0x1B, 0x0D])
        #expect(enc(.enter, .shift) == [0x0D])
        #expect(enc(.tab) == [0x09])
        #expect(enc(.tab, .shift) == esc("[Z"))
        #expect(enc(.tab, .alt) == [0x1B, 0x09])
        #expect(enc(.backspace) == [0x7F])
        #expect(enc(.backspace, .ctrl) == [0x08])
        #expect(enc(.backspace, .alt) == [0x1B, 0x7F])
        #expect(enc(.escape) == [0x1B])
        #expect(enc(.escape, .alt) == [0x1B, 0x1B])
    }

    @Test func navigationKeys() {
        #expect(enc(.insert) == esc("[2~"))
        #expect(enc(.delete) == esc("[3~"))
        #expect(enc(.pageUp) == esc("[5~"))
        #expect(enc(.pageDown) == esc("[6~"))
        #expect(enc(.home) == esc("[H"))
        #expect(enc(.end) == esc("[F"))
    }

    @Test func navigationKeysWithModifiers() {
        #expect(enc(.delete, .shift) == esc("[3;2~"))
        #expect(enc(.pageUp, .ctrl) == esc("[5;5~"))
        #expect(enc(.pageDown, [.shift, .ctrl]) == esc("[6;6~"))
        #expect(enc(.home, .shift) == esc("[1;2H"))
        #expect(enc(.end, .alt) == esc("[1;3F"))
        #expect(enc(.home, [.ctrl, .alt, .shift]) == esc("[1;8H"))
    }

    @Test func homeEndInApplicationMode() {
        #expect(enc(.home, app: true) == esc("OH"))
        #expect(enc(.end, app: true) == esc("OF"))
        #expect(enc(.home, .shift, app: true) == esc("[1;2H"))
    }
}

@Suite("KeyEncoder: arrows")
struct KeyEncoderArrowTests {
    @Test func normalMode() {
        #expect(enc(.arrow(.up)) == esc("[A"))
        #expect(enc(.arrow(.down)) == esc("[B"))
        #expect(enc(.arrow(.right)) == esc("[C"))
        #expect(enc(.arrow(.left)) == esc("[D"))
    }

    @Test func applicationCursorMode() {
        #expect(enc(.arrow(.up), app: true) == esc("OA"))
        #expect(enc(.arrow(.down), app: true) == esc("OB"))
        #expect(enc(.arrow(.right), app: true) == esc("OC"))
        #expect(enc(.arrow(.left), app: true) == esc("OD"))
    }

    @Test(arguments: [
        (KeyModifiers.shift, "2"), (.alt, "3"), ([.shift, .alt], "4"), (.ctrl, "5"),
        ([.shift, .ctrl], "6"), ([.alt, .ctrl], "7"), ([.shift, .alt, .ctrl], "8"),
    ])
    func modifierParameter(_ mods: KeyModifiers, _ param: String) {
        #expect(enc(.arrow(.up), mods) == esc("[1;\(param)A"))
        #expect(enc(.arrow(.left), mods, app: true) == esc("[1;\(param)D"))
        #expect(enc(.arrow(.right), mods) == esc("[1;\(param)C"))
        #expect(enc(.arrow(.down), mods) == esc("[1;\(param)B"))
    }
}

@Suite("KeyEncoder: function keys")
struct KeyEncoderFunctionTests {
    @Test func f1ToF4UseSS3() {
        #expect(enc(.function(1)) == esc("OP"))
        #expect(enc(.function(2)) == esc("OQ"))
        #expect(enc(.function(3)) == esc("OR"))
        #expect(enc(.function(4)) == esc("OS"))
    }

    @Test func f5ToF12UseTilde() {
        let codes = [5: 15, 6: 17, 7: 18, 8: 19, 9: 20, 10: 21, 11: 23, 12: 24]
        for (n, code) in codes {
            #expect(enc(.function(n)) == esc("[\(code)~"), "F\(n)")
        }
    }

    @Test func f13ToF20() {
        let codes = [13: 25, 14: 26, 15: 28, 16: 29, 17: 31, 18: 32, 19: 33, 20: 34]
        for (n, code) in codes {
            #expect(enc(.function(n)) == esc("[\(code)~"), "F\(n)")
        }
    }

    @Test func modifiedFunctionKeys() {
        #expect(enc(.function(1), .shift) == esc("[1;2P"))
        #expect(enc(.function(4), .ctrl) == esc("[1;5S"))
        #expect(enc(.function(5), .alt) == esc("[15;3~"))
        #expect(enc(.function(12), [.shift, .ctrl]) == esc("[24;6~"))
    }

    @Test func outOfRangeFunctionKeysAreNil() {
        #expect(enc(.function(0)) == nil)
        #expect(enc(.function(21)) == nil)
    }
}

@Suite("KeyModifiers")
struct KeyModifiersTests {
    @Test func xtermParameter() {
        #expect(KeyModifiers([]).xtermParameter == 1)
        #expect(KeyModifiers.shift.xtermParameter == 2)
        #expect(KeyModifiers.alt.xtermParameter == 3)
        #expect(KeyModifiers.ctrl.xtermParameter == 5)
        #expect(KeyModifiers([.shift, .alt, .ctrl]).xtermParameter == 8)
    }
}
