import Foundation
import Testing
@testable import ShuaiApp

@Suite("ModalRouter")
struct ModalRouterTests {
    private let host = UUID()

    @Test func presentsWhenNothingIsOpen() {
        var r = ModalRouter()
        #expect(r.request(.settings) == .presented)
        #expect(r.current == .settings)
    }

    @Test func sameRouteIsANoOp() {
        var r = ModalRouter()
        _ = r.request(.keys)
        #expect(r.request(.keys) == .ignored)
        #expect(r.current == .keys)
    }

    @Test func quickSwitcherIsReplaced() {
        var r = ModalRouter()
        _ = r.request(.quickSwitcher)
        #expect(r.request(.editHost(host)) == .replaced)
        #expect(r.current == .editHost(host))
    }

    @Test func otherModalsDoNotStack() {
        var r = ModalRouter()
        _ = r.request(.settings)
        #expect(r.request(.keys) == .ignored)
        #expect(r.request(.newHost) == .ignored)
        #expect(r.request(.quickSwitcher) == .ignored)
        #expect(r.current == .settings)
    }

    @Test func dirtyEditorIsNeverReplaced() {
        var r = ModalRouter()
        _ = r.request(.newHost)
        #expect(r.request(.quickSwitcher, currentIsDirty: true) == .ignored)
        #expect(r.current == .newHost)
    }

    @Test func staleDismissKeepsTheNewRoute() {
        var r = ModalRouter()
        _ = r.request(.quickSwitcher)
        _ = r.request(.newHost)
        r.dismiss(.quickSwitcher)
        #expect(r.current == .newHost)
    }

    @Test func dismissClearsCurrent() {
        var r = ModalRouter()
        _ = r.request(.agentInstall(host))
        r.dismiss(.agentInstall(host))
        #expect(r.current == nil)
        #expect(r.request(.keys) == .presented)
    }
}

@Suite("ModalRouter menu availability")
struct ModalRouterAvailabilityTests {
    @Test func canPresentWhenNothingOpenOrQuickSwitcher() {
        var r = ModalRouter()
        #expect(r.canPresent(.settings))
        _ = r.request(.quickSwitcher)
        #expect(r.canPresent(.keys))
        #expect(!r.canPresent(.quickSwitcher))
        #expect(!r.canPresent(.keys, currentIsDirty: true))
    }

    @Test func cannotPresentOverNonReplaceableModal() {
        var r = ModalRouter()
        _ = r.request(.settings)
        #expect(!r.canPresent(.newHost))
        #expect(!r.canPresent(.keys))
    }

    @Test func canPresentMatchesRequest() {
        for open: ModalRoute? in [nil, .settings, .quickSwitcher, .keys] {
            var a = ModalRouter()
            if let open { _ = a.request(open) }
            let predicted = a.canPresent(.newHost)
            #expect(predicted == (a.request(.newHost) != .ignored))
        }
    }
}
