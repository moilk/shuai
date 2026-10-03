import Foundation
import Testing
@testable import ShuaiApp

@Suite struct ShortcutMapTests {
    let map = ShortcutMap.defaults

    @Test func commandDigitsSelectWindowsByPosition() {
        for n in 1 ... 9 {
            let chord = KeyChord(.character(String(n)), [.command])
            #expect(map.action(for: chord) == .selectWindow(position: n))
            #expect(map.chord(for: .selectWindow(position: n)) == chord)
        }
        #expect(map.action(for: KeyChord(.character("0"), [.command])) == nil)
    }

    @Test func defaultBindingsFollowTheSpec() {
        let expected: [(ShortcutAction, KeyChord)] = [
            (.newWindow, KeyChord(.character("t"), [.command])),
            (.killWindow, KeyChord(.character("w"), [.command, .shift])),
            (.previousWindow, KeyChord(.character("["), [.command, .shift])),
            (.nextWindow, KeyChord(.character("]"), [.command, .shift])),
            (.splitRight, KeyChord(.character("d"), [.command])),
            (.splitDown, KeyChord(.character("d"), [.command, .shift])),
            (.selectPane(.left), KeyChord(.leftArrow, [.command, .option])),
            (.selectPane(.right), KeyChord(.rightArrow, [.command, .option])),
            (.selectPane(.up), KeyChord(.upArrow, [.command, .option])),
            (.selectPane(.down), KeyChord(.downArrow, [.command, .option])),
            (.zoomPane, KeyChord(.returnKey, [.command, .shift])),
            (.quickSwitcher, KeyChord(.character("k"), [.command])),
            (.nextAttention, KeyChord(.character("a"), [.command, .shift])),
        ]
        for (action, chord) in expected {
            #expect(map.chord(for: action) == chord, "\(action)")
            #expect(map.action(for: chord) == action, "\(action)")
        }
    }

    @Test func defaultChordsAreUnique() {
        let chords = map.bindings.map(\.chord)
        #expect(Set(chords).count == chords.count)
        let actions = map.bindings.map(\.action)
        #expect(Set(actions).count == actions.count)
    }

    @Test func noDefaultStealsTheTerminalsOwnShortcuts() {
        // Ghostty owns Cmd+/Cmd-/Cmd0 (font size) and Cmd+C/V (clipboard).
        for key in ["+", "=", "-", "0", "c", "v"] {
            #expect(map.action(for: KeyChord(.character(key), [.command])) == nil)
        }
    }

    @Test func overridingRebindsAndFreesTheOldChord() {
        let new = KeyChord(.character("n"), [.command, .option])
        let m = map.overriding(.newWindow, with: new)
        #expect(m.chord(for: .newWindow) == new)
        #expect(m.action(for: new) == .newWindow)
        #expect(m.action(for: KeyChord(.character("t"), [.command])) == nil)
    }

    @Test func overridingWithAChordInUseUnbindsTheOtherAction() {
        let m = map.overriding(.newWindow, with: KeyChord(.character("k"), [.command]))
        #expect(m.action(for: KeyChord(.character("k"), [.command])) == .newWindow)
        #expect(m.chord(for: .quickSwitcher) == nil)
    }

    @Test func removingABindingDisablesIt() {
        let m = map.removing(.zoomPane)
        #expect(m.chord(for: .zoomPane) == nil)
        #expect(m.action(for: KeyChord(.returnKey, [.command, .shift])) == nil)
    }

    @Test func chordTextRoundTrips() {
        for (_, chord) in map.bindings {
            #expect(KeyChord(text: chord.text) == chord, "\(chord.text)")
        }
        #expect(KeyChord(text: "cmd+shift+[")?.modifiers == [.command, .shift])
        #expect(KeyChord(text: "nonsense+") == nil)
        #expect(KeyChord(text: "") == nil)
    }

    @Test func actionIdsRoundTrip() {
        for (action, _) in map.bindings {
            #expect(ShortcutAction(id: action.id) == action)
        }
        #expect(ShortcutAction(id: "selectWindow.12") == nil)
        #expect(ShortcutAction(id: "bogus") == nil)
    }

    @Test func mapSurvivesJSONSoItCanBecomeUserConfigurable() throws {
        let m = map.overriding(.newWindow, with: KeyChord(.character("n"), [.command, .option]))
        let data = try JSONEncoder().encode(m)
        let back = try JSONDecoder().decode(ShortcutMap.self, from: data)
        #expect(back == m)
    }

    @Test func everyActionHasATitle() {
        for (action, _) in map.bindings { #expect(!action.title.isEmpty) }
    }
}
