import Foundation
import Testing
import ShuaiCore
@testable import ShuaiApp

private let doctorJSON = """
{"version":"\(expectedAgentVersion())","protocol":1,"os":"linux","arch":"x86_64","binary":"/home/u/.shuai/bin/shuai-agent",
"state_dir":"/home/u/.shuai","state_dir_writable":true,"last_seq":null,"app_present":false,
"claude_path":"/home/u/.local/bin/claude","plugin_installed":true,"tmux_version":"tmux 3.4","tmux_allow_passthrough":null,"ntfy_configured":false}
"""

private func probeText(
    arch: String = "x86_64", os: String = "Linux", claude: String? = "/home/u/.local/bin/claude",
    tmux: String? = "tmux 3.4", agent: String = "", plugin: Bool = false, codex: String? = nil,
    codexNotify: String = "", tmuxBlock: Bool = false
) -> String {
    """
    welcome banner
    __SHUAI_PROBE_BEGIN__
    uname_s=\(os)
    uname_m=\(arch)
    home=/home/u
    shell=/bin/bash
    claude_path=\(claude ?? "")
    codex_path=\(codex ?? "")
    tmux_version=\(tmux ?? "")
    agent_version=\(agent)
    plugin_installed=\(plugin ? 1 : 0)
    codex_notify=\(codexNotify)
    tmux_conf_block=\(tmuxBlock ? 1 : 0)
    __SHUAI_PROBE_END__
    """
}

/// Remote that answers like a healthy host; `overrides` match by substring first.
private func host(
    probe: String, overrides: [(String, RemoteExecOutput)] = [], files: [String: String] = [:]
) -> FakeAgentRemote {
    FakeAgentRemote { cmd in
        if cmd.contains("__SHUAI_PROBE_BEGIN__") { return .ok(probe) }
        for (needle, out) in overrides where cmd.contains(needle) { return out }
        if cmd.hasPrefix("test -e ") {
            let path = String(cmd.dropFirst(8)).trimmingCharacters(in: CharacterSet(charactersIn: "'"))
            return files[path] != nil ? .ok() : .fail(1, "")
        }
        if cmd.hasPrefix("cat ") {
            let path = String(cmd.dropFirst(4)).trimmingCharacters(in: CharacterSet(charactersIn: "'"))
            if let f = files[path] { return .ok(f) }
            return .fail(1, "No such file")
        }
        if cmd.hasSuffix("doctor") { return .ok(doctorJSON) }
        return .ok()
    }
}

private func installer(_ remote: FakeAgentRemote, binaries: AgentBinaryProviding = FakeBinaries()) -> AgentInstaller {
    AgentInstaller(remote: remote, binaries: binaries)
}

private func steps(_ r: InstallReport) -> [String] { r.steps.map(\.title) }

@Suite("AgentInstaller")
struct AgentInstallerTests {
    @Test func probeRunsTheScriptThroughSh() async throws {
        let remote = host(probe: probeText())
        let p = try await installer(remote).probe()
        #expect(p.unameM == "x86_64")
        #expect(p.claudePath == "/home/u/.local/bin/claude")
        let cmd = remote.commands.get[0]
        #expect(cmd.hasPrefix("sh -c '"))
        #expect(cmd.contains("__SHUAI_PROBE_BEGIN__"))
    }

    @Test func probeFailureIsThrown() async {
        let remote = FakeAgentRemote { _ in .fail(255, "ssh: broken") }
        await #expect(throws: AgentInstallError.self) { try await installer(remote).probe() }
    }

    @Test func freshHostFullInstall() async throws {
        let remote = host(probe: probeText())
        let inst = installer(remote)
        let probe = try await inst.probe()
        let log = Locked<[InstallProgress]>([])
        let report = await inst.run(
            probe: probe, options: InstallOptions(pluginSource: .local), progress: { p in log.with { $0.append(p) } })
        #expect(report.ok)
        #expect(report.doctor?.pluginInstalled == true)
        #expect(report.doctor?.version == expectedAgentVersion())

        // Agent: uploaded beside the final path (a running binary cannot be overwritten), then moved.
        let up = remote.uploads.get
        #expect(up[0] == UploadRecord(
            path: "/home/u/.shuai/bin/shuai-agent.new",
            data: Data("ELF-x86_64-unknown-linux-musl".utf8), mode: 0o755))
        let cmds = remote.commands.get
        #expect(cmds.contains("mkdir -p /home/u/.shuai/bin"))
        #expect(cmds.contains("mv -f /home/u/.shuai/bin/shuai-agent.new /home/u/.shuai/bin/shuai-agent"))
        #expect(cmds.contains("chmod 755 /home/u/.shuai/bin/shuai-agent"))

        // Plugin: local marketplace (works while the GitHub repo is private).
        let uploaded = Set(up.map(\.path))
        #expect(uploaded.contains("/home/u/.shuai/plugin-marketplace/.claude-plugin/marketplace.json"))
        #expect(uploaded.contains("/home/u/.shuai/plugin-marketplace/plugin/hooks/hooks.json"))
        #expect(uploaded.contains("/home/u/.shuai/plugin-marketplace/plugin/.claude-plugin/plugin.json"))
        #expect(cmds.contains("/home/u/.local/bin/claude plugin marketplace add /home/u/.shuai/plugin-marketplace"))
        #expect(cmds.contains("/home/u/.local/bin/claude plugin install shuai@shuai"))
        #expect(!cmds.contains { $0.contains("moilk/shuai") }, "no GitHub access needed")

        // tmux: idempotent append, then reload only when a server is running.
        #expect(remote.ran(containing: "grep -qF '# >>> shuai >>>' ~/.tmux.conf").count == 1)
        #expect(remote.ran(containing: "tmux source-file").count == 1)
        #expect(remote.ran(containing: "tmux source-file")[0].contains("has-session"))
        #expect(cmds.last == "/home/u/.shuai/bin/shuai-agent doctor")

        // Progress is reported per step, running then done.
        let l = log.get
        #expect(l.first?.status == .running)
        #expect(l.last?.status == .done)
        #expect(Set(l.map(\.stepIndex)).count == report.steps.count)
    }

    @Test func alreadyInstalledHostOnlyRunsDoctor() async throws {
        let remote = host(probe: probeText(agent: "shuai-agent \(expectedAgentVersion())", plugin: true, tmuxBlock: true))
        let inst = installer(remote)
        let report = await inst.run(probe: try await inst.probe())
        #expect(report.ok)
        #expect(remote.uploads.get.isEmpty)
        #expect(steps(report) == ["Run diagnostics"])
        // Re-running is the same.
        let again = await inst.run(probe: try await inst.probe())
        #expect(steps(again) == ["Run diagnostics"])
    }

    @Test func dryRunNeverMutates() async throws {
        let remote = host(probe: probeText())
        let inst = installer(remote)
        let probe = try await inst.probe()
        let before = remote.commands.get.count
        let report = await inst.run(probe: probe, options: InstallOptions(dryRun: true))
        #expect(report.ok)
        #expect(report.dryRun)
        #expect(remote.uploads.get.isEmpty)
        #expect(remote.commands.get.count == before, "dry run issues no commands at all")
        #expect(report.steps.allSatisfy { $0.status == .wouldRun })
        #expect(report.steps.count >= 5)
        #expect(report.steps.allSatisfy { !$0.log.isEmpty })
    }

    @Test func noClaudeMergesSettingsJson() async throws {
        let existing = #"{"model":"opus","hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo mine"}]}]}}"#
        let remote = host(probe: probeText(claude: nil), files: ["/home/u/.claude/settings.json": existing])
        let inst = installer(remote)
        let report = await inst.run(probe: try await inst.probe())
        #expect(report.ok)
        let merged = remote.uploads.get.first { $0.path == "/home/u/.claude/settings.json.shuai-tmp" }
        let text = String(decoding: merged?.data ?? Data(), as: UTF8.self)
        #expect(text.contains("\"model\""))
        #expect(text.contains("echo mine"))
        #expect(text.contains("/home/u/.shuai/bin/shuai-agent"))
        #expect(remote.ran(containing: "settings.json.shuai-bak").isEmpty == false)
        #expect(remote.ran(containing: "plugin marketplace").isEmpty)
    }

    @Test func settingsAreReplacedAtomicallyAndTheBackupIsNeverOverwritten() async throws {
        let remote = host(
            probe: probeText(claude: nil), files: ["/home/u/.claude/settings.json": "{}"])
        let inst = installer(remote)
        _ = await inst.run(probe: try await inst.probe())
        let cmds = remote.commands.get
        // Written beside the target, then renamed over it.
        #expect(remote.uploads.get.contains { $0.path == "/home/u/.claude/settings.json.shuai-tmp" })
        #expect(!remote.uploads.get.contains { $0.path == "/home/u/.claude/settings.json" })
        let replace = cmds.first { $0.contains("mv -f /home/u/.claude/settings.json.shuai-tmp") }
        #expect(replace?.contains("[ -L /home/u/.claude/settings.json ]") == true, "symlinks are written through")
        // The first backup wins: a second install must not replace the original copy.
        let backup = cmds.first { $0.contains("settings.json.shuai-bak") && $0.contains("cp ") }
        #expect(backup == "[ -e /home/u/.claude/settings.json.shuai-bak ] || cp /home/u/.claude/settings.json /home/u/.claude/settings.json.shuai-bak")
        // Backup happens before the replacement.
        let iBackup = cmds.firstIndex { $0 == backup }
        let iReplace = cmds.firstIndex { $0 == replace }
        #expect(iBackup != nil && iReplace != nil && iBackup! < iReplace!)
    }

    @Test func hostileHomeIsQuotedInEveryCommand() async throws {
        let probe = probeText(claude: nil).replacingOccurrences(of: "home=/home/u", with: "home=/ho me/it's $x `y`")
        let remote = host(probe: probe)
        let inst = installer(remote)
        let report = await inst.run(probe: try await inst.probe())
        #expect(report.ok)
        for c in remote.commands.get where c.contains("ho me") {
            // every occurrence of the home must sit inside single quotes ('it'\\''s' form)
            #expect(c.contains("'/ho me/it'\\''s $x `y`"), "unquoted hostile path in: \(c)")
        }
        #expect(remote.commands.get.contains { $0.contains("ho me") })
    }

    @Test func noClaudeAndNoSettingsFileCreatesIt() async throws {
        let remote = host(probe: probeText(claude: nil))
        let inst = installer(remote)
        let report = await inst.run(probe: try await inst.probe())
        #expect(report.ok)
        #expect(remote.uploads.get.contains { $0.path == "/home/u/.claude/settings.json.shuai-tmp" })
        #expect(remote.commands.get.contains("mkdir -p /home/u/.claude"))
    }

    @Test func pluginCliFailureFallsBackToSettingsMerge() async throws {
        let remote = host(
            probe: probeText(),
            overrides: [("plugin marketplace add", .fail(1, "boom")), ("plugin install", .fail(1, "boom"))])
        let inst = installer(remote)
        let report = await inst.run(probe: try await inst.probe())
        #expect(report.ok)
        #expect(report.warnings.contains { $0.contains("settings.json") })
        #expect(remote.uploads.get.contains { $0.path == "/home/u/.claude/settings.json.shuai-tmp" })
    }

    @Test func existingMarketplaceRegistrationDoesNotBlockInstall() async throws {
        let remote = host(
            probe: probeText(), overrides: [("plugin marketplace add", .fail(1, "already exists"))])
        let inst = installer(remote)
        let report = await inst.run(probe: try await inst.probe())
        #expect(report.ok)
        #expect(!remote.uploads.get.contains { $0.path.hasSuffix("settings.json") })
    }

    @Test func defaultPluginSourceIsTheGitHubMarketplace() async throws {
        let remote = host(probe: probeText())
        let inst = installer(remote)
        let report = await inst.run(probe: try await inst.probe())
        #expect(report.ok)
        let cmds = remote.commands.get
        #expect(cmds.contains { $0.hasSuffix("plugin marketplace add moilk/shuai") })
        #expect(cmds.contains { $0.hasSuffix("plugin install shuai@shuai") })
        #expect(!cmds.contains { $0.contains(".shuai/plugin-marketplace") }, "local fallback unused")
        #expect(!remote.uploads.get.contains { $0.path.contains("plugin-marketplace") })
    }

    @Test func githubPluginSourceFallsBackToLocalWhenPrivate() async throws {
        let remote = host(
            probe: probeText(), overrides: [("marketplace add moilk/shuai", .fail(1, "repository not found"))])
        let inst = installer(remote)
        let report = await inst.run(probe: try await inst.probe(), options: InstallOptions(pluginSource: .github))
        #expect(report.ok)
        let cmds = remote.commands.get
        let gh = cmds.firstIndex { $0.contains("marketplace add moilk/shuai") }
        let local = cmds.firstIndex { $0.contains("marketplace add /home/u/.shuai/plugin-marketplace") }
        #expect(gh != nil && local != nil && gh! < local!)
    }

    @Test func codexConflictIsSurfacedNotOverwritten() async throws {
        let conflict = #"notify = ["/usr/local/bin/other-notify"]"#
        let remote = host(probe: probeText(codex: "/usr/bin/codex", codexNotify: conflict))
        let inst = installer(remote)
        let report = await inst.run(probe: try await inst.probe())
        #expect(report.ok, "a pending decision is not a failure")
        #expect(report.conflicts == [CodexConflict(configPath: "~/.codex/config.toml", existing: conflict)])
        #expect(report.steps.contains { $0.status == .needsDecision })
        #expect(!remote.uploads.get.contains { $0.path.contains("config.toml") })
    }

    @Test func codexConflictCanBeReplaced() async throws {
        let toml = "notify = [\"/usr/local/bin/other\"]\nmodel = \"x\"\n"
        let remote = host(
            probe: probeText(codex: "/usr/bin/codex", codexNotify: "notify = [\"/usr/local/bin/other\"]"),
            files: ["/home/u/.codex/config.toml": toml])
        let inst = installer(remote)
        let report = await inst.run(
            probe: try await inst.probe(), options: InstallOptions(codexConflict: .replace))
        #expect(report.ok)
        #expect(report.conflicts.isEmpty)
        let up = remote.uploads.get.first { $0.path == "/home/u/.codex/config.toml.shuai-tmp" }
        #expect(String(decoding: up?.data ?? Data(), as: UTF8.self)
            == "notify = [\"/home/u/.shuai/bin/shuai-agent\", \"codex-notify\"]\nmodel = \"x\"\n")
    }

    @Test func codexWithoutNotifyGetsConfigured() async throws {
        let remote = host(probe: probeText(codex: "/usr/bin/codex"), files: ["/home/u/.codex/config.toml": "model = \"x\"\n"])
        let inst = installer(remote)
        let report = await inst.run(probe: try await inst.probe())
        #expect(report.ok)
        let up = remote.uploads.get.first { $0.path == "/home/u/.codex/config.toml.shuai-tmp" }
        let upText = String(decoding: up?.data ?? Data(), as: UTF8.self)
        #expect(upText.hasPrefix("notify = [\"/home/u/.shuai/bin/shuai-agent\", \"codex-notify\"]\n"))
    }

    @Test func missingBinaryStopsTheInstall() async throws {
        let remote = host(probe: probeText(arch: "aarch64"))
        let inst = installer(remote, binaries: FakeBinaries(available: ["x86_64-unknown-linux-musl"]))
        let report = await inst.run(probe: try await inst.probe())
        #expect(!report.ok)
        #expect(report.steps.contains { if case .failed = $0.status { true } else { false } })
        #expect(remote.ran(containing: "plugin install").isEmpty, "later steps are skipped after a failure")
        #expect(report.steps.last?.status == .skipped)
    }

    @Test func uploadErrorFailsTheStep() async throws {
        let remote = host(probe: probeText())
        remote.uploadError = NSError(domain: "x", code: 1, userInfo: [NSLocalizedDescriptionKey: "disk full"])
        let inst = installer(remote)
        let report = await inst.run(probe: try await inst.probe())
        #expect(!report.ok)
        #expect(report.steps.contains { $0.status == .failed("disk full") })
    }

    @Test func unsupportedPlatform() async throws {
        let remote = host(probe: probeText(arch: "riscv64"))
        let inst = installer(remote)
        let report = await inst.run(probe: try await inst.probe())
        #expect(!report.ok)
        #expect(remote.uploads.get.isEmpty)
    }

    @Test func uninstallRemovesEverythingWeAdded() async throws {
        let merged = #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"x /home/u/.shuai/bin/shuai-agent hook Stop"}]}]}}"#
        let remote = host(
            probe: probeText(agent: "shuai-agent 0.1.0", plugin: true, codex: "/usr/bin/codex",
                             codexNotify: "notify = [\"/home/u/.shuai/bin/shuai-agent\", \"codex-notify\"]", tmuxBlock: true),
            files: ["/home/u/.claude/settings.json": merged,
                    "/home/u/.codex/config.toml": "notify = [\"/home/u/.shuai/bin/shuai-agent\", \"codex-notify\"]\nmodel = 1\n"])
        let inst = installer(remote)
        let report = await inst.uninstall(probe: try await inst.probe())
        #expect(report.ok)
        let cmds = remote.commands.get
        #expect(cmds.contains("/home/u/.local/bin/claude plugin uninstall shuai@shuai"))
        #expect(cmds.contains("/home/u/.local/bin/claude plugin marketplace remove shuai"))
        #expect(cmds.contains { $0.contains("awk") && $0.contains("~/.tmux.conf") })
        // A running agent (the app's own monitor) would recreate its state dir after the rm: stop it first,
        // then remove the whole ~/.shuai (binary, plugin copy and runtime state), plus Claude Code's orphaned plugin cache for our marketplace, so nothing is left behind.
        #expect(cmds.contains("pkill -f '[.]shuai/bin/shuai-agent'; sleep 0.3; rm -rf /home/u/.shuai /home/u/.claude/plugins/cache/shuai"))
        let s = remote.uploads.get.first { $0.path == "/home/u/.claude/settings.json.shuai-tmp" }
        let sText = String(decoding: s?.data ?? Data(), as: UTF8.self)
        #expect(!sText.contains("shuai-agent"))
        let c = remote.uploads.get.first { $0.path == "/home/u/.codex/config.toml.shuai-tmp" }
        #expect(String(decoding: c?.data ?? Data(), as: UTF8.self) == "model = 1\n")
    }

    @Test func uninstallDryRunTouchesNothing() async throws {
        let remote = host(probe: probeText(agent: "shuai-agent 0.1.0", plugin: true, tmuxBlock: true))
        let inst = installer(remote)
        let probe = try await inst.probe()
        let before = remote.commands.get.count
        let report = await inst.uninstall(probe: probe, options: InstallOptions(dryRun: true))
        #expect(report.ok)
        #expect(remote.commands.get.count == before)
        #expect(remote.uploads.get.isEmpty)
    }

    @Test func installWritesTheNotificationConfigBeforeTheDoctorRuns() async throws {
        let remote = host(probe: probeText())
        let inst = installer(remote)
        let probe = try await inst.probe()
        let options = InstallOptions(pluginSource: .local, agentConfigToml: "host_id = \"x\"\n")
        let report = await inst.run(probe: probe, options: options)
        #expect(report.ok)
        let t = steps(report)
        let cfg = try #require(t.firstIndex(of: "Write notification settings"))
        let doc = try #require(t.firstIndex(of: "Run diagnostics"))
        #expect(cfg < doc)
        let up = try #require(remote.uploads.get.first { $0.path == "/home/u/.shuai/config.toml.tmp" })
        #expect(up.mode == 0o600)
        #expect(String(decoding: up.data, as: UTF8.self) == "host_id = \"x\"\n")
        #expect(remote.commands.get.contains("mv -f /home/u/.shuai/config.toml.tmp /home/u/.shuai/config.toml"))
    }

    @Test func installWithoutConfigWritesNone() async throws {
        let remote = host(probe: probeText())
        let inst = installer(remote)
        let report = await inst.run(probe: try await inst.probe(), options: InstallOptions(pluginSource: .local))
        #expect(!steps(report).contains("Write notification settings"))
        #expect(!remote.uploads.get.contains { $0.path.hasSuffix("config.toml.tmp") })
    }

    @Test func dryRunDoesNotWriteTheConfig() async throws {
        let remote = host(probe: probeText())
        let inst = installer(remote)
        let report = await inst.run(
            probe: try await inst.probe(), options: InstallOptions(dryRun: true, agentConfigToml: "x"))
        #expect(steps(report).contains("Write notification settings"))
        #expect(remote.uploads.get.isEmpty)
    }

    @Test func doctorReportDecodes() throws {
        let d = try DoctorReport.decode(doctorJSON)
        #expect(d.os == "linux")
        #expect(d.stateDirWritable)
        #expect(d.lastSeq == nil)
        #expect(d.tmuxVersion == "tmux 3.4")
        #expect(throws: (any Error).self) { try DoctorReport.decode("not json") }
    }
}
