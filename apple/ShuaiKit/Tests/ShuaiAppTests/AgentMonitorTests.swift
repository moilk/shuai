import Foundation
import Testing
import ShuaiCore
@testable import ShuaiApp

@MainActor
private func makeMonitor(
    _ remote: FakeAgentRemote, claude: String? = nil, reconcile: Duration = .seconds(3600)
) -> (AgentMonitor, Locked<[FfiTrackerChange]>) {
    let m = AgentMonitor(host: GoldenTranscript.host, reconcileInterval: reconcile, now: { 1_791_018_700_000 })
    let live = Locked<[FfiTrackerChange]>([])
    m.onLiveChanges = { c in live.with { $0 += c } }
    m.attach(remote: remote, claudePath: claude)
    return (m, live)
}

@Suite("AgentMonitor")
@MainActor
struct AgentMonitorTests {
    let lines = GoldenTranscript.lines

    @Test func transcriptFixtureIsAvailable() {
        #expect(lines.count == 25)
    }

    @Test func watchesFromCursorZeroOnFirstAttach() async {
        let remote = FakeAgentRemote()
        let (m, _) = makeMonitor(remote)
        #expect(await waitUntil { remote.lastStream != nil })
        #expect(remote.lastStream?.command == "~/.shuai/bin/shuai-agent watch --since 0")
        #expect(m.state == .connecting || m.state == .watching)
    }

    @Test func goldenTranscriptReplayIsSilentLiveIsAnnounced() async {
        let remote = FakeAgentRemote()
        let (m, live) = makeMonitor(remote)
        #expect(await waitUntil { remote.lastStream != nil })
        let s = remote.lastStream!
        // Presence heartbeat first, then the replay (seq 1...8), then the marker, then live.
        s.emitLines([GoldenTranscript.heartbeat] + Array(lines[0..<8]) + [GoldenTranscript.caughtUp])
        #expect(await waitUntil { m.state == .watching && m.sessions.first?.state == .done })
        #expect(live.get.isEmpty, "replay must not announce anything")
        #expect(m.attentionCount == 1)

        s.emitLines(Array(lines[8...]))
        #expect(await waitUntil { m.lastSeq == 25 })
        let requested = live.get.compactMap { c -> String? in
            if case .permissionRequested(_, let r) = c { return r.requestId }
            return nil
        }
        #expect(requested == [GoldenTranscript.secondRequest, "56322b50927d8422f17e13701affe9c5"])
        #expect(m.sessions.count == 1)
        #expect(m.sessions[0].sessionId == GoldenTranscript.sessionID)
        #expect(m.sessions[0].pendingPermission == nil)
    }

    @Test func linesSplitAcrossChunksAreReassembled() async {
        let remote = FakeAgentRemote()
        let (m, _) = makeMonitor(remote)
        #expect(await waitUntil { remote.lastStream != nil })
        let s = remote.lastStream!
        s.emit(GoldenTranscript.heartbeat + "\n")
        s.emit(GoldenTranscript.caughtUp + "\n")
        let first = lines[0]
        let mid = first.index(first.startIndex, offsetBy: 40)
        s.emit(String(first[..<mid]))
        s.emit(String(first[mid...]) + "\n")
        #expect(await waitUntil { m.sessions.count == 1 })
    }

    @Test func olderAgentWithoutCaughtUpEndsReplayAtSecondHeartbeat() async {
        let remote = FakeAgentRemote()
        let (m, live) = makeMonitor(remote)
        #expect(await waitUntil { remote.lastStream != nil })
        let s = remote.lastStream!
        s.emitLines([GoldenTranscript.heartbeat] + Array(lines[0..<4]) + [GoldenTranscript.heartbeat])
        #expect(await waitUntil { m.lastSeq == 4 })
        #expect(live.get.isEmpty)
        s.emitLines(Array(lines[4..<6]))
        #expect(await waitUntil { m.lastSeq == 6 })
        #expect(live.get.contains { if case .permissionCleared = $0 { true } else { false } })
    }

    @Test func malformedLinesAreIgnored() async {
        let remote = FakeAgentRemote()
        let (m, _) = makeMonitor(remote)
        #expect(await waitUntil { remote.lastStream != nil })
        remote.lastStream!.emitLines(["garbage", "{\"x\":", GoldenTranscript.caughtUp, lines[0]])
        #expect(await waitUntil { m.sessions.count == 1 })
        #expect(m.state == .watching)
    }

    @Test func reconnectResumesFromLastSeq() async {
        let remote1 = FakeAgentRemote()
        let (m, _) = makeMonitor(remote1)
        #expect(await waitUntil { remote1.lastStream != nil })
        remote1.lastStream!.emitLines([GoldenTranscript.heartbeat] + Array(lines[0..<8]) + [GoldenTranscript.caughtUp])
        #expect(await waitUntil { m.lastSeq == 8 })
        remote1.lastStream!.finish()
        #expect(await waitUntil { m.state == .disconnected })
        #expect(m.sessions.count == 1, "state survives a dropped connection")

        let remote2 = FakeAgentRemote()
        m.attach(remote: remote2, claudePath: nil)
        #expect(await waitUntil { remote2.lastStream != nil })
        #expect(remote2.lastStream?.command == "~/.shuai/bin/shuai-agent watch --since 8")
    }

    @Test func missingAgentMeansNotInstalled() async {
        let remote = FakeAgentRemote()
        let (m, _) = makeMonitor(remote)
        #expect(await waitUntil { remote.lastStream != nil })
        remote.lastStream!.emitStderr("sh: 1: /home/u/.shuai/bin/shuai-agent: not found\n")
        remote.lastStream!.exit(127)
        remote.lastStream!.finish()
        #expect(await waitUntil { m.state == .notInstalled })
    }

    @Test func otherFailureIsReported() async {
        let remote = FakeAgentRemote()
        let (m, _) = makeMonitor(remote)
        #expect(await waitUntil { remote.lastStream != nil })
        remote.lastStream!.emitStderr("boom\n")
        remote.lastStream!.exit(2)
        remote.lastStream!.finish()
        #expect(await waitUntil { if case .failed = m.state { true } else { false } })
    }

    @Test func openingTheStreamCanFail() async {
        let remote = FakeAgentRemote()
        remote.streamError = NSError(domain: "x", code: 1)
        let (m, _) = makeMonitor(remote)
        #expect(await waitUntil { if case .failed = m.state { true } else { false } })
    }

    @Test func detachStopsWatching() async {
        let remote = FakeAgentRemote()
        let (m, _) = makeMonitor(remote)
        #expect(await waitUntil { remote.lastStream != nil })
        m.detach()
        #expect(await waitUntil { remote.lastStream!.closeCalls.get >= 1 })
        #expect(m.state == .disconnected)
    }

    @Test func paneBadgeProvider() async {
        let remote = FakeAgentRemote()
        let (m, _) = makeMonitor(remote)
        #expect(await waitUntil { remote.lastStream != nil })
        remote.lastStream!.emitLines([GoldenTranscript.caughtUp] + Array(lines[0..<4]))
        #expect(await waitUntil { m.lastSeq == 4 })
        let provider: PaneBadgeProvider = m
        #expect(provider.badge(host: GoldenTranscript.host, pane: "%0") == .needsPermission)
        #expect(provider.badge(host: GoldenTranscript.host, pane: "%7") == nil)
        #expect(provider.badge(host: "other", pane: "%0") == nil)
    }

    @Test func periodicReconcileUsesClaudeAgents() async {
        let remote = FakeAgentRemote { cmd in
            cmd.contains("agents --json")
                ? .ok(#"[{"sessionId":"\#(GoldenTranscript.sessionID)","status":"idle"}]"#) : .ok()
        }
        let (m, _) = makeMonitor(remote, claude: "/home/u/.local/bin/claude", reconcile: .milliseconds(30))
        #expect(await waitUntil { remote.lastStream != nil })
        // Working (a Stop was lost): seq 1-3 only.
        remote.lastStream!.emitLines([GoldenTranscript.caughtUp] + Array(lines[0..<3]))
        #expect(await waitUntil { remote.ran(containing: "agents --json").isEmpty == false })
        #expect(remote.ran(containing: "agents --json").first == "/home/u/.local/bin/claude agents --json")
        #expect(await waitUntil { m.sessions.first?.state == .done })
    }

    @Test func noReconcileWithoutClaudePath() async {
        let remote = FakeAgentRemote()
        let (_, _) = makeMonitor(remote, claude: nil, reconcile: .milliseconds(10))
        try? await Task.sleep(for: .milliseconds(100))
        #expect(remote.ran(containing: "agents").isEmpty)
    }
}

@Suite("AgentMonitor permission flow")
@MainActor
struct AgentMonitorPermissionTests {
    let lines = GoldenTranscript.lines
    let req = GoldenTranscript.firstRequest

    private func pending() async -> (AgentMonitor, FakeAgentRemote) {
        let remote = FakeAgentRemote()
        let (m, _) = makeMonitor(remote)
        _ = await waitUntil { remote.lastStream != nil }
        remote.lastStream!.emitLines([GoldenTranscript.caughtUp] + Array(lines[0..<4]))
        _ = await waitUntil { m.pendingPermissions.count == 1 }
        return (m, remote)
    }

    @Test func respondRunsTheCommandWithOptimisticState() async {
        let (m, remote) = await pending()
        #expect(m.pendingPermissions.first?.request.requestId == req)
        let release = Locked<CheckedContinuation<Void, Never>?>(nil)
        remote.gate.with {
            $0 = { await withCheckedContinuation { c in release.with { $0 = c } } }
        }
        let task = Task { await m.respond(requestId: req, allow: true) }
        #expect(await waitUntil { m.answering[req] == .allowing })
        #expect(remote.ran(containing: "respond").first == "~/.shuai/bin/shuai-agent respond \(req) allow")
        _ = await waitUntil { release.get != nil }
        release.get?.resume()
        #expect(await task.value == .sent)
        // The card stays "answering" until the agent reports it resolved.
        #expect(m.answering[req] == .allowing)
        remote.lastStream!.emitLines([lines[4], lines[5]])
        #expect(await waitUntil { m.pendingPermissions.isEmpty })
        #expect(m.answering[req] == nil)
    }

    @Test func denyWithMessage() async {
        let (m, remote) = await pending()
        let r = await m.respond(requestId: req, allow: false, message: "not now")
        #expect(r == .sent)
        #expect(remote.ran(containing: "respond").first == "~/.shuai/bin/shuai-agent respond \(req) deny --message='not now'")
        #expect(m.answering[req] == .denying)
    }

    @Test func failureRevertsOptimisticState() async {
        let (m, remote) = await pending()
        remote.setHandler { _ in .fail(1, "no space left") }
        let r = await m.respond(requestId: req, allow: true)
        #expect(r == .failed("no space left"))
        #expect(m.answering[req] == nil)
        #expect(m.pendingPermissions.count == 1, "the card is still answerable")
        #expect(m.lastError != nil)
    }

    @Test func resolvedLocallyFirstWins() async {
        let (m, remote) = await pending()
        remote.lastStream!.emitLines([lines[4], lines[5]])
        #expect(await waitUntil { m.pendingPermissions.isEmpty })
        let r = await m.respond(requestId: req, allow: true)
        #expect(r == .alreadyResolved)
        #expect(remote.ran(containing: "respond").isEmpty)
        #expect(m.lastError == nil)
    }

    @Test func resolvedWhileSendingIsNotAnError() async {
        let (m, remote) = await pending()
        remote.setHandler { _ in .fail(1, "late") }
        remote.gate.with {
            $0 = {
                remote.lastStream!.emitLines([GoldenTranscript.lines[4], GoldenTranscript.lines[5]])
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        let r = await m.respond(requestId: req, allow: true)
        #expect(r == .alreadyResolved)
        #expect(m.answering[req] == nil)
        #expect(m.lastError == nil)
    }

    @Test func invalidRequestIdIsRejectedWithoutExec() async {
        let (m, remote) = await pending()
        let r = await m.respond(requestId: "a;b", allow: true)
        if case .failed = r {} else { Issue.record("expected failure, got \(r)") }
        #expect(remote.ran(containing: "respond").isEmpty)
    }

    @Test func respondWithoutAConnectionFails() async {
        let (m, _) = await pending()
        m.detach()
        let r = await m.respond(requestId: req, allow: true)
        if case .failed = r {} else { Issue.record("expected failure, got \(r)") }
    }
}
