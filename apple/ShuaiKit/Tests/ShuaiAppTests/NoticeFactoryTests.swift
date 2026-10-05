import Foundation
import Testing
@testable import ShuaiApp

@Suite("Notice factories")
struct NoticeFactoryTests {
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
        let n = try #require(Notice.pushSync(.synced, hostName: "box", hostID: nil, redacting: []))
        #expect(n.severity == .success)
        #expect(n.text == "Notification settings synced to box.")
        #expect(n.key == "push-sync")
        #expect(Notice.pushSync(.upToDate, hostName: "box", hostID: nil, redacting: []) == nil)
    }

    @Test func pushSyncFailureIsSanitizedAndCapped() throws {
        let long = "bad\u{202E}\n" + String(repeating: "x", count: 1000)
        let n = try #require(Notice.pushSync(.failed(long), hostName: "box", hostID: nil, redacting: []))
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
}
