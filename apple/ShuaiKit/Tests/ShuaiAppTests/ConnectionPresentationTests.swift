import Foundation
import Testing
@testable import ShuaiPlatform
@testable import ShuaiApp

private func make(_ s: SessionState) -> ConnectionPresentation {
    ConnectionPresentation.make(s, hostName: "alpha", target: "user@alpha:22")
}

private let allStates: [SessionState] = [
    .idle, .connecting, .authenticating, .connected,
    .reconnecting(attempt: 1, nextRetryAt: nil),
    .failed(SessionError(kind: .network, message: "x")),
    .disconnected(exitStatus: nil),
]

@Suite("ConnectionPresentation")
struct ConnectionPresentationTests {
    @Test func idleAndConnectedShowNothing() {
        for s in [SessionState.idle, .connected] {
            let p = make(s)
            #expect(p.placement == .none)
            #expect(p.actions.isEmpty)
            #expect(!p.dimsTerminal)
            #expect(!p.showsProgress)
        }
    }

    @Test func connectingIsCardWithProgressAndCancel() {
        let p = make(.connecting)
        #expect(p.placement == .card)
        #expect(p.showsProgress)
        #expect(!p.dimsTerminal)
        #expect(p.title == "Connecting to alpha…")
        #expect(p.detail == "user@alpha:22")
        #expect(p.actions == [.cancelConnect])
        #expect(p.accessibilityIdentifier == "connecting-card")
    }

    @Test func authenticatingSaysSigningIn() {
        let p = make(.authenticating)
        #expect(p.placement == .card)
        #expect(p.title == "Signing in to alpha…")
        #expect(p.actions == [.cancelConnect])
        #expect(p.accessibilityIdentifier == "connecting-card")
    }

    @Test func hostKeyPromptIsCard() {
        let challenge = HostKeyChallenge(
            host: "alpha", port: 22, publicKeyLine: "ssh-ed25519 AAAA", fingerprint: "SHA256:abc", kind: .unknown)
        let p = make(.hostKeyPrompt(challenge))
        #expect(p.placement == .card)
        #expect(p.title == "Verify alpha's host key")
        #expect(p.actions.isEmpty)
        #expect(p.accessibilityIdentifier == "connecting-card")
    }

    @Test func reconnectingIsNonBlockingStrip() {
        let p = make(.reconnecting(attempt: 2, nextRetryAt: Date(timeIntervalSince1970: 100)))
        #expect(p.placement == .strip)
        #expect(!p.dimsTerminal)
        #expect(p.showsProgress)
        #expect(p.title == "Reconnecting to alpha")
        #expect(p.tone == .warning)
        #expect(p.actions == [.retryNow, .cancelReconnect])
        #expect(p.accessibilityIdentifier == "reconnect-overlay")
        #expect(p.attempt == 2)
        #expect(p.retryAt == Date(timeIntervalSince1970: 100))
    }

    @Test func reconnectingDetailShowsAttemptCountdownAndTypingPaused() {
        let p = make(.reconnecting(attempt: 3, nextRetryAt: Date(timeIntervalSince1970: 100)))
        #expect(p.detail(at: Date(timeIntervalSince1970: 93.5)) == "Attempt 3 · retrying in 7s · typing paused")
    }

    @Test func reconnectingWithoutRetryAtOmitsCountdown() {
        let p = make(.reconnecting(attempt: 1, nextRetryAt: nil))
        #expect(p.detail(at: Date()) == "Attempt 1 · typing paused")
    }

    @Test func countdownRoundsUpAndClampsAtZero() {
        let now = Date(timeIntervalSince1970: 1000)
        #expect(ConnectionPresentation.countdownSeconds(until: now.addingTimeInterval(2.1), now: now) == 3)
        #expect(ConnectionPresentation.countdownSeconds(until: now.addingTimeInterval(2), now: now) == 2)
        #expect(ConnectionPresentation.countdownSeconds(until: now, now: now) == 0)
        #expect(ConnectionPresentation.countdownSeconds(until: now.addingTimeInterval(-5), now: now) == 0)
    }

    @Test func failedAuthOffersEditHost() {
        let p = make(.failed(SessionError(kind: .authFailed, message: "nope")))
        #expect(p.placement == .card)
        #expect(p.dimsTerminal)
        #expect(p.tone == .error)
        #expect(p.title == "Can't connect to alpha")
        #expect(p.detail == "nope")
        #expect(p.actions == [.retry, .editHost])
        #expect(p.accessibilityIdentifier == "connection-error")
    }

    @Test func failedKeyMissingOffersOpenKeys() {
        let p = make(.failed(SessionError(kind: .keyMissing, message: "no key")))
        #expect(p.actions == [.retry, .openKeys])
    }

    @Test func failedNetworkOffersRetryOnly() {
        for k in [SessionError.Kind.network, .timeout, .hostKeyRejected, .other] {
            #expect(make(.failed(SessionError(kind: k, message: "m"))).actions == [.retry])
        }
    }

    @Test func failedMessageSanitizedAndCapped() {
        let dirty = "bad\u{1B}[31m\u{202E}thing\u{2066}\n\n  here\t\u{85}ok  "
        let p = make(.failed(SessionError(kind: .other, message: dirty)))
        #expect(p.detail == "bad[31mthing here ok")
        let long = String(repeating: "a", count: 1000)
        let q = make(.failed(SessionError(kind: .other, message: long)))
        #expect(q.detail == String(repeating: "a", count: 299) + "…")
        let exact = String(repeating: "b", count: 300)
        #expect(make(.failed(SessionError(kind: .other, message: exact))).detail == exact)
    }

    @Test func failedMessageDropsZeroWidthAndBidiAndStaysWithinLimit() {
        let split = "pass\u{200B}word\u{202E} re\u{2066}jected"
        let p = make(.failed(SessionError(kind: .other, message: split)))
        #expect(p.detail == "password rejected")
        let long = String(repeating: "x\u{200B}", count: 1000)
        let q = make(.failed(SessionError(kind: .other, message: long)))
        #expect(q.detail?.count == 300)
        #expect(q.detail?.hasSuffix("…") == true)
        #expect(q.detail?.unicodeScalars.contains { $0.value == 0x200B } == false)
    }

    @Test func disconnectedWithExitStatusIsStrip() {
        let p = make(.disconnected(exitStatus: 3))
        #expect(p.placement == .strip)
        #expect(!p.dimsTerminal)
        #expect(!p.showsProgress)
        #expect(p.title == "Disconnected")
        #expect(p.detail == "Session ended (exit status 3)")
        #expect(p.actions == [.reconnect])
        #expect(p.accessibilityIdentifier == "disconnected-card")
    }

    @Test func disconnectedWithoutStatusSaysDisconnected() {
        let p = make(.disconnected(exitStatus: nil))
        #expect(p.title == "Disconnected")
        #expect(p.detail == nil)
    }

    @Test func everyStatusHasDistinctSymbolAndLabel() {
        let all: [SessionState.Status] = [.off, .busy, .connected, .warning, .error]
        #expect(Set(all.map(\.symbol)).count == all.count)
        #expect(Set(all.map(\.label)).count == all.count)
        #expect(SessionState.Status.off.symbol == "circle.dashed")
        #expect(SessionState.Status.busy.symbol == "circle.dotted")
        #expect(SessionState.Status.connected.symbol == "checkmark.circle.fill")
        #expect(SessionState.Status.warning.symbol == "arrow.triangle.2.circlepath")
        #expect(SessionState.Status.error.symbol == "xmark.octagon.fill")
        #expect(SessionState.Status.off.label == "Not connected")
        #expect(SessionState.Status.busy.label == "Connecting")
        #expect(SessionState.Status.connected.label == "Connected")
        #expect(SessionState.Status.warning.label == "Reconnecting")
        #expect(SessionState.Status.error.label == "Connection failed")
    }

    @Test func accessibilityLabelNamesHostAndState() {
        for s in allStates {
            let p = make(s)
            #expect(p.accessibilityLabel == "alpha: \(s.status.label)")
            #expect(p.tone == s.status)
            #expect(p.symbol == s.status.symbol)
        }
    }

    @Test func identifiersMatchLegacyIds() {
        typealias A = ConnectionPresentation.Action
        #expect(A.retryNow.accessibilityIdentifier == "retry-now")
        #expect(A.cancelReconnect.accessibilityIdentifier == "cancel-reconnect")
        #expect(A.cancelConnect.accessibilityIdentifier == "cancel-connect")
        #expect(A.retry.accessibilityIdentifier == "retry-connect")
        #expect(A.reconnect.accessibilityIdentifier == "reconnect-session")
        #expect(A.editHost.accessibilityIdentifier == "edit-host")
        #expect(A.openKeys.accessibilityIdentifier == "open-keys")
        #expect(A.retryNow.title == "Retry now")
        #expect(A.cancelReconnect.title == "Cancel")
        #expect(A.cancelConnect.title == "Cancel")
        #expect(A.retry.title == "Retry")
        #expect(A.reconnect.title == "Reconnect")
        #expect(A.editHost.title == "Edit host")
        #expect(A.openKeys.title == "Open keys")
    }
}
