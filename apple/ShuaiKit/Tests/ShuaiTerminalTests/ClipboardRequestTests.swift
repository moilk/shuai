import Foundation
import Testing
@testable import ShuaiTerminal

@MainActor
@Suite("ClipboardRequest")
struct ClipboardRequestTests {
    @Test func respondsExactlyOnce() {
        var answers: [Bool] = []
        let r = ClipboardRequest(contents: "x", kind: .osc52Write) { answers.append($0) }
        r.respond(allow: true)
        r.respond(allow: false)
        #expect(answers == [true])
    }

    @Test func droppedRequestIsDenied() {
        var answers: [Bool] = []
        do {
            _ = ClipboardRequest(contents: "x", kind: .osc52Write) { answers.append($0) }
        }
        #expect(answers == [false])
    }

    @Test func notificationEquality() {
        #expect(TerminalNotification(title: "a", body: "b") == TerminalNotification(title: "a", body: "b"))
    }
}

@Suite("AccessoryBarModel sync")
struct AccessoryBarSyncTests {
    @Test func syncAdoptsExternalState() {
        var m = AccessoryBarModel()
        m.sync(ctrl: .locked, alt: .oneShot)
        #expect(m.ctrl == .locked)
        #expect(m.alt == .oneShot)
        m.sync(ctrl: .off, alt: .off)
        #expect(!m.hasActiveModifiers)
    }
}
