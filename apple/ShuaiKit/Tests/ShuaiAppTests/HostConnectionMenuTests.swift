import Foundation
import Testing

@testable import ShuaiPlatform
@testable import ShuaiApp

@Suite struct HostConnectionMenuTests {
    private let hostKey = HostKeyChallenge(
        host: "h", port: 22, publicKeyLine: "ssh-ed25519 AAAA", fingerprint: "SHA256:x", kind: .unknown)

    @Test func hostsWithoutALiveSessionOfferConnect() {
        #expect(HostConnectionMenu.item(for: nil) == .connect)
        #expect(HostConnectionMenu.item(for: .idle) == .connect)
        #expect(HostConnectionMenu.item(for: .disconnected(exitStatus: 0)) == .connect)
        #expect(HostConnectionMenu.item(for: .failed(SessionError(kind: .network, message: "x"))) == .connect)
    }

    @Test func hostsWithASessionInPlayOfferDisconnect() {
        #expect(HostConnectionMenu.item(for: .connected) == .disconnect)
        #expect(HostConnectionMenu.item(for: .connecting) == .disconnect)
        #expect(HostConnectionMenu.item(for: .authenticating) == .disconnect)
        #expect(HostConnectionMenu.item(for: .hostKeyPrompt(hostKey)) == .disconnect)
        #expect(HostConnectionMenu.item(for: .reconnecting(attempt: 1, nextRetryAt: nil)) == .disconnect)
    }

    @Test func itemsHaveTitlesAndSymbols() {
        #expect(HostConnectionMenu.Item.connect.title == "Connect")
        #expect(HostConnectionMenu.Item.disconnect.title == "Disconnect")
        #expect(HostConnectionMenu.Item.connect.symbol != HostConnectionMenu.Item.disconnect.symbol)
    }
}
