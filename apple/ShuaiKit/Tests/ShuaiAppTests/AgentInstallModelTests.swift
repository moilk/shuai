import Foundation
import Testing
import ShuaiCore
@testable import ShuaiApp

private func probe(claude: Bool = true, codexNotify: String = "") -> String {
    """
    __SHUAI_PROBE_BEGIN__
    uname_s=Linux
    uname_m=x86_64
    home=/home/u
    claude_path=\(claude ? "/home/u/.local/bin/claude" : "")
    codex_path=\(codexNotify.isEmpty ? "" : "/usr/bin/codex")
    codex_notify=\(codexNotify)
    tmux_version=tmux 3.4
    __SHUAI_PROBE_END__
    """
}

@Suite("AgentInstallModel")
@MainActor
struct AgentInstallModelTests {
    private func model(_ remote: FakeAgentRemote) -> AgentInstallModel {
        AgentInstallModel(installer: AgentInstaller(remote: remote, binaries: FakeBinaries()))
    }

    @Test func inspectProbesAndPreviewsWithoutChangingTheHost() async {
        let remote = FakeAgentRemote { cmd in cmd.contains("__SHUAI_PROBE_BEGIN__") ? .ok(probe()) : .ok("{}") }
        let m = model(remote)
        await m.inspect()
        #expect(m.phase == .ready)
        #expect(m.probe?.unameM == "x86_64")
        #expect(m.preview.count >= 5)
        #expect(m.preview.allSatisfy { $0.status == .wouldRun })
        #expect(remote.uploads.get.isEmpty)
        #expect(remote.commands.get.count == 1, "only the probe ran")
    }

    @Test func installRunsAndLogsProgressInOrder() async {
        let remote = FakeAgentRemote { cmd in
            cmd.contains("__SHUAI_PROBE_BEGIN__") ? .ok(probe()) : .ok("{}")
        }
        let m = model(remote)
        await m.inspect()
        await m.install()
        #expect(m.phase == .finished)
        #expect(m.report?.dryRun == false)
        #expect(m.report?.ok == false || m.report?.ok == true)
        let idx = m.log.map(\.stepIndex)
        #expect(idx == idx.sorted())
        #expect(m.log.first?.status == .running)
        #expect(!remote.uploads.get.isEmpty)
    }

    @Test func probeFailureIsShown() async {
        let remote = FakeAgentRemote { _ in .fail(255, "Connection reset") }
        let m = model(remote)
        await m.inspect()
        if case .failed(let msg) = m.phase { #expect(msg.contains("Connection reset")) } else { Issue.record("expected failure") }
    }

    @Test func codexConflictCanBeResolvedAndRerun() async {
        let existing = #"notify = ["/usr/bin/other"]"#
        let remote = FakeAgentRemote { cmd in
            if cmd.contains("__SHUAI_PROBE_BEGIN__") { return .ok(probe(codexNotify: existing)) }
            if cmd.hasPrefix("cat ") { return .ok("model = 1\n") }
            return .ok("{}")
        }
        let m = model(remote)
        await m.inspect()
        await m.install()
        #expect(m.report?.conflicts.count == 1)
        #expect(!remote.uploads.get.contains { $0.path.hasSuffix("config.toml") })
        m.codexResolution = .replace
        await m.install()
        #expect(m.report?.conflicts.isEmpty == true)
        #expect(remote.uploads.get.contains { $0.path.hasSuffix("config.toml") })
    }
}
