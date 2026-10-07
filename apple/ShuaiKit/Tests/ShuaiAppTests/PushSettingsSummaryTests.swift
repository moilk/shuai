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
        let secrets = InMemoryPushSecretStore()
        let topic = "shuai-" + String(repeating: "q7", count: 13)
        let token = "tk_abcdefghijklmnopqrstuvwxyz012345"
        secrets.set(topic, for: .topic)
        secrets.set(token, for: .token)
        let defaults = UserDefaults(suiteName: "PushSettingsSummaryTests-\(UUID().uuidString)")!
        let s = PushSettings(defaults: defaults, secrets: secrets)
        s.serverText = "https://ntfy.example.org"
        s.enabled = true
        #expect(s.topic == topic)
        #expect(s.token == token)
        let text = PushSettingsSummary.text(for: s)
        #expect(text == "On · ntfy.example.org")
        #expect(!text.contains(topic))
        #expect(!text.contains(String(topic.suffix(6))))
        #expect(!text.contains(token))
        #expect(!text.contains("shuai-"))
    }

    @Test func summaryHidesUserinfoFromURL() {
        for server in ["https://user:pass@host.example", "https://tok@host.example"] {
            let text = PushSettingsSummary.text(enabled: true, serverText: server)
            #expect(!text.contains("user"), "\(text)")
            #expect(!text.contains("pass"), "\(text)")
            #expect(!text.contains("tok"), "\(text)")
        }
    }

    @Test func summaryForHTTPServer() {
        #expect(PushSettingsSummary.text(enabled: true, serverText: "http://ntfy.lan:8080") == "On · ntfy.lan")
    }

    @Test func summaryForIPv6ServerIsSafe() {
        let text = PushSettingsSummary.text(enabled: true, serverText: "https://[2001:db8::1]:8443/sub")
        #expect(!text.contains("8443"))
        #expect(!text.contains("sub"))
        #expect(!text.contains("https"))
    }

    @Test func summaryForEmptyServerWhileEnabled() {
        #expect(PushSettingsSummary.text(enabled: true, serverText: "") == "On")
        #expect(PushSettingsSummary.text(enabled: true, serverText: "   ") == "On")
    }

    @Test func summaryForIDNHost() {
        let text = PushSettingsSummary.text(enabled: true, serverText: "https://bücher.example/x")
        #expect(!text.contains("https"))
        #expect(!text.contains("/x"))
        #expect(text.hasPrefix("On"))
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

    @Test func maskOfFullwidthPrefixRevealsNothing() {
        let t = "ｓｈｕａｉ-" + String(repeating: "a", count: 22) + "wxyz"
        #expect(NtfyTopic.masked(t) == "••••••••")
        #expect(NtfyTopic.maskedSpoken(t) == "Topic hidden")
    }

    @Test func maskOfCombiningCharacterRevealsNothing() {
        let t = "shuai-" + String(repeating: "a", count: 24) + "z\u{301}"
        #expect(NtfyTopic.masked(t) == "••••••••")
        let t2 = "shuai-" + String(repeating: "a", count: 25) + "\u{301}z"
        #expect(NtfyTopic.masked(t2) == "••••••••")
    }

    @Test func maskedSpokenNamesLastFour() {
        let t = "shuai-" + String(repeating: "a", count: 22) + "wxyz"
        #expect(NtfyTopic.maskedSpoken(t) == "Topic hidden, ends in wxyz")
        #expect(NtfyTopic.maskedSpoken("secret") == "Topic hidden")
    }

    @Test func maskedSpokenNeverContainsMoreThanFourChars() {
        let t = NtfyTopic.generate()
        let spoken = NtfyTopic.maskedSpoken(t)
        #expect(spoken.hasSuffix(String(t.suffix(4))))
        #expect(!spoken.contains(String(t.suffix(5))))
        #expect(spoken.count == "Topic hidden, ends in ".count + 4)
    }
}

@Suite("TopicRevealPolicy")
struct TopicRevealPolicyTests {
    @Test func staysRevealedOnlyWhileActive() {
        #expect(TopicRevealPolicy.shouldKeepRevealed(isActive: true))
        #expect(!TopicRevealPolicy.shouldKeepRevealed(isActive: false))
    }
}
