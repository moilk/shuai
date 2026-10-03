import Foundation
import Observation
import ShuaiCore

/// Drives the "Enable AI integration" sheet: inspect (probe + dry-run preview), then install.
@MainActor @Observable
public final class AgentInstallModel {
    public enum Phase: Equatable, Sendable {
        case idle, inspecting, ready, installing, finished
        case failed(String)
    }

    public private(set) var phase: Phase = .idle
    public private(set) var probe: FfiProbeResult?
    /// Dry-run outcome of the plan (nothing was changed on the host).
    public private(set) var preview: [StepOutcome] = []
    /// Progress events, in order (live while installing).
    public private(set) var log: [InstallProgress] = []
    public private(set) var report: InstallReport?
    public var codexResolution: CodexConflictResolution = .skip
    public var pluginSource: PluginSource = .local

    @ObservationIgnored private let installer: AgentInstaller

    public init(installer: AgentInstaller) { self.installer = installer }

    /// Read-only: probe the host and preview the plan.
    public func inspect() async {
        phase = .inspecting
        report = nil
        log = []
        do {
            let p = try await installer.probe()
            probe = p
            let dry = await installer.run(probe: p, options: InstallOptions(dryRun: true, pluginSource: pluginSource))
            preview = dry.steps
            phase = .ready
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    public func install() async {
        guard let p = probe else { return }
        let options = InstallOptions(pluginSource: pluginSource, codexConflict: codexResolution)
        await perform { sink in
            await self.installer.run(probe: p, options: options) { sink.append($0) }
        }
    }

    public func uninstall() async {
        guard let p = probe else { return }
        await perform { sink in
            await self.installer.uninstall(probe: p) { sink.append($0) }
        }
    }

    private func perform(_ work: (ProgressSink) async -> InstallReport) async {
        phase = .installing
        log = []
        let sink = ProgressSink()
        sink.onAppend = { [weak self] p in Task { @MainActor in self?.liveAppend(p) } }
        let r = await work(sink)
        log = sink.items  // authoritative, complete and ordered
        report = r
        phase = .finished
    }

    private func liveAppend(_ p: InstallProgress) {
        if phase == .installing { log.append(p) }
    }
}

final class ProgressSink: @unchecked Sendable {
    private let lock = NSLock()
    private var _items: [InstallProgress] = []
    var onAppend: (@Sendable (InstallProgress) -> Void)?
    func append(_ p: InstallProgress) {
        lock.lock(); _items.append(p); lock.unlock()
        onAppend?(p)
    }
    var items: [InstallProgress] { lock.lock(); defer { lock.unlock() }; return _items }
}
