import Foundation
import Testing
@testable import ShuaiApp

@Suite("Notice factories")
struct NoticeFactoryTests {
    let hid = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!

    @Test func deepLinkNoticeIsWarningWithStableKey() {
        let a = Notice.deepLink(.notice("one"))
        let b = Notice.deepLink(.notice("two"))
        #expect(a?.severity == .warning)
        #expect(a?.source == .deepLink)
        #expect(a?.scope == .app)
        #expect(a?.lifetime == .auto)
        #expect(a?.key == b?.key)
        #expect((a?.duration ?? 0) >= 8000)
        #expect(Notice.deepLink(.opened) == nil)
        #expect(Notice.deepLink(.ignored) == nil)
    }

    @Test func deepLinkNoticeTextComesFromOutcome() {
        #expect(Notice.deepLink(.notice("That pane no longer exists."))?.text == "That pane no longer exists.")
    }

    @Test func pushSyncFailureRedactsTopicAndToken() throws {
        let id = UUID()
        let n = try #require(Notice.pushSync(
            .failed("PUT https://ntfy.example/s3cretTopic failed: Bearer tk_abc123 rejected"),
            hostName: "box", hostID: id, redacting: ["s3cretTopic", "tk_abc123", ""]))
        #expect(n.severity == .warning)
        #expect(n.text.hasPrefix("Could not sync to box: "))
        #expect(!n.text.contains("s3cretTopic"))
        #expect(!n.text.contains("tk_abc123"))
        #expect(n.key == "push-sync:\(id.uuidString)")
    }

    @Test func pushSyncSuccessIsSuccess() throws {
        let n = try #require(Notice.pushSync(.synced, hostName: "box", hostID: hid, redacting: []))
        #expect(n.severity == .success)
        #expect(n.text == "Notification settings synced to box.")
        #expect(n.key == "push-sync:\(hid.uuidString)")
        #expect(Notice.pushSync(.upToDate, hostName: "box", hostID: hid, redacting: []) == nil)
    }

    @Test func pushSyncFailureIsSanitizedAndCapped() throws {
        let long = "bad\u{202E}\n" + String(repeating: "x", count: 1000)
        let n = try #require(Notice.pushSync(.failed(long), hostName: "box", hostID: hid, redacting: []))
        #expect(n.text.count <= Notice.textLimit)
        #expect(!n.text.contains("\u{202E}"))
        #expect(!n.text.contains("\n"))
    }

    @Test func noAttentionIsInfo() {
        let n = Notice.noAttention
        #expect(n.severity == .info)
        #expect(n.text == "No agent needs your attention.")
    }

    @Test func syncSummariesAreInfoAndSuccess() {
        #expect(Notice.noSyncTargets.severity == .info)
        #expect(Notice.pushSyncedAll.severity == .success)
    }

    // MARK: redaction

    @Test func redactRemovesSecretSplitByInvisibleCharacters() {
        let out = Notice.redact("failed for s3c\u{200B}re\u{202E}tTopic now", secrets: ["s3cretTopic"], limit: 300)
        #expect(!out.contains("s3c"))
        #expect(out.contains("…"))
    }

    @Test func redactReplacesLongestSecretFirst() {
        let out = Notice.redact("token abcdef1234 end", secrets: ["abcdef", "abcdef1234"], limit: 300)
        #expect(out == "token … end")
    }

    @Test func redactIsCaseInsensitive() {
        let out = Notice.redact("url /MyTopic and /mytopic", secrets: ["MyTopic"], limit: 300)
        #expect(!out.lowercased().contains("mytopic"))
    }

    @Test func redactHandlesSecretNearTheCap() throws {
        let msg = String(repeating: "x", count: 288) + " tk_SECRETVALUE tail"
        let n = try #require(Notice.pushSync(.failed(msg), hostName: "box", hostID: hid, redacting: ["tk_SECRETVALUE"]))
        #expect(!n.text.contains("tk_"))
        #expect(!n.text.contains("SECRET"))
    }

    @Test func redactSkipsEmptySecrets() {
        #expect(Notice.redact("plain text", secrets: ["", ""], limit: 300) == "plain text")
    }

    // MARK: paths

    @Test func syncFailureCollapsesHomePaths() throws {
        let msg = "mkdir: cannot create directory '/home/alice/.shuai' and /Users/bob/x and /root/y"
        let n = try #require(Notice.pushSync(.failed(msg), hostName: "box", hostID: hid, redacting: []))
        #expect(n.text.contains("'~/.shuai'"))
        #expect(n.text.contains("~/x"))
        #expect(n.text.contains("~/y"))
        #expect(!n.text.contains("alice"))
        #expect(!n.text.contains("bob"))
        #expect(Notice.collapseHomePaths("/rootfs/a /var/log") == "/rootfs/a /var/log")
    }

    // MARK: summary

    @Test func summaryPostsOneWarningPerFailedHostAndNoSuccess() {
        let a = UUID(), b = UUID(), c = UUID()
        let r = Notice.pushSyncSummary(
            [(a, "one", .failed("x")), (b, "two", .failed("y")), (c, "three", .synced)], redacting: [])
        #expect(r.post.count == 2)
        #expect(r.post.allSatisfy { $0.severity == .warning })
        #expect(r.retractKeys == ["push-sync:\(c.uuidString)"])
    }

    @Test func summaryWithoutFailuresPostsSuccessAndRetractsStaleFailures() {
        let a = UUID()
        let r = Notice.pushSyncSummary([(a, "one", .synced)], redacting: [])
        #expect(r.post.map(\.text) == [Notice.pushSyncedAll.text])
        #expect(r.retractKeys == ["push-sync:\(a.uuidString)"])
    }

    @Test func summaryWithNoTargetsSaysSo() {
        #expect(Notice.pushSyncSummary([], redacting: []).post.map(\.text) == [Notice.noSyncTargets.text])
    }

    @MainActor @Test func twoFailedHostsCoexistAndRecoveryRetractsOne() {
        let clock = FakeClock()
        let center = NoticeCenter(now: { clock.now }, sleep: { try await clock.sleep($0) })
        let a = UUID(), b = UUID()
        center.apply(Notice.pushSyncSummary([(a, "one", .failed("x")), (b, "two", .failed("y"))], redacting: []))
        #expect(center.queue.count == 2)
        center.apply(Notice.pushSyncSummary([(a, "one", .synced), (b, "two", .failed("y"))], redacting: []))
        #expect(center.queue.allNotices.map(\.key) == ["push-sync:\(b.uuidString)"])
    }
}
