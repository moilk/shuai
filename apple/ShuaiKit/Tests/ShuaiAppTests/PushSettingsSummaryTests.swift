import Foundation
import Testing
@testable import ShuaiApp

@Suite("PushSettingsSummary")
@MainActor
struct PushSettingsSummaryTests {
    private func settings(enabled: Bool, server: String, token: String = "") -> PushSettings {
        let defaults = UserDefaults(suiteName: "PushSettingsSummaryTests-\(UUID().uuidString)")!
        let s = PushSettings(defaults: defaults, secrets: InMemoryPushSecretStore())
        s.serverText = server
        s.token = token
        s.enabled = enabled
        return s
    }

    @Test func summaryShowsServerHostOnly() {
        let s = settings(enabled: true, server: "https://ntfy.sh")
        #expect(PushSettingsSummary.text(for: s) == "On · ntfy.sh")
    }

    @Test func summaryOffWhenDisabled() {
        #expect(PushSettingsSummary.text(for: settings(enabled: false, server: "https://ntfy.sh")) == "Off")
    }

    @Test func summaryNeverContainsTopicOrToken() {
        let s = settings(enabled: true, server: "https://ntfy.example.org", token: "tk_supersecrettoken")
        let text = PushSettingsSummary.text(for: s)
        #expect(!text.contains(s.topic))
        #expect(!text.contains("shuai-"))
        #expect(!text.contains("tk_supersecrettoken"))
    }

    @Test func summaryOmitsPathAndQuery() {
        let s = settings(enabled: true, server: "https://ntfy.example.org:8443/sub/path")
        let text = PushSettingsSummary.text(for: s)
        #expect(text == "On · ntfy.example.org")
        #expect(!text.contains("sub"))
        #expect(PushSettingsSummary.text(enabled: true, serverText: "https://h.example.org/p?token=abc") == "On")
    }
}

@Suite("NtfyTopic masking")
struct NtfyTopicMaskTests {
    @Test func maskKeepsPrefixAndLastFour() {
        let t = "shuai-" + String(repeating: "a", count: 22) + "wxyz"
        #expect(NtfyTopic.masked(t) == "shuai-••••…wxyz")
    }

    @Test func maskNeverEqualsTheTopic() {
        let t = NtfyTopic.generate()
        let m = NtfyTopic.masked(t)
        #expect(m != t)
        #expect(m.count < t.count)
        #expect(!m.dropFirst(6).dropLast(4).contains { $0.isLetter || $0.isNumber })
    }

    @Test func maskOfMalformedInputRevealsNothing() {
        for bad in ["", "abc", "shuai-", "secret-token-value-1234", "shuai-short", "shuai-" + String(repeating: "A", count: 26)] {
            let m = NtfyTopic.masked(bad)
            #expect(m == "••••••••", "\(bad)")
            #expect(!m.contains("shuai"))
        }
    }
}
