import Foundation
import Testing
@testable import ShuaiApp

@Suite("NtfyTopic")
struct NtfyTopicTests {
    @Test func zeroBytesEncodeToAs() {
        #expect(NtfyTopic.generate(randomBytes: { n in [UInt8](repeating: 0, count: n) }) == "shuai-" + String(repeating: "a", count: 26))
    }

    @Test func allOnesBytesEncodeToTopOfTheAlphabet() {
        let t = NtfyTopic.generate(randomBytes: { n in [UInt8](repeating: 0xFF, count: n) })
        #expect(t == "shuai-" + String(repeating: "7", count: 25) + "4")
    }

    @Test func asksForExactly128Bits() {
        var asked = 0
        _ = NtfyTopic.generate(randomBytes: { n in asked = n; return [UInt8](repeating: 1, count: n) })
        #expect(asked == 16)
    }

    @Test func formatAndEntropyOfTheDefaultGenerator() {
        var seen = Set<String>()
        var chars = Set<Character>()
        for _ in 0 ..< 500 {
            let t = NtfyTopic.generate()
            #expect(t.wholeMatch(of: /shuai-[a-z2-7]{26}/) != nil, "\(t)")
            #expect(NtfyTopic.isValid(t))
            seen.insert(t)
            chars.formUnion(t.dropFirst(6))
        }
        #expect(seen.count == 500)
        // 13,000 random base32 characters hit (almost surely) the whole alphabet
        #expect(chars.count == 32)
    }

    @Test func validity() {
        #expect(NtfyTopic.isValid("my-topic_1"))
        #expect(!NtfyTopic.isValid(""))
        #expect(!NtfyTopic.isValid("a b"))
        #expect(!NtfyTopic.isValid("a/b"))
        #expect(!NtfyTopic.isValid("a?b"))
        #expect(!NtfyTopic.isValid("ü"))
        #expect(!NtfyTopic.isValid(String(repeating: "a", count: 65)))
    }
}

@Suite("NtfyServer")
struct NtfyServerTests {
    @Test func httpsIsAccepted() {
        #expect(NtfyServer.validate("https://ntfy.sh") == .valid(URL(string: "https://ntfy.sh")!))
        #expect(NtfyServer.validate("  https://ntfy.example.com:8443/  ") == .valid(URL(string: "https://ntfy.example.com:8443")!))
    }

    @Test func httpIsAcceptedWithAWarning() {
        #expect(NtfyServer.validate("http://10.0.0.5:8080") == .insecure(URL(string: "http://10.0.0.5:8080")!))
    }

    @Test(arguments: [
        "", "   ", "ntfy.sh", "ftp://ntfy.sh", "https://", "https:///x", "https://user:pw@ntfy.sh", "https://ntfy.sh?x=1",
        "https://ntfy.sh#frag", "https://ntfy sh", "javascript:alert(1)", "shuai://open",
    ])
    func rejects(_ text: String) {
        guard case .invalid = NtfyServer.validate(text) else {
            Issue.record("accepted \(text)")
            return
        }
    }

    @Test(arguments: ["https://tk%40ntfy.example", "https://user%3Apass%40ntfy.example"])
    func percentEncodedUserinfoIsRejected(_ text: String) {
        guard case .invalid = NtfyServer.validate(text) else {
            Issue.record("accepted \(text)")
            return
        }
    }

    @Test(arguments: ["https://user@ntfy.example", "https://user:pw@ntfy.example", "http://:pw@ntfy.example"])
    func plainUserinfoStillRejected(_ text: String) {
        #expect(NtfyServer.validate(text) == .invalid(.hasCredentials))
    }

    @Test(arguments: [
        "https://ntfy.example%2Fx", "https://ntfy.example%3Fx=1", "https://ntfy.example%23frag",
        "https://ntfy%2F.example", "https://ntfy.example%20x", "https://ntfy.example%0Ax", "https://ntfy.example%25",
    ])
    func hostWithEncodedSlashOrQuestionIsRejected(_ text: String) {
        guard case .invalid = NtfyServer.validate(text) else {
            Issue.record("accepted \(text)")
            return
        }
    }

    @Test(arguments: [
        "https://ntfy.sh", "https://ntfy.example:8443/prefix", "http://10.0.0.5:8080", "https://[2001:db8::1]:8443",
        "https://[::1]", "https://ntfy.example/a/b/",
    ])
    func roundTripNeverContainsUserinfo(_ text: String) {
        guard let url = NtfyServer.validate(text).url else {
            Issue.record("rejected \(text)")
            return
        }
        #expect(url.user == nil)
        #expect(url.password == nil)
        #expect(!url.absoluteString.contains("@"))
    }

    @Test func ipv6LiteralAccepted() {
        #expect(NtfyServer.validate("https://[::1]") == .valid(URL(string: "https://[::1]")!))
        #expect(NtfyServer.validate("https://[2001:db8::1]") == .valid(URL(string: "https://[2001:db8::1]")!))
    }

    @Test func ipv6LiteralWithPortAccepted() {
        #expect(NtfyServer.validate("https://[2001:db8::1]:8443") == .valid(URL(string: "https://[2001:db8::1]:8443")!))
        #expect(NtfyServer.validate("http://[::1]:8080/p/") == .insecure(URL(string: "http://[::1]:8080/p")!))
    }

    @Test(arguments: ["https://[::1", "https://::1", "https://[::1]x", "https://[zz::1]", "https://[]", "https://[::1]:99999"])
    func malformedIPv6Rejected(_ text: String) {
        guard case .invalid = NtfyServer.validate(text) else {
            Issue.record("accepted \(text)")
            return
        }
    }

    @Test func existingValidServersUnchanged() {
        #expect(NtfyServer.validate("https://ntfy.sh") == .valid(URL(string: "https://ntfy.sh")!))
        #expect(NtfyServer.validate("https://ntfy.example:8443/prefix") == .valid(URL(string: "https://ntfy.example:8443/prefix")!))
        #expect(NtfyServer.validate("http://10.0.0.5:8080") == .insecure(URL(string: "http://10.0.0.5:8080")!))
    }

    @Test func appLinkUsesHostAndTopic() {
        let https = URL(string: "https://ntfy.sh")!
        #expect(NtfyServer.appLink(server: https, topic: "shuai-abc")?.absoluteString == "ntfy://ntfy.sh/shuai-abc")
        let port = URL(string: "https://ntfy.example.com:8443")!
        #expect(NtfyServer.appLink(server: port, topic: "t")?.absoluteString == "ntfy://ntfy.example.com:8443/t")
        let http = URL(string: "http://10.0.0.5:8080")!
        #expect(NtfyServer.appLink(server: http, topic: "t")?.absoluteString == "ntfy://10.0.0.5:8080/t?secure=false")
        #expect(NtfyServer.appLink(server: https, topic: "bad topic") == nil)
    }
}

@Suite("PushSettings")
@MainActor
struct PushSettingsTests {
    private func make(
        defaults: UserDefaults? = nil, secrets: PushSecretStore = InMemoryPushSecretStore(),
        transport: NtfyTransport = RecordingTransport()
    ) -> PushSettings {
        PushSettings(
            defaults: defaults ?? UserDefaults(suiteName: "push-\(UUID().uuidString)")!, secrets: secrets,
            transport: transport, randomBytes: { n in (0 ..< n).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 3) } })
    }

    @Test func defaultsToPublicNtfyWithAGeneratedPrivateTopicAndIsOff() {
        let s = make()
        #expect(!s.enabled)
        #expect(s.serverText == "https://ntfy.sh")
        #expect(s.topic.hasPrefix("shuai-"))
        #expect(s.topic.count == 32)
        #expect(s.config == nil, "disabled means no ntfy section")
    }

    @Test func settingsAndTopicPersistAcrossInstances() {
        let defaults = UserDefaults(suiteName: "push-\(UUID().uuidString)")!
        let secrets = InMemoryPushSecretStore()
        let a = make(defaults: defaults, secrets: secrets)
        a.enabled = true
        a.serverText = "https://ntfy.example.com"
        a.token = "tk_abc"
        let topic = a.topic
        let b = make(defaults: defaults, secrets: secrets)
        #expect(b.enabled)
        #expect(b.serverText == "https://ntfy.example.com")
        #expect(b.topic == topic)
        #expect(b.token == "tk_abc")
    }

    @Test func topicAndTokenLiveInTheSecretStoreNotInDefaults() {
        let suite = "push-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let secrets = InMemoryPushSecretStore()
        let s = make(defaults: defaults, secrets: secrets)
        s.token = "tk_secret"
        let dump = defaults.persistentDomain(forName: suite).map { "\($0)" } ?? ""
        #expect(!dump.contains("tk_secret"))
        #expect(!dump.contains(s.topic))
        #expect(secrets.get(.token) == "tk_secret")
        #expect(secrets.get(.topic) == s.topic)
        s.token = ""
        #expect(secrets.get(.token) == nil)
    }

    @Test func regenerateChangesTheTopic() {
        let s = make()
        let old = s.topic
        var counter: UInt8 = 0
        s.regenerateTopic(randomBytes: { n in counter &+= 1; return [UInt8](repeating: counter, count: n) })
        #expect(s.topic != old)
        #expect(NtfyTopic.isValid(s.topic))
    }

    @Test func regeneratingTheTopicAndTogglingPushNotifyTheApp() {
        let s = make()
        var calls = 0
        s.onSyncRelevantChange = { calls += 1 }
        s.regenerateTopic()
        #expect(calls == 1)
        s.enabled = true
        s.enabled = false
        #expect(calls == 3)
        s.enabled = false
        #expect(calls == 3, "no change, no sync")
    }

    @Test func windowNamesAreOptInAndPersist() {
        let defaults = UserDefaults(suiteName: "push-\(UUID().uuidString)")!
        let secrets = InMemoryPushSecretStore()
        let s = make(defaults: defaults, secrets: secrets)
        s.enabled = true
        #expect(!s.includeWindowNames)
        #expect(s.config?.includeWindowNames == false)
        s.includeWindowNames = true
        #expect(s.config?.includeWindowNames == true)
        #expect(make(defaults: defaults, secrets: secrets).includeWindowNames)
    }

    @Test func failureMessagesNeverContainTheTopicOrToken() async {
        struct Leaky: Error, LocalizedError {
            let text: String
            var errorDescription: String? { text }
        }
        let bad = RecordingTransport()
        let s = make(transport: bad)
        s.token = "tk_SECRET"
        bad.error = Leaky(text: "could not reach https://ntfy.sh/\(s.topic) with Bearer tk_SECRET")
        guard case .failed(let m) = await s.sendTest() else { Issue.record("expected failure"); return }
        #expect(!m.contains(s.topic) && !m.contains("tk_SECRET"), "\(m)")
    }

    @Test func configIsBuiltOnlyWhenEnabledAndValid() {
        let s = make()
        s.enabled = true
        s.token = "tk"
        #expect(s.config == NtfyConfig(server: "https://ntfy.sh", topic: s.topic, token: "tk"))
        s.serverText = "nope"
        #expect(s.config == nil)
        s.serverText = "http://192.168.1.2:8080/"
        #expect(s.config?.server == "http://192.168.1.2:8080")
        #expect(s.serverWarning != nil)
        s.token = ""
        #expect(s.config?.token == nil)
    }

    @Test func openInNtfyAppLinkAndStoreFallback() {
        let s = make()
        #expect(s.appLink?.absoluteString == "ntfy://ntfy.sh/\(s.topic)")
        #expect(PushSettings.appStoreURL.host == "apps.apple.com")
    }

    @Test func testNotificationPostsStatusOnlyToTheConfiguredServerAndTopic() async {
        let transport = RecordingTransport()
        let s = make(transport: transport)
        s.serverText = "https://ntfy.example.com"
        s.token = "tk_abc"
        let result = await s.sendTest()
        #expect(result == .sent)
        let r = transport.requests.get.first
        #expect(r?.httpMethod == "POST")
        #expect(r?.url?.absoluteString == "https://ntfy.example.com/\(s.topic)")
        #expect(r?.value(forHTTPHeaderField: "Authorization") == "Bearer tk_abc")
        #expect(r?.value(forHTTPHeaderField: "Title") == "Shuai test notification")
        #expect(r.flatMap { $0.httpBody.map { String(decoding: $0, as: UTF8.self) } } == "Push notifications are working.")
    }

    @Test func testNotificationReportsFailuresAndInvalidServers() async {
        let t = RecordingTransport()
        t.status = 403
        let s = make(transport: t)
        #expect(await s.sendTest() == .failed("The server answered HTTP 403."))
        s.serverText = "nope"
        if case .failed = await s.sendTest() {} else { Issue.record("invalid server must not send") }
        #expect(t.requests.get.count == 1)
        let bad = RecordingTransport()
        bad.error = URLError(.cannotConnectToHost)
        let s2 = make(transport: bad)
        if case .failed = await s2.sendTest() {} else { Issue.record("transport error must fail") }
    }
}

final class RecordingTransport: NtfyTransport, @unchecked Sendable {
    let requests = Locked<[URLRequest]>([])
    var status = 200
    var error: Error?
    func send(_ request: URLRequest) async throws -> Int {
        requests.with { $0.append(request) }
        if let error { throw error }
        return status
    }
}
