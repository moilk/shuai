import SwiftUI
import ShuaiCore

/// "Enable AI integration" sheet: what was found on the host, what will change, live progress,
/// and the Codex conflict decision.
public struct AgentInstallSheet: View {
    @Bindable var model: AgentInstallModel
    public var hostName: String
    public var onClose: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .body) private var lineSpacing: CGFloat = 2
    @ScaledMetric(relativeTo: .body) private var blockSpacing: CGFloat = 4

    public init(model: AgentInstallModel, hostName: String, onClose: @escaping () -> Void) {
        self.model = model
        self.hostName = hostName
        self.onClose = onClose
    }

    public var body: some View {
        NavigationStack {
            List {
                if let p = model.probe { probeSection(p) }
                switch model.phase {
                case .idle, .inspecting:
                    Section { HStack { ProgressView(); Text("Inspecting \(hostName)...") } }
                case .failed(let message):
                    Section { Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.chromeError) }
                case .ready:
                    planSection(title: model.mode == .install ? "Planned changes" : "Will be removed", model.preview.map { ($0.title, $0.status, $0.log) })
                case .installing, .finished:
                    progressSection
                }
                if let r = model.report { reportSections(r) }
            }
            .chromeForm()
            .navigationTitle(model.mode == .install ? "Enable AI integration" : "Remove AI integration")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close", action: onClose) }
                ToolbarItem(placement: .confirmationAction) { primaryButton }
            }
        }
        .task { if model.phase == .idle { await model.inspect() } }
        .accessibilityIdentifier("agent-install-sheet")
    }

    @ViewBuilder private var primaryButton: some View {
        switch model.phase {
        case .ready:
            if model.mode == .install {
                Button("Install") { Task { await model.install() } }.accessibilityIdentifier("agent-install-button")
            } else {
                Button("Remove", role: .destructive) { Task { await model.uninstall() } }
                    .accessibilityIdentifier("agent-remove-button")
            }
        case .failed:
            Button("Retry") { Task { await model.inspect() } }
        case .finished:
            if model.report?.conflicts.isEmpty == false {
                Button("Replace and retry") {
                    model.codexResolution = .replace
                    Task { await model.install() }
                }
            } else {
                Button("Done", action: onClose)
            }
        default:
            EmptyView()
        }
    }

    private func probeSection(_ p: FfiProbeResult) -> some View {
        Section("Host") {
            row("System", "\(p.unameS) \(p.unameM)")
            row("Claude Code", p.claudePath ?? "not found")
            row("tmux", p.tmuxVersion ?? "not found")
            row("shuai-agent", p.agentVersion ?? "not installed")
            row("Plugin", p.pluginInstalled ? "installed" : "not installed")
            if p.codexPath != nil { row("Codex", p.codexNotify.map { "notify: \($0)" } ?? "found") }
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        // Long values (paths) are shortened in the middle only while they fit beside the title;
        // at accessibility sizes they wrap in full.
        LabeledContent(title) {
            Text(value).foregroundStyle(.chromeSecondary)
                .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                .truncationMode(.middle)
        }
    }

    private func planSection(title: String, _ steps: [(String, StepStatus, [String])]) -> some View {
        Section(title) {
            ForEach(Array(steps.enumerated()), id: \.offset) { _, s in
                VStack(alignment: .leading, spacing: lineSpacing) {
                    Text(s.0)
                    ForEach(Array(s.2.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.system(.caption, design: .monospaced)).foregroundStyle(.chromeSecondary)
                    }
                }
            }
        }
    }

    private var progressSection: some View {
        Section(model.phase == .installing ? "Installing..." : "Result") {
            if let r = model.report {
                ForEach(r.steps, id: \.index) { s in
                    HStack(alignment: .top) {
                        icon(s.status)
                        VStack(alignment: .leading) {
                            Text(s.title)
                            ForEach(Array(s.log.enumerated()), id: \.offset) { _, l in
                                Text(l).font(.caption).foregroundStyle(.chromeSecondary)
                            }
                            if case .failed(let m) = s.status { Text(m).font(.caption).foregroundStyle(.chromeError) }
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            } else {
                ForEach(Array(model.log.enumerated()), id: \.offset) { _, e in
                    HStack(alignment: .top) {
                        icon(e.status)
                        Text(e.message ?? e.title).font(e.message == nil ? .body : .caption)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private func icon(_ status: StepStatus) -> some View {
        statusSymbol(status).accessibilityLabel(status.accessibilityLabel)
    }

    @ViewBuilder private func statusSymbol(_ status: StepStatus) -> some View {
        switch status {
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.chromeSuccess)
        case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.chromeError)
        case .needsDecision: Image(systemName: "questionmark.circle.fill").foregroundStyle(.chromeWarning)
        case .skipped: Image(systemName: "minus.circle").foregroundStyle(.chromeSecondary)
        case .running: ProgressView().controlSize(.small)
        case .pending, .wouldRun: Image(systemName: "circle").foregroundStyle(.chromeSecondary)
        }
    }

    @ViewBuilder private func reportSections(_ r: InstallReport) -> some View {
        if !r.conflicts.isEmpty {
            Section("Needs your decision") {
                ForEach(r.conflicts, id: \.configPath) { c in
                    VStack(alignment: .leading, spacing: blockSpacing) {
                        Text("Codex already runs a notify program:")
                        Text(c.existing).font(.system(.caption, design: .monospaced))
                        Text("Replacing it keeps a backup (config.toml.shuai-bak).").font(.caption).foregroundStyle(.chromeSecondary)
                    }
                }
            }
        }
        if !r.warnings.isEmpty {
            Section("Warnings") { ForEach(r.warnings, id: \.self) { Text($0).font(.caption) } }
        }
        if let d = r.doctor {
            Section("Diagnostics") {
                row("shuai-agent", "\(d.version) (protocol \(d.protocolVersion))")
                row("State directory", d.stateDirWritable ? "writable" : "not writable")
                row("Plugin", d.pluginInstalled ? "installed" : "not installed")
            }
        }
    }
}

#if DEBUG
/// Scripted remote for previews and the debug harness: answers the probe and accepts everything.
struct PreviewAgentRemote: AgentRemote {
    var codexNotify: String = ""

    func exec(_ command: String) async throws -> RemoteExecOutput {
        if command.contains("__SHUAI_PROBE_BEGIN__") {
            return .ok("""
                __SHUAI_PROBE_BEGIN__
                uname_s=Linux
                uname_m=x86_64
                home=/home/dev
                claude_path=/home/dev/.local/bin/claude
                codex_path=\(codexNotify.isEmpty ? "" : "/usr/bin/codex")
                codex_notify=\(codexNotify)
                tmux_version=tmux 3.4
                __SHUAI_PROBE_END__
                """)
        }
        try await Task.sleep(for: .milliseconds(200))
        return .ok("{}")
    }

    func execStream(_ command: String) async throws -> AgentStream { throw AgentInstallError.commandFailed("preview") }
    func upload(_ data: Data, to path: String, mode: UInt32) async throws {}
}

struct PreviewBinaries: AgentBinaryProviding {
    func binary(forTriple triple: String) throws -> Data { Data("ELF".utf8) }
}

#Preview("Install sheet") {
    AgentInstallSheet(
        model: AgentInstallModel(installer: AgentInstaller(remote: PreviewAgentRemote(), binaries: PreviewBinaries())),
        hostName: "dev"
    ) {}
}

#Preview("Install sheet, Codex conflict") {
    AgentInstallSheet(
        model: AgentInstallModel(
            installer: AgentInstaller(remote: PreviewAgentRemote(codexNotify: #"notify = ["/usr/bin/other"]"#), binaries: PreviewBinaries())),
        hostName: "dev"
    ) {}
}

/// Debug harness: a fake monitor fed with a pending permission, next to the install sheet entry.
/// (Not wired into the app; open from previews or a debug screen.)
public struct AgentDebugHarness: View {
    @State private var answered: String?
    @State private var showInstall = false

    public init() {}

    public var body: some View {
        VStack(spacing: 16) {
            PermissionCardView(item: .sample(tool: "Bash", inputJSON: #"{"command":"npm test"}"#)) { allow, msg in
                answered = (allow ? "allow" : "deny") + (msg.map { ": \($0)" } ?? "")
            }
            if let answered { Text("Answered: \(answered)").font(.caption) }
            HStack { AgentStatusBadge(.needsPermission, showsLabel: true); AgentStatusBadge(.working, showsLabel: true) }
            Button("Enable AI integration...") { showInstall = true }
        }
        .padding()
        .sheet(isPresented: $showInstall) {
            AgentInstallSheet(
                model: AgentInstallModel(
                    installer: AgentInstaller(remote: PreviewAgentRemote(), binaries: PreviewBinaries())),
                hostName: "dev"
            ) { showInstall = false }
        }
    }
}

#Preview("Harness") { AgentDebugHarness() }
#endif
