#if DEBUG
import Foundation
import Observation
import ShuaiApp
import ShuaiCore
import SwiftUI

/// What the fixture host's fake agent was asked to do (read by UI tests through `agent-fixture-log`).
@MainActor @Observable
final class FixtureLog {
    static let shared = FixtureLog()
    private(set) var lines: [String] = []
    func add(_ line: String) { lines.append(line) }
}

/// `-debugAgentFixture`: a fake `AgentRemote` that plays the recorded real Claude Code 2.1.288
/// transcript (core/shuai-agent/tests/fixtures/e2e-claude-2.1.288.jsonl, bundled) through the real
/// `AgentMonitor`/tracker. The host presents as `e2e-host` (the transcript's hostname), so the
/// profile-id <-> hostname mapping of `AgentHub` is exercised too.
///
/// Script: probe answers; the watch stream sends heartbeat + caught_up, then (live) events 1-4 up to
/// the first permission request. `shuai-agent respond` is recorded; the "agent" then resolves it and
/// finishes the turn (events 6-8), like Claude would after the answer.
final class FixtureAgentRemote: AgentRemote, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<AgentStreamEvent>.Continuation?
    private let lines: [String]

    init() {
        let url = Bundle.main.url(forResource: "e2e-claude-2.1.288", withExtension: "jsonl")
        let text = url.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        lines = text.split(separator: "\n").map(String.init)
    }

    func exec(_ command: String) async throws -> RemoteExecOutput {
        if command == AgentHostProbe.command {
            return .ok("host=e2e-host\nagent=shuai-agent \(expectedAgentVersion())\n")
        }
        if command.contains("respond") {
            await MainActor.run { FixtureLog.shared.add(command) }
            Task {
                try? await Task.sleep(for: .milliseconds(300))
                self.emit(Array(self.lines[5 ..< min(8, self.lines.count)]))
            }
        }
        return .ok()
    }

    func execStream(_ command: String) async throws -> AgentStream {
        let (events, cont) = AsyncStream<AgentStreamEvent>.makeStream()
        setContinuation(cont)
        cont.yield(.stdout(Data(("{\"type\":\"heartbeat\"}\n{\"type\":\"caught_up\"}\n").utf8)))
        Task {
            try? await Task.sleep(for: .seconds(1))
            self.emit(Array(self.lines[0 ..< min(4, self.lines.count)]))
        }
        return FixtureStream(events: events)
    }

    func upload(_ data: Data, to path: String, mode: UInt32) async throws {}

    private func setContinuation(_ c: AsyncStream<AgentStreamEvent>.Continuation) {
        lock.lock(); continuation = c; lock.unlock()
    }

    private func emit(_ batch: [String]) {
        lock.lock(); let c = continuation; lock.unlock()
        c?.yield(.stdout(Data((batch.joined(separator: "\n") + "\n").utf8)))
    }
}

private struct FixtureStream: AgentStream {
    let events: AsyncStream<AgentStreamEvent>
    func close() async {}
}

/// Invisible element whose value lists the recorded `respond` commands.
struct FixtureLogProbe: View {
    var body: some View {
        let log = FixtureLog.shared
        Color.clear.frame(width: 4, height: 4)
            .accessibilityElement()
            .accessibilityLabel("agent-fixture-log")
            .accessibilityValue(log.lines.joined(separator: "\n"))
            .accessibilityIdentifier("agent-fixture-log")
    }
}
#endif
