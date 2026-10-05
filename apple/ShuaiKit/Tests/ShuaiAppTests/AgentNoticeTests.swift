import Foundation
import ShuaiCore
import Testing
@testable import ShuaiApp

private func session(_ id: String, prompt: String? = nil, message: String? = nil) -> FfiAgentSession {
    FfiAgentSession(
        host: "h", sessionId: id, source: .claude, cwd: "/w", title: nil, model: nil, tmuxPane: "%1", tmuxSocket: nil,
        pid: nil, state: .done, currentTool: nil, lastPrompt: prompt, lastMessage: message, pendingPermission: nil,
        activeSubagents: 0, seen: false, needsAttention: true, badge: .done, updatedAt: 0, startedAt: 0)
}

private func sk(_ id: String) -> FfiSessionKey { FfiSessionKey(host: "h", sessionId: id) }

private func resolve(_ b: AttentionBanner) -> (hostName: String, session: FfiAgentSession?) {
    ("dev", session(b.key.sessionId, message: "all green"))
}

@MainActor
private func banners(_ changes: [FfiTrackerChange]) -> [AttentionBanner] {
    let q = AttentionBannerQueue()
    q.enqueue(changes)
    return q.banners
}

@MainActor
@Suite("Agent notices")
struct AgentNoticeTests {
    @Test func agentNoticesSkipPermissionKinds() {
        let req = FfiPendingPermission(requestId: "r1", toolName: "Bash", inputPreview: "ls", toolInputJson: "{}", since: 0)
        let list = banners([
            .permissionRequested(key: sk("p"), request: req),
            .stateChanged(key: sk("d"), from: .working(tool: nil), to: .done),
        ])
        #expect(list.count == 2)
        let notices = AgentNotices.make(list, resolve: resolve)
        #expect(notices.count == 1)
        #expect(notices.first?.action == .jumpToAgent(sk("d")))
    }

    @Test func agentNoticeIdEqualsBannerId() {
        let list = banners([.stateChanged(key: sk("a"), from: .working(tool: nil), to: .needsInput)])
        #expect(AgentNotices.make(list, resolve: resolve).map(\.id) == list.map(\.id))
        #expect(AgentNotices.make(list, resolve: resolve) == AgentNotices.make(list, resolve: resolve))
    }

    @Test func agentNoticeUsesBannerContentAttribution() throws {
        let list = banners([.stateChanged(key: sk("a"), from: .working(tool: nil), to: .done)])
        let n = try #require(AgentNotices.make(list, resolve: resolve).first)
        let content = BannerContent.make(list[0], hostName: "dev", session: session("a", message: "all green"))
        #expect(n.title == content.title)
        #expect(n.title?.hasPrefix("dev") == true)
        #expect(n.text == content.message)
        #expect(n.symbol == content.symbol)
        #expect(n.source == .agent)
        #expect(n.scope == .app)
        #expect(n.lifetime == .auto)
        #expect(n.accessibilityIdentifier == "agent-banner")
    }

    @Test func agentNoticeWithoutSnippetStillHasText() throws {
        let list = banners([.stateChanged(key: sk("a"), from: .working(tool: nil), to: .done)])
        let n = try #require(AgentNotices.make(list, resolve: { _ in ("dev", nil) }).first)
        #expect(!n.text.isEmpty)
        #expect(n.text.contains("dev"))
    }

    @Test func agentNoticeSeverityFollowsKind() {
        let list = banners([
            .stateChanged(key: sk("n"), from: .working(tool: nil), to: .needsInput),
            .stateChanged(key: sk("d"), from: .working(tool: nil), to: .done),
            .stateChanged(key: sk("f"), from: .working(tool: nil), to: .failed(error: "boom")),
        ])
        var by: [String: Notice.Severity] = [:]
        for n in AgentNotices.make(list, resolve: resolve) {
            if case .jumpToAgent(let k) = n.action { by[k.sessionId] = n.severity }
        }
        #expect(by == ["n": .attention, "d": .success, "f": .error])
    }

    @Test func agentNoticeActionJumpsToSession() throws {
        let list = banners([.stateChanged(key: sk("x"), from: .working(tool: nil), to: .done)])
        #expect(try #require(AgentNotices.make(list, resolve: resolve).first).action == .jumpToAgent(sk("x")))
    }

    @Test func agentNoticeKeysAreUniquePerSession() {
        let list = banners([
            .stateChanged(key: sk("a"), from: .working(tool: nil), to: .done),
            .stateChanged(key: sk("b"), from: .working(tool: nil), to: .done),
            .stateChanged(key: sk("a"), from: .done, to: .needsInput),
        ])
        let keys = AgentNotices.make(list, resolve: resolve).map(\.key)
        #expect(keys.count == 2)
        #expect(Set(keys).count == 2)
    }

    @Test func agentNoticeKeysCannotCollideAcrossHostAndSession() {
        func key(host: String, session: String) -> String {
            let k = FfiSessionKey(host: host, sessionId: session)
            let b = banners([.stateChanged(key: k, from: .working(tool: nil), to: .done)])
            return AgentNotices.make(b, resolve: resolve)[0].key
        }
        #expect(key(host: "a|b", session: "c") != key(host: "a", session: "b|c"))
    }

    // MARK: with a real center and queue

    @MainActor
    private final class Rig {
        let clock = FakeClock()
        let queue = AttentionBannerQueue()
        let center: NoticeCenter

        init() {
            let queue = queue
            let clock = clock
            center = NoticeCenter(
                now: { clock.now }, sleep: { try await clock.sleep($0) },
                onDismiss: { AgentNotices.dismissed($0, in: queue) },
                onExpire: { AgentNotices.dismissed($0, in: queue) })
        }

        func live(_ changes: [FfiTrackerChange]) {
            queue.enqueue(changes)
            AgentNotices.sync(queue: queue, center: center, resolve: resolve)
        }
    }

    @Test func dismissingAgentNoticeDismissesQueueBanner() throws {
        let rig = Rig()
        rig.live([.stateChanged(key: sk("a"), from: .working(tool: nil), to: .done)])
        let n = try #require(rig.center.queue.visible.first)
        rig.center.dismiss(id: n.id)
        #expect(rig.queue.banners.isEmpty)
        AgentNotices.sync(queue: rig.queue, center: rig.center, resolve: resolve)
        #expect(rig.center.queue.count == 0)
    }

    @Test func expiringAnAgentNoticeDismissesItsQueueBanner() async throws {
        let rig = Rig()
        rig.live([.stateChanged(key: sk("a"), from: .working(tool: nil), to: .done)])
        #expect(await waitUntil { rig.clock.sleeping == 1 })
        rig.clock.advance(60_000)
        #expect(await waitUntil { rig.center.queue.count == 0 })
        #expect(rig.queue.banners.isEmpty)
    }

    @Test func agentNoticeTextFollowsTheSession() throws {
        let rig = Rig()
        rig.live([.stateChanged(key: sk("a"), from: .working(tool: nil), to: .done)])
        let before = try #require(rig.center.queue.visible.first)
        #expect(before.text == "all green")
        let queue = rig.queue
        AgentNotices.sync(queue: queue, center: rig.center) { b in ("dev", session(b.key.sessionId, message: "now red")) }
        let after = try #require(rig.center.queue.visible.first)
        #expect(after.id == before.id)
        #expect(after.text == "now red")
    }

    @Test func expiredAgentNoticeDoesNotReappearOnNextLiveChange() async throws {
        let rig = Rig()
        rig.live([.stateChanged(key: sk("a"), from: .working(tool: nil), to: .done)])
        #expect(rig.center.queue.count == 1)
        #expect(await waitUntil { rig.clock.sleeping == 1 })
        rig.clock.advance(60_000)
        #expect(await waitUntil { rig.center.queue.count == 0 })
        // The banner is still queued; an unrelated live change must not bring the notice back.
        rig.live([.sessionAdded(key: sk("other"))])
        #expect(rig.center.queue.count == 0)
    }

    @Test func clearedBannerRemovesNotice() {
        let rig = Rig()
        rig.live([.stateChanged(key: sk("a"), from: .working(tool: nil), to: .done)])
        rig.live([.stateChanged(key: sk("b"), from: .working(tool: nil), to: .needsInput)])
        #expect(rig.center.queue.count == 2)
        rig.live([.sessionRemoved(key: sk("a"))])
        #expect(rig.center.queue.allNotices.map(\.action) == [.jumpToAgent(sk("b"))])
        rig.live([.stateChanged(key: sk("b"), from: .needsInput, to: .ended)])
        #expect(rig.center.queue.count == 0)
    }
}
