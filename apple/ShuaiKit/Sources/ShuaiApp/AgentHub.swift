import Foundation
import Observation
import ShuaiCore

/// A pending permission request together with the app's host profile it belongs to.
public struct HubPermission: Identifiable, Equatable, Sendable {
    public var id: String { item.request.requestId }
    public let profileID: UUID
    public let item: PendingPermissionItem
    /// tmux pane the request came from (`%3`), if the agent knew it.
    public var paneID: String? { item.session.tmuxPane }
}

/// A session that wants the user, resolved to the app's host profile and tmux pane.
public struct AttentionTarget: Identifiable, Equatable, Sendable {
    public var id: String { "\(key.host)/\(key.sessionId)" }
    public let profileID: UUID
    public let key: FfiSessionKey
    public let session: FfiAgentSession
    public var paneID: String? { session.tmuxPane }
}

/// Picks "the next one" in a cycle (⌘⇧A).
public enum AttentionCycle {
    /// The key after `current` in `keys` (wrapping); the first one when `current` is nil or no
    /// longer listed (e.g. it was just marked seen).
    public static func next(after current: FfiSessionKey?, in keys: [FfiSessionKey]) -> FfiSessionKey? {
        guard let first = keys.first else { return nil }
        guard let current, let i = keys.firstIndex(of: current) else { return first }
        return keys[(i + 1) % keys.count]
    }
}

/// All hosts' agent monitors behind one object, keyed the way the UI keys hosts.
///
/// **Host keys.** The UI (sidebar, quick switcher, `PaneBadgeProvider` callers) identifies a host
/// by its `HostProfile.id` (the UUID, passed as `uuidString` where the provider API wants a
/// `String`). The agent's events carry the *remote hostname* instead (`uname -n`, or
/// `SHUAI_HOSTNAME`), and the Rust tracker is keyed by that. The hub bridges the two: per
/// connection it probes the remote hostname (`AgentHostProbe`, the same rule the agent uses),
/// creates the `AgentMonitor` with `host: <remote hostname>` and remembers `profile id -> monitor`.
/// Every query from the UI goes through the profile id and is translated to the hostname here;
/// every change coming out of a monitor (keyed by hostname) is translated back to the profile id.
/// Two profiles for the same machine simply get two monitors (separate trackers), so nothing collides
/// except banner dedupe, which only costs a replaced banner.
@MainActor @Observable
public final class AgentHub: PaneAgentInfoProvider {
    public private(set) var monitors: [UUID: AgentMonitor] = [:]
    public private(set) var statuses: [UUID: AgentHostStatus] = [:]
    /// Shared by every monitor: live NeedsInput / Done / Failed transitions of all hosts.
    public let banners: AttentionBannerQueue

    /// Live (never replayed) changes of a host, translated to its profile id.
    @ObservationIgnored public var onLiveChanges: (@MainActor (UUID, [FfiTrackerChange]) -> Void)?

    /// A connected host turned out to have the agent installed (called after every such connect).
    /// Used to bring its `config.toml` (push settings) up to date.
    @ObservationIgnored public var onAgentReady: (@MainActor (UUID, AgentRemote) async -> Void)?

    @ObservationIgnored private let expectedVersion: String
    @ObservationIgnored private let now: @Sendable () -> UInt64
    @ObservationIgnored private let reconcileInterval: Duration
    /// Bumped on every connect/disconnect of a host so a late probe cannot revive a dropped one.
    @ObservationIgnored private var epochs: [UUID: Int] = [:]

    public init(
        expectedVersion: String = expectedAgentVersion(), banners: AttentionBannerQueue = AttentionBannerQueue(),
        reconcileInterval: Duration = .seconds(60),
        now: @escaping @Sendable () -> UInt64 = { UInt64(Date().timeIntervalSince1970 * 1000) }
    ) {
        self.expectedVersion = expectedVersion
        self.banners = banners
        self.reconcileInterval = reconcileInterval
        self.now = now
    }

    // MARK: Lifecycle

    /// Call after every successful (re)connect of `id` with that connection's remote. Probes the
    /// host and, when the agent is installed, (re)starts watching; a reconnect resumes the same
    /// monitor from its cursor.
    public func hostConnected(id: UUID, remote: AgentRemote) async {
        let epoch = (epochs[id] ?? 0) + 1
        epochs[id] = epoch
        let info = (try? await remote.exec(AgentHostProbe.command)).flatMap(AgentHostProbe.parse)
        guard epochs[id] == epoch else { return }  // disconnected / reconnected meanwhile
        guard let info else {
            statuses[id] = .unknown
            monitors[id]?.detach()
            return
        }
        let status = AgentHostStatus.make(installed: info.agentVersion, bundled: expectedVersion)
        statuses[id] = status
        guard status.isInstalled else {
            monitors[id]?.detach()
            monitors[id] = nil
            return
        }
        let monitor: AgentMonitor
        if let existing = monitors[id], existing.host == info.hostname {
            monitor = existing
        } else {
            monitors[id]?.detach()
            monitor = AgentMonitor(
                host: info.hostname, banners: banners, reconcileInterval: reconcileInterval, now: now)
            monitor.onLiveChanges = { [weak self] changes in self?.onLiveChanges?(id, changes) }
            monitors[id] = monitor
        }
        monitor.attach(remote: remote, claudePath: info.claudePath)
        if let ready = onAgentReady { Task { await ready(id, remote) } }
    }

    /// The connection of `id` went away (state is kept for the UI until it comes back).
    public func hostDisconnected(id: UUID) {
        epochs[id] = (epochs[id] ?? 0) + 1
        monitors[id]?.detach()
    }

    public func removeHost(id: UUID) {
        epochs[id] = nil
        monitors[id]?.detach()
        monitors[id] = nil
        statuses[id] = nil
    }

    /// The installer changed the host: the next connect re-probes; until then show it as unknown.
    public func invalidate(id: UUID) { statuses[id] = .unknown }

    // MARK: Lookup

    public func monitor(for id: UUID) -> AgentMonitor? { monitors[id] }
    public func status(for id: UUID) -> AgentHostStatus { statuses[id] ?? .unknown }

    /// Which profile owns the session `key` (keyed by remote hostname).
    public func profileID(for key: FfiSessionKey) -> UUID? {
        let byHost = monitors.filter { $0.value.host == key.host }
        return byHost.first { $0.value.sessions.contains { $0.sessionId == key.sessionId } }?.key ?? byHost.keys.sorted { $0.uuidString < $1.uuidString }.first
    }

    // MARK: PaneBadgeProvider (host = profile UUID string)

    public func badge(host: String, pane: String) -> PaneBadge? {
        guard let id = UUID(uuidString: host), let m = monitors[id] else { return nil }
        _ = m.sessions  // observation: `badge` below reads the (unobserved) tracker
        return m.badge(host: m.host, pane: pane)
    }

    public func agentInfo(host: String, pane: String) -> PaneAgentInfo? {
        guard let id = UUID(uuidString: host), let m = monitors[id] else { return nil }
        guard let s = m.sessions.first(where: { $0.tmuxPane == pane }), let b = s.badge else { return nil }
        return PaneAgentInfo(badge: PaneBadge(b), snippet: PaneAgentInfo.snippet(prompt: s.lastPrompt, message: s.lastMessage))
    }

    // MARK: Attention

    private static func waiting(_ s: FfiAgentSession) -> Bool {
        switch s.state {
        case .needsPermission, .needsInput: true
        default: false
        }
    }

    /// Sessions of `id` that are waiting for the user (approval or input).
    public func waitingCount(for id: UUID) -> Int { monitors[id]?.sessions.filter(Self.waiting).count ?? 0 }
    public var totalWaiting: Int { monitors.values.reduce(0) { $0 + $1.sessions.filter(Self.waiting).count } }

    /// Every pending permission request, oldest first.
    public var pendingPermissions: [HubPermission] {
        monitors.flatMap { id, m in m.pendingPermissions.map { HubPermission(profileID: id, item: $0) } }
            .sorted { ($0.item.request.since, $0.id) < ($1.item.request.since, $1.id) }
    }

    public func answering(_ p: HubPermission) -> AnswerState? { monitors[p.profileID]?.answering[p.id] }
    public func lastError(for p: HubPermission) -> String? { monitors[p.profileID]?.lastError }

    @discardableResult
    public func respond(_ p: HubPermission, allow: Bool, message: String?) async -> RespondResult {
        guard let m = monitors[p.profileID] else { return .failed("Not connected") }
        return await m.respond(requestId: p.id, allow: allow, message: message)
    }

    /// Sessions that want the user (⌘⇧A order): most urgent first, then most recent.
    public func attentionTargets() -> [AttentionTarget] {
        let all = monitors.flatMap { id, m in
            m.sessions.filter(\.needsAttention).map { AttentionTarget(profileID: id, key: FfiSessionKey(host: $0.host, sessionId: $0.sessionId), session: $0) }
        }
        return all.sorted { a, b in
            let (pa, pb) = (Self.urgency(a.session), Self.urgency(b.session))
            if pa != pb { return pa > pb }
            if a.session.updatedAt != b.session.updatedAt { return a.session.updatedAt > b.session.updatedAt }
            return a.id < b.id
        }
    }

    private static func urgency(_ s: FfiAgentSession) -> Int { s.badge.map { PaneBadge($0).priority } ?? -1 }

    public func nextNeedingAttention(after current: FfiSessionKey?) -> AttentionTarget? {
        let targets = attentionTargets()
        guard let key = AttentionCycle.next(after: current, in: targets.map(\.key)) else { return nil }
        return targets.first { $0.key == key }
    }

    /// The user is looking at `paneID` of `profileID`: its agent session counts as seen.
    public func markSeen(profileID: UUID, paneID: String) {
        guard let m = monitors[profileID], let s = m.sessions.first(where: { $0.tmuxPane == paneID }) else { return }
        m.markSeen(FfiSessionKey(host: s.host, sessionId: s.sessionId))
    }

    /// The session `key` (e.g. of a banner) as a jump target, whatever its state.
    public func target(for key: FfiSessionKey) -> AttentionTarget? {
        guard let id = profileID(for: key),
            let s = monitors[id]?.sessions.first(where: { $0.host == key.host && $0.sessionId == key.sessionId })
        else { return nil }
        return AttentionTarget(profileID: id, key: key, session: s)
    }

    public func markSeen(_ target: AttentionTarget) {
        monitors[target.profileID]?.markSeen(target.key)
    }
}
