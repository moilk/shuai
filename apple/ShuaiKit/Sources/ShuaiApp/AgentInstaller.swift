import Foundation
import ShuaiCore

// "Enable AI integration on this host": probe -> plan (Rust, `installPlan`) -> execute over SSH.
//
// Plugin install path. Default (`.github`): `claude plugin marketplace add moilk/shuai` +
// `claude plugin install shuai@shuai` (the repo is public). If that fails (offline host, no GitHub
// access) it falls back to a LOCAL marketplace: the app embeds the repo's marketplace + plugin files (Rust `plugin_bundle()`),
// uploads them to `~/.shuai/plugin-marketplace` and runs
//   claude plugin marketplace add ~/.shuai/plugin-marketplace && claude plugin install shuai@shuai
// (verified: `claude plugin marketplace add` accepts a local path). `PluginSource.github` tries the
// GitHub marketplace first and falls back to the local one. If the claude CLI is missing or both
// fail, the hook entries are merged into ~/.claude/settings.json (never clobbering the user's own
// hooks; a `.shuai-bak` copy is kept).

public enum PluginSource: Sendable { case local, github }
public enum CodexConflictResolution: Sendable {
    /// Report the conflict and leave the config alone (the UI then asks).
    case skip
    /// Replace the user's `notify` with ours.
    case replace
}

public struct InstallOptions: Sendable {
    public var dryRun: Bool
    public var pluginSource: PluginSource
    public var codexConflict: CodexConflictResolution

    public init(dryRun: Bool = false, pluginSource: PluginSource = .github, codexConflict: CodexConflictResolution = .skip) {
        self.dryRun = dryRun
        self.pluginSource = pluginSource
        self.codexConflict = codexConflict
    }
}

public enum StepStatus: Equatable, Sendable {
    case pending, running, done, skipped
    case failed(String)
    /// Dry run: this is what would happen.
    case wouldRun
    /// Needs the user (a Codex `notify` that is not ours).
    case needsDecision
}

public struct StepOutcome: Equatable, Sendable {
    public var index: Int
    public var title: String
    public var status: StepStatus
    public var log: [String]
}

public struct InstallProgress: Equatable, Sendable {
    public var stepIndex: Int
    public var title: String
    public var status: StepStatus
    /// A log line produced by the step (status stays `.running`).
    public var message: String?
}

public struct CodexConflict: Equatable, Sendable {
    public var configPath: String
    public var existing: String
}

public struct InstallReport: Sendable {
    public var steps: [StepOutcome]
    public var dryRun: Bool
    public var conflicts: [CodexConflict]
    public var warnings: [String]
    public var doctor: DoctorReport?
    public var ok: Bool { !steps.contains { if case .failed = $0.status { true } else { false } } }
}

public enum AgentInstallError: Error, LocalizedError, Equatable {
    case probeFailed(String)
    case commandFailed(String)

    public var errorDescription: String? {
        switch self {
        case .probeFailed(let m): "Could not inspect the host: \(m)"
        case .commandFailed(let m): m
        }
    }
}

/// `shuai-agent doctor` output.
public struct DoctorReport: Decodable, Equatable, Sendable {
    public var version: String
    public var protocolVersion: Int
    public var os: String
    public var arch: String
    public var binary: String?
    public var stateDir: String
    public var stateDirWritable: Bool
    public var lastSeq: UInt64?
    public var appPresent: Bool
    public var claudePath: String?
    public var pluginInstalled: Bool
    public var tmuxVersion: String?
    public var tmuxAllowPassthrough: String?
    public var ntfyConfigured: Bool

    enum CodingKeys: String, CodingKey {
        case version, os, arch, binary
        case protocolVersion = "protocol"
        case stateDir = "state_dir"
        case stateDirWritable = "state_dir_writable"
        case lastSeq = "last_seq"
        case appPresent = "app_present"
        case claudePath = "claude_path"
        case pluginInstalled = "plugin_installed"
        case tmuxVersion = "tmux_version"
        case tmuxAllowPassthrough = "tmux_allow_passthrough"
        case ntfyConfigured = "ntfy_configured"
    }

    public static func decode(_ text: String) throws -> DoctorReport {
        try JSONDecoder().decode(DoctorReport.self, from: Data(text.utf8))
    }
}

public struct AgentInstaller: Sendable {
    private let remote: AgentRemote
    private let binaries: AgentBinaryProviding
    private let expectedVersion: String

    public init(remote: AgentRemote, binaries: AgentBinaryProviding, expectedVersion: String = expectedAgentVersion()) {
        self.remote = remote
        self.binaries = binaries
        self.expectedVersion = expectedVersion
    }

    /// Read-only: runs the probe script (`sh -c`) and parses its output.
    public func probe() async throws -> FfiProbeResult {
        let out: RemoteExecOutput
        do {
            out = try await remote.exec("sh -c " + ShellQuote.quote(probeScript()))
        } catch {
            throw AgentInstallError.probeFailed(error.localizedDescription)
        }
        guard out.ok else {
            let e = out.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw AgentInstallError.probeFailed(e.isEmpty ? "exit status \(out.exitStatus.map(String.init) ?? "signal")" : e)
        }
        let p = parseProbe(text: out.stdout)
        guard !p.unameS.isEmpty else { throw AgentInstallError.probeFailed("unexpected probe output") }
        return p
    }

    public func plan(for probe: FfiProbeResult) -> [FfiInstallStep] {
        installPlan(probe: probe, expectedAgentVersion: expectedVersion)
    }

    public func run(
        probe: FfiProbeResult, options: InstallOptions = InstallOptions(),
        progress: @escaping @Sendable (InstallProgress) -> Void = { _ in }
    ) async -> InstallReport {
        let runner = Runner(remote: remote, binaries: binaries, probe: probe, options: options)
        let steps = plan(for: probe).map { runner.action(for: $0) }
        return await runner.execute(steps, progress: progress)
    }

    public func uninstall(
        probe: FfiProbeResult, options: InstallOptions = InstallOptions(),
        progress: @escaping @Sendable (InstallProgress) -> Void = { _ in }
    ) async -> InstallReport {
        let runner = Runner(remote: remote, binaries: binaries, probe: probe, options: options)
        return await runner.execute(runner.uninstallActions(), progress: progress)
    }
}

// MARK: - Execution

private struct Action {
    var title: String
    /// What a dry run reports.
    var preview: [String]
    var perform: (Runner) async throws -> StepStatus
}

private final class Runner: @unchecked Sendable {
    let remote: AgentRemote
    let binaries: AgentBinaryProviding
    let probe: FfiProbeResult
    let options: InstallOptions
    var warnings: [String] = []
    var conflicts: [CodexConflict] = []
    var doctor: DoctorReport?
    private var currentLog: ((String) -> Void) = { _ in }

    init(remote: AgentRemote, binaries: AgentBinaryProviding, probe: FfiProbeResult, options: InstallOptions) {
        self.remote = remote
        self.binaries = binaries
        self.probe = probe
        self.options = options
    }

    var home: String { probe.home }
    var agentPath: String { expandTilde(path: "~/.shuai/bin/shuai-agent", home: home) }
    func abs(_ p: String) -> String { expandTilde(path: p, home: home) }
    func q(_ p: String) -> String { ShellQuote.quote(p) }
    func log(_ s: String) { currentLog(s) }

    func execute(_ actions: [Action], progress: @escaping @Sendable (InstallProgress) -> Void) async -> InstallReport {
        var outcomes: [StepOutcome] = []
        var failed = false
        for (i, a) in actions.enumerated() {
            var lines: [String] = []
            func emit(_ status: StepStatus, _ message: String? = nil) {
                progress(InstallProgress(stepIndex: i, title: a.title, status: status, message: message))
            }
            if failed {
                outcomes.append(StepOutcome(index: i, title: a.title, status: .skipped, log: ["Skipped because an earlier step failed."]))
                emit(.skipped)
                continue
            }
            currentLog = { line in lines.append(line); emit(.running, line) }
            emit(.running)
            let status: StepStatus
            if options.dryRun {
                a.preview.forEach { lines.append($0) }
                status = .wouldRun
            } else {
                do {
                    status = try await a.perform(self)
                } catch {
                    status = .failed(error.localizedDescription)
                }
            }
            currentLog = { _ in }
            if case .failed = status { failed = true }
            outcomes.append(StepOutcome(index: i, title: a.title, status: status, log: lines))
            emit(status)
        }
        return InstallReport(steps: outcomes, dryRun: options.dryRun, conflicts: conflicts, warnings: warnings, doctor: doctor)
    }

    // MARK: remote helpers

    @discardableResult
    func sh(_ command: String, what: String) async throws -> RemoteExecOutput {
        let out = try await remote.exec(command)
        guard out.ok else {
            let e = out.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw AgentInstallError.commandFailed("\(what) failed" + (e.isEmpty ? "" : ": \(e)"))
        }
        return out
    }

    /// File contents, or nil when it does not exist. Unreadable existing files throw (never clobbered).
    func readFile(_ path: String) async throws -> String? {
        let out = try await remote.exec("cat \(q(path))")
        if out.ok { return out.stdout }
        if try await !remote.exec("test -e \(q(path))").ok { return nil }
        throw AgentInstallError.commandFailed("cannot read \(path)")
    }

    func parent(_ path: String) -> String {
        let p = (path as NSString).deletingLastPathComponent
        return p.isEmpty ? "/" : p
    }

    /// Replace a text file, keeping a one-time `.shuai-bak` copy of the original.
    func writeFile(_ path: String, _ text: String, hadOriginal: Bool) async throws {
        try await sh("mkdir -p \(q(parent(path)))", what: "mkdir")
        if hadOriginal {
            try await sh("[ -e \(q(path + ".shuai-bak")) ] || cp \(q(path)) \(q(path + ".shuai-bak"))", what: "backup of \(path)")
        }
        // Atomic replace: a concurrent reader (Claude Code) sees the old or the new file, never a
        // half-written one. A symlinked file (dotfile managers) is written through instead of
        // being replaced by a regular file.
        let tmp = path + ".shuai-tmp"
        try await remote.upload(Data(text.utf8), to: tmp, mode: 0o600)
        try await sh(
            "if [ -L \(q(path)) ]; then cat \(q(tmp)) > \(q(path)) && rm -f \(q(tmp)); else mv -f \(q(tmp)) \(q(path)); fi",
            what: "replace \(path)")
    }

    // MARK: install actions

    func action(for step: FfiInstallStep) -> Action {
        switch step {
        case .unsupported(let reason):
            return Action(title: "Check platform", preview: [reason]) { _ in
                throw AgentInstallError.commandFailed(reason)
            }
        case .makeDirs(let path):
            return Action(title: "Create \(path)", preview: ["Would run: mkdir -p \(abs(path))"]) { r in
                try await r.sh("mkdir -p \(r.q(r.abs(path)))", what: "mkdir")
                return .done
            }
        case .uploadAgent(let triple, let remotePath):
            return Action(title: "Upload shuai-agent (\(triple))", preview: ["Would upload the \(triple) binary to \(abs(remotePath))"]) { r in
                let data = try r.binaries.binary(forTriple: triple)
                let dest = r.abs(remotePath)
                r.log("Uploading \(data.count) bytes to \(dest)")
                // Beside the target: a running agent (watch) cannot be overwritten in place.
                try await r.remote.upload(data, to: dest + ".new", mode: 0o755)
                try await r.sh("mv -f \(r.q(dest + ".new")) \(r.q(dest))", what: "mv")
                return .done
            }
        case .chmod(let path, let mode):
            return Action(title: "Make shuai-agent executable", preview: ["Would run: chmod \(String(mode, radix: 8)) \(abs(path))"]) { r in
                try await r.sh("chmod \(String(mode, radix: 8)) \(r.q(r.abs(path)))", what: "chmod")
                return .done
            }
        case .installPluginViaCli(let claude):
            let via = options.pluginSource == .github ? "GitHub marketplace, then local" : "local marketplace"
            return Action(
                title: "Install Claude Code plugin",
                preview: ["Would register the shuai plugin with \(claude) (\(via): \(abs(pluginMarketplaceDir())))"]
            ) { r in try await r.installPlugin(claude: claude) }
        case .mergeSettingsJson(let path, let agent):
            return Action(title: "Register hooks in settings.json", preview: ["Would merge the shuai hooks into \(abs(path))"]) { r in
                try await r.mergeSettings(path: r.abs(path), agentPath: agent)
                return .done
            }
        case .configureCodexNotify(let configPath, let argv):
            return Action(title: "Configure Codex notify", preview: ["Would set notify in \(abs(configPath))"]) { r in
                try await r.setCodexNotify(path: r.abs(configPath), argv: argv)
                return .done
            }
        case .codexNotifyConflict(let configPath, let existing):
            return Action(
                title: "Configure Codex notify",
                preview: ["Codex already has a notify program (\(existing)); the app would ask before changing it."]
            ) { r in
                switch r.options.codexConflict {
                case .replace:
                    r.log("Replacing the existing notify setting (kept in config.toml.shuai-bak)")
                    try await r.setCodexNotify(path: r.abs(configPath), argv: [r.agentPath, "codex-notify"])
                    return .done
                case .skip:
                    r.conflicts.append(CodexConflict(configPath: configPath, existing: existing))
                    r.log("Codex already has a notify program: \(existing)")
                    return .needsDecision
                }
            }
        case .appendTmuxConf(let path, let lines):
            return Action(title: "Add tmux settings", preview: ["Would append a marked block to \(path):"] + lines) { r in
                try await r.sh(appendTmuxBlockCommand(path: path, lines: lines), what: "tmux.conf update")
                // Reload only when a server is running; failures are irrelevant.
                _ = try? await r.remote.exec("tmux has-session 2>/dev/null && tmux source-file \(path) || true")
                return .done
            }
        case .runDoctor(let agent):
            return Action(title: "Run diagnostics", preview: ["Would run: \(agent) doctor"]) { r in
                let out = try await r.sh("\(r.q(agent)) doctor", what: "shuai-agent doctor")
                r.doctor = try? DoctorReport.decode(out.stdout)
                if r.doctor == nil { r.warnings.append("Could not read the doctor report.") }
                return .done
            }
        }
    }

    func installPlugin(claude: String) async throws -> StepStatus {
        if options.pluginSource == .github {
            let cmds = pluginInstallCommands(claudePath: claude)
            log("Trying the GitHub marketplace")
            var ok = true
            for c in cmds where ok {
                let o = try? await remote.exec(c)
                // Re-running after a previous install: the marketplace is already registered.
                ok = o?.ok == true || o?.stderr.localizedCaseInsensitiveContains("already") == true
            }
            if ok { return .done }
            log("GitHub marketplace unavailable (private repository?); using the local one")
        }
        do {
            try await installLocalPlugin(claude: claude)
            return .done
        } catch {
            warnings.append("Plugin install via the claude CLI failed (\(error.localizedDescription)); registered the hooks in ~/.claude/settings.json instead.")
            log("claude plugin install failed: \(error.localizedDescription); falling back to settings.json")
            try await mergeSettings(path: abs("~/.claude/settings.json"), agentPath: agentPath)
            return .done
        }
    }

    func installLocalPlugin(claude: String) async throws {
        let base = abs(pluginMarketplaceDir())
        let files = pluginBundle()
        let dirs = Set(files.map { parent(base + "/" + $0.path) })
        try await sh("mkdir -p " + dirs.sorted().map(q).joined(separator: " "), what: "mkdir")
        for f in files {
            try await remote.upload(Data(f.contents.utf8), to: base + "/" + f.path, mode: 0o644)
        }
        log("Uploaded the plugin marketplace to \(base)")
        let cmds = localPluginInstallCommands(claudePath: claude, home: home)
        // `marketplace add` fails when it is already registered; only the install matters.
        if let add = try? await remote.exec(cmds[0]), !add.ok {
            log("marketplace add: \(add.stderr.trimmingCharacters(in: .whitespacesAndNewlines)) (continuing)")
        }
        try await sh(cmds[1], what: "claude plugin install")
    }

    func mergeSettings(path: String, agentPath: String) async throws {
        let existing = try await readFile(path)
        let merged: String
        do {
            merged = try mergeClaudeSettings(existing: existing ?? "", agentPath: agentPath)
        } catch {
            throw AgentInstallError.commandFailed("\(path) is not valid JSON; left untouched")
        }
        try await writeFile(path, merged, hadOriginal: existing != nil)
        log("Merged hooks into \(path)")
    }

    func setCodexNotify(path: String, argv: [String]) async throws {
        let existing = try await readFile(path)
        try await writeFile(path, CodexConfigEditor.settingNotify(in: existing ?? "", argv: argv), hadOriginal: existing != nil)
    }

    // MARK: uninstall

    func uninstallActions() -> [Action] {
        var actions: [Action] = []
        let claude = probe.claudePath
        if probe.pluginInstalled {
            actions.append(Action(title: "Remove Claude Code plugin", preview: ["Would uninstall the shuai plugin and remove its hooks from settings.json"]) { r in
                if let claude {
                    for c in pluginUninstallCommands(claudePath: claude) {
                        if let o = try? await r.remote.exec(c), !o.ok { r.log("\(c): \(o.stderr.trimmingCharacters(in: .whitespacesAndNewlines))") }
                    }
                }
                let path = r.abs("~/.claude/settings.json")
                if let text = try await r.readFile(path), text.contains("shuai-agent") {
                    let cleaned = try removeClaudeSettingsHooks(existing: text)
                    try await r.writeFile(path, cleaned, hadOriginal: true)
                    r.log("Removed hooks from \(path)")
                }
                return .done
            })
        }
        if probe.tmuxConfBlock {
            actions.append(Action(title: "Remove tmux settings", preview: ["Would remove the marked shuai block from ~/.tmux.conf"]) { r in
                for p in ["~/.tmux.conf", "~/.config/tmux/tmux.conf"] {
                    try await r.sh(removeTmuxBlockCommand(path: p), what: "tmux.conf update")
                }
                return .done
            })
        }
        if let n = probe.codexNotify, n.contains("shuai-agent") {
            actions.append(Action(title: "Remove Codex notify", preview: ["Would remove notify from ~/.codex/config.toml"]) { r in
                let path = r.abs("~/.codex/config.toml")
                if let text = try await r.readFile(path) {
                    try await r.writeFile(path, CodexConfigEditor.removingShuaiNotify(from: text), hadOriginal: true)
                }
                return .done
            })
        }
        if probe.agentVersion != nil || probe.pluginInstalled {
            let dir = abs("~/.shuai")
            let command = "pkill -f '[.]shuai/bin/shuai-agent'; sleep 0.3; rm -rf \(q(dir))"
            actions.append(Action(title: "Remove shuai-agent", preview: ["Would stop a running shuai-agent and run: rm -rf " + dir]) { r in
                try await r.sh(command, what: "rm")
                return .done
            })
        }
        return actions
    }
}
