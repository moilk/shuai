import Foundation
import Testing
import ShuaiCore
@testable import ShuaiApp

private func session(
    state: FfiSessionState = .done, cwd: String? = "/work/app", prompt: String? = "fix the login bug",
    message: String? = nil, pane: String? = "%1", pending: FfiPendingPermission? = nil
) -> FfiAgentSession {
    FfiAgentSession(
        host: "h", sessionId: "s1", source: .claude, cwd: cwd, title: nil, model: nil, tmuxPane: pane, tmuxSocket: nil,
        pid: nil, state: state, currentTool: nil, lastPrompt: prompt, lastMessage: message, pendingPermission: pending,
        activeSubagents: 0, seen: false, needsAttention: true, badge: .done, updatedAt: 0, startedAt: 0)
}

private let key = FfiSessionKey(host: "h", sessionId: "s1")

@Suite("BannerContent")
struct BannerContentTests {
    private func banner(_ kind: AttentionBanner.Kind) -> AttentionBanner {
        AttentionBanner(id: UUID(), key: key, kind: kind)
    }

    @Test func needsInputNamesTheHostAndQuotesThePrompt() {
        let c = BannerContent.make(banner(.needsInput), hostName: "dev", session: session(state: .needsInput))
        #expect(c.title == "dev: needs your input")
        #expect(c.message == "fix the login bug")
        #expect(c.symbol == PaneBadge.needsInput.symbol)
    }

    @Test func doneShowsTheLastMessageWhenThereIsOne() {
        let c = BannerContent.make(banner(.done), hostName: "dev", session: session(message: "All tests pass.\nMore"))
        #expect(c.title == "dev: done")
        #expect(c.message == "All tests pass. More")
    }

    @Test func failedShowsTheError() {
        let c = BannerContent.make(banner(.failed(error: "rate_limit")), hostName: "dev", session: session())
        #expect(c.title == "dev: failed")
        #expect(c.message == "rate_limit")
    }

    @Test func unknownSessionFallsBackToTheKey() {
        let c = BannerContent.make(banner(.done), hostName: "dev", session: nil)
        #expect(c.title == "dev: done")
        #expect(c.message == "")
    }

    @Test func terminalNotificationsShareTheShape() {
        let c = BannerContent.make(title: "Build", body: "finished", hostName: "dev")
        #expect(c.title == "Build")
        #expect(c.message == "finished")
        let untitled = BannerContent.make(title: "", body: "just text", hostName: "dev")
        #expect(untitled.title == "dev")
        #expect(untitled.message == "just text")
    }

    @Test func permissionBannersAreNotShownAsBannersTheCardsCoverThem() {
        #expect(!BannerContent.isShownAsBanner(banner(.permission(requestId: "r", tool: "Bash", preview: "ls"))))
        #expect(BannerContent.isShownAsBanner(banner(.needsInput)))
        #expect(BannerContent.isShownAsBanner(banner(.done)))
        #expect(BannerContent.isShownAsBanner(banner(.failed(error: "x"))))
    }
}

@Suite("AttentionNotificationPolicy")
struct AttentionNotificationPolicyTests {
    private func make(_ change: FfiTrackerChange, active: Bool, s: FfiAgentSession? = session()) -> LocalNotificationContent? {
        AttentionNotificationPolicy.content(for: change, session: s, hostName: "dev", appActive: active)
    }

    @Test func nothingWhileTheAppIsInTheForeground() {
        #expect(make(.stateChanged(key: key, from: .working(tool: nil), to: .done), active: true) == nil)
    }

    @Test func transitionsThatWantTheUserNotifyInTheBackground() {
        let done = make(.stateChanged(key: key, from: .working(tool: nil), to: .done), active: false)
        #expect(done?.title == "dev: done")
        #expect(done?.body == "fix the login bug")
        let input = make(.stateChanged(key: key, from: .working(tool: nil), to: .needsInput), active: false)
        #expect(input?.title == "dev: needs your input")
        let failed = make(.stateChanged(key: key, from: .working(tool: nil), to: .failed(error: "boom")), active: false)
        #expect(failed?.title == "dev: failed")
        #expect(failed?.body == "boom")
    }

    @Test func permissionRequestsNotifyWithToolAndPreview() {
        let req = FfiPendingPermission(requestId: "r1", toolName: "Bash", inputPreview: "rm -rf build", toolInputJson: "{}", since: 0)
        let n = make(.permissionRequested(key: key, request: req), active: false)
        #expect(n?.title == "dev: needs approval")
        #expect(n?.body == "Bash: rm -rf build")
        #expect(n?.identifier == "permission-r1")
        #expect(n?.paneID == "%1")
    }

    @Test func quietTransitionsNeverNotify() {
        #expect(make(.stateChanged(key: key, from: .done, to: .working(tool: nil)), active: false) == nil)
        #expect(make(.stateChanged(key: key, from: .working(tool: nil), to: .ended), active: false) == nil)
        #expect(make(.sessionAdded(key: key), active: false) == nil)
        #expect(make(.permissionCleared(key: key), active: false) == nil)
        // a permission state change is covered by the request itself
        #expect(make(.stateChanged(key: key, from: .working(tool: nil), to: .needsPermission), active: false) == nil)
    }

    @Test func oneIdentifierPerSessionSoANewerTransitionReplacesTheOlder() {
        let a = make(.stateChanged(key: key, from: .working(tool: nil), to: .done), active: false)
        let b = make(.stateChanged(key: key, from: .working(tool: nil), to: .needsInput), active: false)
        #expect(a?.identifier == b?.identifier)
        #expect(a?.identifier == "session-h-s1")
    }
}

@Suite("FfiTrackerChange.sessionKey")
struct TrackerChangeKeyTests {
    @Test func everyChangeNamesItsSession() {
        let req = FfiPendingPermission(requestId: "r", toolName: "Bash", inputPreview: "", toolInputJson: "{}", since: 0)
        let changes: [FfiTrackerChange] = [
            .sessionAdded(key: key), .sessionRemoved(key: key), .stateChanged(key: key, from: .done, to: .ended),
            .permissionRequested(key: key, request: req), .permissionCleared(key: key),
        ]
        #expect(changes.allSatisfy { $0.sessionKey == key })
    }
}
