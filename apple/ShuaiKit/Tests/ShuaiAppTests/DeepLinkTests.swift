import Foundation
import Testing
@testable import ShuaiApp

private let id = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
private let idText = "11111111-2222-3333-4444-555555555555"

private func parse(_ s: String) -> Result<DeepLink, DeepLinkError> {
    guard let url = URL(string: s) else { return .failure(.malformed) }
    return DeepLink.parse(url)
}

@Suite("DeepLink.parse")
struct DeepLinkParseTests {
    @Test func hostAndEncodedPane() {
        #expect(parse("shuai://open?host=\(idText)&pane=%2512") == .success(DeepLink(hostID: id, pane: "%12")))
    }

    @Test func exactlyWhatTheAgentSends() {
        #expect(parse("shuai://open?host=\(idText)&pane=%255") == .success(DeepLink(hostID: id, pane: "%5")))
    }

    @Test func paneIsOptional() {
        #expect(parse("shuai://open?host=\(idText)") == .success(DeepLink(hostID: id, pane: nil)))
    }

    @Test func uppercaseUUIDAndSchemeAreAccepted() {
        #expect(parse("SHUAI://open?host=\(idText.uppercased())&pane=%250") == .success(DeepLink(hostID: id, pane: "%0")))
    }

    @Test func extraParametersAreIgnored() {
        #expect(parse("shuai://open?x=1&host=\(idText)&pane=%253&cmd=rm%20-rf") == .success(DeepLink(hostID: id, pane: "%3")))
    }

    @Test(arguments: [
        "shuai://open",
        "shuai://open?pane=%251",
        "shuai://open?host=",
        "shuai://open?host=not-a-uuid&pane=%251",
        "shuai://open?host=1111",
        "shuai://open?host=\(idText)&host=\(idText)",
        "shuai://open?host=\(idText)&pane=%251&pane=%252",
        "shuai://open?host=\(idText)&pane=",
        "shuai://open?host=\(idText)&pane=5",
        "shuai://open?host=\(idText)&pane=%25",
        "shuai://open?host=\(idText)&pane=%25a",
        "shuai://open?host=\(idText)&pane=%251a",
        "shuai://open?host=\(idText)&pane=%25-1",
        "shuai://open?host=\(idText)&pane=%251%3B%20rm",
        "shuai://open?host=\(idText)&pane=%2599999999999999999999",
        "shuai://open/extra?host=\(idText)",
        "shuai://evil?host=\(idText)",
        "shuai://host/\(idText)/pane/%255",
        "http://open?host=\(idText)",
        "ntfy://open?host=\(idText)",
    ])
    func rejectsHostileInput(_ s: String) {
        if case .success(let l) = parse(s) { Issue.record("accepted \(s) as \(l)") }
    }

    @Test func buildsURLsThatRoundTrip() {
        let url = DeepLink(hostID: id, pane: "%7").url
        #expect(url.absoluteString == "shuai://open?host=\(idText)&pane=%257")
        #expect(DeepLink.parse(url) == .success(DeepLink(hostID: id, pane: "%7")))
    }
}

@MainActor
private final class FakeNavigator: PaneNavigating {
    var hosts: Set<UUID> = [id]
    var result: PaneNavigationResult = .opened
    var calls: [(UUID, String?)] = []
    func hostExists(_ id: UUID) -> Bool { hosts.contains(id) }
    func navigate(hostID: UUID, pane: String?) async -> PaneNavigationResult {
        calls.append((hostID, pane))
        return result
    }
}

@Suite("DeepLinkRouter")
@MainActor
struct DeepLinkRouterTests {
    @Test func opensTheHostAndPane() async {
        let nav = FakeNavigator()
        let outcome = await DeepLinkRouter(navigator: nav).handle(URL(string: "shuai://open?host=\(idText)&pane=%252")!)
        #expect(outcome == .opened)
        #expect(nav.calls.count == 1)
        #expect(nav.calls[0].0 == id)
        #expect(nav.calls[0].1 == "%2")
    }

    @Test func unknownHostGivesAFriendlyNoticeAndNeverNavigates() async {
        let nav = FakeNavigator()
        nav.hosts = []
        let outcome = await DeepLinkRouter(navigator: nav).handle(URL(string: "shuai://open?host=\(idText)&pane=%252")!)
        guard case .notice(let m) = outcome else { Issue.record("expected a notice"); return }
        #expect(m.contains("host"))
        #expect(nav.calls.isEmpty)
    }

    @Test func malformedLinksGiveANoticeAndNeverNavigate() async {
        let nav = FakeNavigator()
        for s in ["shuai://open", "shuai://open?host=zzz&pane=%251", "shuai://open?host=\(idText)&pane=%25x"] {
            guard case .notice = await DeepLinkRouter(navigator: nav).handle(URL(string: s)!) else {
                Issue.record("expected a notice for \(s)")
                return
            }
        }
        #expect(nav.calls.isEmpty)
    }

    @Test func otherSchemesAreIgnored() async {
        let nav = FakeNavigator()
        #expect(await DeepLinkRouter(navigator: nav).handle(URL(string: "https://example.com")!) == .ignored)
        #expect(nav.calls.isEmpty)
    }

    @Test func missingPaneGivesAFriendlyNotice() async {
        let nav = FakeNavigator()
        nav.result = .paneNotFound
        guard case .notice(let m) = await DeepLinkRouter(navigator: nav).handle(DeepLink(hostID: id, pane: "%9")) else {
            Issue.record("expected a notice")
                return
        }
        #expect(m.contains("pane"))
    }

    @Test func connectionFailureGivesANotice() async {
        let nav = FakeNavigator()
        nav.result = .connectionFailed
        guard case .notice = await DeepLinkRouter(navigator: nav).handle(DeepLink(hostID: id, pane: nil)) else {
            Issue.record("expected a notice")
                return
        }
    }

    @Test func localNotificationTapsUseTheSamePath() async {
        let nav = FakeNavigator()
        let outcome = await DeepLinkRouter(navigator: nav).handle(DeepLink(hostID: id, pane: "%4"))
        #expect(outcome == .opened)
        #expect(nav.calls[0].1 == "%4")
    }
}
