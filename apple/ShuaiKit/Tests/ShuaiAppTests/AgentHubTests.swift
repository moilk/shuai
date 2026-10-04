import Foundation
import Testing
import ShuaiCore
@testable import ShuaiApp

// MARK: probe + version

@Suite("AgentHostProbe")
struct AgentHostProbeTests {
    @Test func parsesHostnameVersionAndClaudePath() {
        let out = RemoteExecOutput.ok("host=e2e-host\nagent=shuai-agent 0.1.3\nclaude=/home/u/.local/bin/claude\n")
        let info = AgentHostProbe.parse(out)
        #expect(info == AgentHostInfo(hostname: "e2e-host", agentVersion: "0.1.3", claudePath: "/home/u/.local/bin/claude"))
    }

    @Test func missingAgentMeansNoVersion() {
        let info = AgentHostProbe.parse(.ok("host=box\n"))
        #expect(info == AgentHostInfo(hostname: "box", agentVersion: nil, claudePath: nil))
    }

    @Test func noHostnameIsNoInfo() {
        #expect(AgentHostProbe.parse(.ok("agent=shuai-agent 0.1.0\n")) == nil)
        #expect(AgentHostProbe.parse(.fail(1, "boom")) == nil)
    }

    @Test func commandHonoursTheAgentsHostnameOverrideAndStaysQuoted() {
        let c = AgentHostProbe.command
        #expect(c.hasPrefix("sh -c "))
        #expect(c.contains("SHUAI_HOSTNAME"))
        #expect(c.contains(".shuai/bin/shuai-agent"))
        #expect(c.contains("--version"))
    }

    @Test func versionComparison() {
        #expect(AgentHostStatus.make(installed: nil, bundled: "0.2.0") == .notInstalled)
        #expect(AgentHostStatus.make(installed: "0.1.9", bundled: "0.2.0") == .outdated(installed: "0.1.9", bundled: "0.2.0"))
        #expect(AgentHostStatus.make(installed: "0.2.0", bundled: "0.2.0") == .installed(version: "0.2.0"))
        #expect(AgentHostStatus.make(installed: "0.10.0", bundled: "0.9.0") == .installed(version: "0.10.0"))
        #expect(AgentHostStatus.make(installed: "weird", bundled: "0.2.0") == .installed(version: "weird"))
    }
}

// MARK: hub

private let probeOK = "host=\(GoldenTranscript.host)\nagent=shuai-agent 0.1.0\n"

private func remote(probe: String = probeOK) -> FakeAgentRemote {
    FakeAgentRemote(handler: { cmd in cmd.hasPrefix("sh -c") && cmd.contains("--version") ? .ok(probe) : .ok() })
}

@MainActor
private func hub(expected: String = "0.1.0") -> AgentHub {
    AgentHub(expectedVersion: expected, now: { 1_791_018_700_000 })
}

/// Streams the golden lines `range` as live events (after an empty replay) on the host's watch.
@MainActor
private func feed(_ r: FakeAgentRemote, lines range: Range<Int>) async {
    #expect(await waitUntil { r.lastStream != nil })
    let s = r.lastStream!
    s.emitLines([GoldenTranscript.heartbeat, GoldenTranscript.caughtUp] + Array(GoldenTranscript.lines[range]))
}

@Suite("AgentHub")
@MainActor
struct AgentHubTests {
    let a = UUID()
    let b = UUID()

    @Test func startsAMonitorKeyedByTheRemoteHostnameAndMapsBadgesByProfileID() async {
        let h = hub()
        let r = remote()
        await h.hostConnected(id: a, remote: r)
        #expect(h.status(for: a) == .installed(version: "0.1.0"))
        let m = h.monitor(for: a)
        #expect(m?.host == "e2e-host")
        await feed(r, lines: 0..<4)  // up to the first permission request
        #expect(await waitUntil { m?.sessions.first?.state == .needsPermission })
        // The sidebar asks with the profile UUID, never with the hostname.
        #expect(h.badge(host: a.uuidString, pane: "%0") == .needsPermission)
        #expect(h.badge(host: GoldenTranscript.host, pane: "%0") == nil)
        #expect(h.badge(host: b.uuidString, pane: "%0") == nil)
        #expect(h.waitingCount(for: a) == 1)
        #expect(h.totalWaiting == 1)
    }

    @Test func hostWithoutTheAgentGetsNoMonitorAndNoStream() async {
        let h = hub()
        let r = remote(probe: "host=box\n")
        await h.hostConnected(id: a, remote: r)
        #expect(h.status(for: a) == .notInstalled)
        #expect(h.monitor(for: a) == nil)
        #expect(r.streams.get.isEmpty)
        #expect(h.badge(host: a.uuidString, pane: "%0") == nil)
    }

    @Test func outdatedAgentStillWatchesButIsFlagged() async {
        let h = hub(expected: "0.2.0")
        let r = remote()
        await h.hostConnected(id: a, remote: r)
        #expect(h.status(for: a) == .outdated(installed: "0.1.0", bundled: "0.2.0"))
        #expect(h.monitor(for: a) != nil)
        #expect(await waitUntil { r.lastStream != nil })
    }

    @Test func failedProbeLeavesTheHostUnknown() async {
        let h = hub()
        let r = FakeAgentRemote(handler: { _ in .fail(255, "oops") })
        await h.hostConnected(id: a, remote: r)
        #expect(h.status(for: a) == .unknown)
        #expect(h.monitor(for: a) == nil)
    }

    @Test func reconnectResumesTheSameMonitorFromItsCursor() async {
        let h = hub()
        let r1 = remote()
        await h.hostConnected(id: a, remote: r1)
        await feed(r1, lines: 0..<4)
        let m = h.monitor(for: a)!
        #expect(await waitUntil { m.lastSeq == 4 })
        h.hostDisconnected(id: a)
        #expect(m.state == .disconnected)
        #expect(m.sessions.count == 1, "state survives a disconnect")
        let r2 = remote()
        await h.hostConnected(id: a, remote: r2)
        #expect(h.monitor(for: a) === m)
        #expect(await waitUntil { r2.lastStream != nil })
        #expect(r2.lastStream?.command == "~/.shuai/bin/shuai-agent watch --since 4")
    }

    @Test func aLateProbeOfTheOldConnectionIsDropped() async {
        let h = hub()
        let old = remote()
        let release = Locked<CheckedContinuation<Void, Never>?>(nil)
        old.gate.with { $0 = { await withCheckedContinuation { c in release.with { $0 = c } } } }
        let first = Task { await h.hostConnected(id: a, remote: old) }
        #expect(await waitUntil { release.get != nil })  // old probe is in flight
        let fresh = remote()
        await h.hostConnected(id: a, remote: fresh)  // reconnected meanwhile
        #expect(await waitUntil { fresh.lastStream != nil })
        old.gate.with { $0 = nil }
        release.get?.resume()
        await first.value
        #expect(old.streams.get.isEmpty, "the stale probe result must not attach the dead connection")
        #expect(h.monitor(for: a) != nil)
        #expect(fresh.streams.get.count == 1)
    }

    @Test func aChangedHostnameStartsAFreshMonitor() async {
        let h = hub()
        await h.hostConnected(id: a, remote: remote())
        let first = h.monitor(for: a)
        await h.hostConnected(id: a, remote: remote(probe: "host=other\nagent=shuai-agent 0.1.0\n"))
        #expect(h.monitor(for: a) !== first)
        #expect(h.monitor(for: a)?.host == "other")
    }

    @Test func removeHostForgetsEverything() async {
        let h = hub()
        await h.hostConnected(id: a, remote: remote())
        h.removeHost(id: a)
        #expect(h.monitor(for: a) == nil)
        #expect(h.status(for: a) == .unknown)
    }

    @Test func pendingPermissionsAcrossHostsCarryTheProfileID() async {
        let h = hub()
        let ra = remote()
        let rb = remote(probe: "host=second\nagent=shuai-agent 0.1.0\n")
        await h.hostConnected(id: a, remote: ra)
        await h.hostConnected(id: b, remote: rb)
        await feed(ra, lines: 0..<4)
        #expect(await waitUntil { h.pendingPermissions.count == 1 })
        let p = h.pendingPermissions[0]
        #expect(p.profileID == a)
        #expect(p.item.request.requestId == GoldenTranscript.firstRequest)
        #expect(h.profileID(for: p.item.key) == a)
    }

    @Test func respondGoesToTheOwningHostAndTheCardClearsWhenResolved() async {
        let h = hub()
        let r = remote()
        await h.hostConnected(id: a, remote: r)
        await feed(r, lines: 0..<4)
        #expect(await waitUntil { h.pendingPermissions.count == 1 })
        let p = h.pendingPermissions[0]
        let result = await h.respond(p, allow: true, message: nil)
        #expect(result == .sent)
        #expect(r.ran(containing: "respond").first?.contains(GoldenTranscript.firstRequest) == true)
        // answered (here or in the terminal) -> permission_resolved arrives -> card gone
        r.lastStream!.emitLines(Array(GoldenTranscript.lines[4..<6]))
        #expect(await waitUntil { h.pendingPermissions.isEmpty })
    }

    @Test func liveTransitionsReachTheBannerQueueAndCallbackWithTheProfile() async {
        let h = hub()
        let seen = Locked<[UUID]>([])
        h.onLiveChanges = { id, _ in seen.with { $0.append(id) } }
        let r = remote()
        await h.hostConnected(id: a, remote: r)
        await feed(r, lines: 0..<8)
        #expect(await waitUntil { !h.banners.banners.isEmpty })
        #expect(!seen.get.isEmpty)
        #expect(seen.get.allSatisfy { $0 == a })
        #expect(h.banners.banners.contains { if case .done = $0.kind { true } else { false } })
    }

    @Test func nextNeedingAttentionResolvesPaneAndProfile() async {
        let h = hub()
        let ra = remote()
        await h.hostConnected(id: a, remote: ra)
        await feed(ra, lines: 0..<4)  // permission pending on a
        #expect(await waitUntil { h.attentionTargets().count == 1 })
        let first = h.nextNeedingAttention(after: nil)
        #expect(first?.profileID == a)
        #expect(first?.paneID == "%0")
        #expect(first?.session.sessionId == GoldenTranscript.sessionID)
        // only one candidate: after it, we come back to it
        #expect(h.nextNeedingAttention(after: first?.key)?.key == first?.key)
    }

    @Test func targetForAKeyResolvesAnySessionNeedingAttentionOrNot() async {
        let h = hub()
        let r = remote()
        await h.hostConnected(id: a, remote: r)
        await feed(r, lines: 0..<3)  // working, no attention
        #expect(await waitUntil { h.monitor(for: a)?.sessions.count == 1 })
        let key = FfiSessionKey(host: GoldenTranscript.host, sessionId: GoldenTranscript.sessionID)
        let t = h.target(for: key)
        #expect(t?.profileID == a)
        #expect(t?.paneID == "%0")
        #expect(h.target(for: FfiSessionKey(host: "nope", sessionId: "x")) == nil)
    }

    @Test func markSeenByPaneClearsTheSessionThatLivesThere() async {
        let h = hub()
        let r = remote()
        await h.hostConnected(id: a, remote: r)
        await feed(r, lines: 0..<8)  // done, unseen, pane %0
        #expect(await waitUntil { h.attentionTargets().count == 1 })
        h.markSeen(profileID: a, paneID: "%7")  // another pane: nothing happens
        #expect(h.attentionTargets().count == 1)
        h.markSeen(profileID: a, paneID: "%0")
        #expect(h.attentionTargets().isEmpty)
    }

    @Test func markSeenOnArrivalDropsADoneSessionFromTheList() async {
        let h = hub()
        let r = remote()
        await h.hostConnected(id: a, remote: r)
        await feed(r, lines: 0..<8)  // ends done, unseen
        #expect(await waitUntil { h.attentionTargets().count == 1 })
        let t = h.attentionTargets()[0]
        h.markSeen(t)
        #expect(h.attentionTargets().isEmpty)
        #expect(h.waitingCount(for: a) == 0)
    }
}

@Suite("AttentionCycle")
struct AttentionCycleTests {
    @Test func picksTheFirstAfterCurrentAndWraps() {
        let keys = ["a", "b", "c"].map { FfiSessionKey(host: "h", sessionId: $0) }
        #expect(AttentionCycle.next(after: nil, in: keys) == keys[0])
        #expect(AttentionCycle.next(after: keys[0], in: keys) == keys[1])
        #expect(AttentionCycle.next(after: keys[2], in: keys) == keys[0])
        // the current one is gone (it was marked seen): start from the top again
        #expect(AttentionCycle.next(after: FfiSessionKey(host: "h", sessionId: "gone"), in: keys) == keys[0])
        #expect(AttentionCycle.next(after: nil, in: []) == nil)
    }
}

@Suite("ConnectionAgentRemote")
struct ConnectionAgentRemoteTests {
    @Test func execStreamsAndUploadsGoThroughTheConnection() async throws {
        let conn = FakeConnection()
        conn.execHandler.with { $0 = { _ in ExecResult(stdout: Data("out".utf8), stderr: Data("err".utf8), exitStatus: 3, exitSignal: nil) } }
        let remote = ConnectionAgentRemote(conn)
        let r = try await remote.exec("echo hi")
        #expect(r == RemoteExecOutput(stdout: "out", stderr: "err", exitStatus: 3))
        #expect(conn.execCommands.get == ["echo hi"])

        let stream = try await remote.execStream("tail -f x")
        #expect(conn.execStreamCommands.get == ["tail -f x"])
        let fake = conn.execStreams.get[0]
        fake.emit("line\n")
        fake.emit(.exitStatus(status: 0))
        fake.finish()
        var seen: [AgentStreamEvent] = []
        for await e in stream.events { seen.append(e) }
        #expect(seen == [.stdout(Data("line\n".utf8)), .exited(0), .closed])

        try await remote.upload(Data("x".utf8), to: "/p", mode: 0o755)
        #expect(conn.uploads.get == [UploadRecord(path: "/p", data: Data("x".utf8), mode: 0o755)])
    }
}

@Suite("AgentHub agent-ready hook")
@MainActor
struct AgentHubReadyTests {
    @Test func firesOnceForAnInstalledAgentWithItsHostID() async {
        let h = hub()
        let id = UUID()
        let seen = Locked<[UUID]>([])
        h.onAgentReady = { host, _ in seen.with { $0.append(host) } }
        await h.hostConnected(id: id, remote: remote())
        #expect(await waitUntil { seen.get == [id] })
    }

    @Test func doesNotFireWithoutAnInstalledAgent() async {
        let h = hub()
        let fired = Locked(false)
        h.onAgentReady = { _, _ in fired.with { $0 = true } }
        await h.hostConnected(id: UUID(), remote: remote(probe: "host=box\n"))
        try? await Task.sleep(for: .milliseconds(100))
        #expect(!fired.get)
    }
}
