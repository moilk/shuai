import Testing
@testable import ShuaiTerminal

/// Hardware keyboard: UIKit reports Option+b as characters "∫" (composed) with charactersIgnoringModifiers
/// "b". libghostty's `macos-option-as-alt` is not something we can rely on for the iOS embedding, so
/// TerminalView maps the chord itself using these rules.
@Suite("OptionAsAlt")
struct OptionAsAltTests {
    @Test func optionLetterBecomesAltLetter() {
        #expect(OptionAsAlt.stroke(base: "b", shift: false, control: false, command: false, option: true)
            == KeyStroke(.character("b"), .alt))
        #expect(OptionAsAlt.stroke(base: "f", shift: false, control: false, command: false, option: true)
            == KeyStroke(.character("f"), .alt))
    }

    @Test func shiftIsKeptInTheCharacter() {
        // charactersIgnoringModifiers keeps Shift: Option+Shift+b -> "B".
        #expect(OptionAsAlt.stroke(base: "B", shift: true, control: false, command: false, option: true)
            == KeyStroke(.character("B"), .alt))
    }

    @Test func digitsAndPunctuation() {
        #expect(OptionAsAlt.stroke(base: ".", shift: false, control: false, command: false, option: true)
            == KeyStroke(.character("."), .alt))
        #expect(OptionAsAlt.stroke(base: "1", shift: false, control: false, command: false, option: true)
            == KeyStroke(.character("1"), .alt))
    }

    @Test func notHandledWithoutOption() {
        #expect(OptionAsAlt.stroke(base: "b", shift: false, control: false, command: false, option: false) == nil)
    }

    @Test func controlAndCommandChordsAreLeftToGhostty() {
        #expect(OptionAsAlt.stroke(base: "b", shift: false, control: true, command: false, option: true) == nil)
        #expect(OptionAsAlt.stroke(base: "b", shift: false, control: false, command: true, option: true) == nil)
    }

    @Test func functionAndNavigationKeysAreLeftToGhostty() {
        // Arrows/Home/F-keys arrive as private-use scalars (U+F700...); Ghostty encodes Alt+Arrow itself.
        #expect(OptionAsAlt.stroke(base: "\u{F700}", shift: false, control: false, command: false, option: true) == nil)
        #expect(OptionAsAlt.stroke(base: "\u{F704}", shift: false, control: false, command: false, option: true) == nil)
        #expect(OptionAsAlt.stroke(base: "", shift: false, control: false, command: false, option: true) == nil)
        #expect(OptionAsAlt.stroke(base: "\u{1B}", shift: false, control: false, command: false, option: true) == nil)
        #expect(OptionAsAlt.stroke(base: "\u{7F}", shift: false, control: false, command: false, option: true) == nil)
    }

    @Test func multiCharacterStringsAreRejected() {
        #expect(OptionAsAlt.stroke(base: "ab", shift: false, control: false, command: false, option: true) == nil)
    }

    @Test func encodesAsEscapePrefix() {
        let s = OptionAsAlt.stroke(base: "b", shift: false, control: false, command: false, option: true)!
        #expect(KeyEncoder.encode(s) == Data([0x1B, 0x62]))
    }
}
