import Testing
@testable import ShuaiApp

@Suite("TmuxMenuState")
struct TmuxMenuStateTests {
    private func items(_ availability: TmuxMenuAvailability = .available) -> [TmuxMenuItem] {
        TmuxMenuState.items(shortcuts: .defaults, availability: availability)
    }

    @Test func itemsDisabledWithoutLiveTmux() {
        let all = items(.unavailable)
        #expect(!all.isEmpty)
        #expect(all.allSatisfy { !$0.enabled })
    }

    @Test func itemsEnabledWhenLiveOrPolling() {
        #expect(items().allSatisfy(\.enabled))
        #expect(TmuxMenuAvailability(.live) == .available)
        #expect(TmuxMenuAvailability(.polling) == .available)
        for state: TmuxMonitor.State in [.idle, .starting, .unavailable("x"), .ended(nil), .stopped] {
            #expect(TmuxMenuAvailability(state) == .unavailable)
        }
    }

    @Test func chordsMatchShortcutMapDefaults() {
        for item in items() {
            let action = ShortcutAction(id: item.id)
            #expect(action != nil, "\(item.id) has no ShortcutAction")
            if let action { #expect(item.chord == ShortcutMap.defaults.chord(for: action)) }
        }
    }

    @Test func unboundActionsHaveNoChord() {
        let map = ShortcutMap.defaults.removing(.newWindow)
        let item = TmuxMenuState.items(shortcuts: map, availability: .available).first { $0.id == "newWindow" }
        #expect(item != nil)
        #expect(item?.chord == nil)
    }

    @Test func noDuplicateChords() {
        let chords = items().compactMap(\.chord)
        #expect(Set(chords).count == chords.count)
    }

    @Test func windowItemsCoverPositions1To9() {
        let ids = Set(items().map(\.id))
        for n in 1 ... 9 { #expect(ids.contains(ShortcutAction.selectWindow(position: n).id)) }
    }

    @Test func titlesAreUniqueAndWorded() {
        let titles = items().map(\.title)
        #expect(Set(titles).count == titles.count)
        #expect(titles.allSatisfy { $0.contains(where: \.isLetter) })
        for want in ["New Window", "Close Window", "Previous Window", "Next Window", "Split Right", "Split Down", "Zoom Pane"] {
            #expect(titles.contains(want))
        }
    }

    @Test func itemIdsAreUnique() {
        let ids = items().map(\.id)
        #expect(Set(ids).count == ids.count)
    }
}
