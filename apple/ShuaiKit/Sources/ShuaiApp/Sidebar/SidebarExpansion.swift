import Foundation
import Observation

/// Which sidebar rows differ from their default expanded/collapsed state. Keys use names, never
/// tmux `$N`/`@N`/`%N` ids: those are reused after a server restart and would collapse the wrong rows.
public struct SidebarExpansion: Codable, Equatable, Sendable {
    public enum Key: Hashable, Codable, Sendable {
        case host(UUID)
        case session(host: UUID, name: String)

        var hostID: UUID {
            switch self {
            case .host(let id), .session(let id, _): id
            }
        }
    }

    /// Upper bound on stored exceptions; the oldest-inserted are dropped first.
    public static let maxEntries = 256

    /// Only the exceptions to the default.
    public private(set) var overrides: [Key: Bool] = [:]
    /// Insertion order of `overrides` keys, oldest first.
    private var order: [Key] = []

    public init() {}

    public func isExpanded(_ key: Key, default def: Bool) -> Bool { overrides[key] ?? def }

    public mutating func toggle(_ key: Key, default def: Bool) {
        let next = !isExpanded(key, default: def)
        if next == def {
            remove(key)
            return
        }
        if overrides[key] == nil { order.append(key) }
        overrides[key] = next
        while order.count > Self.maxEntries {
            overrides[order.removeFirst()] = nil
        }
    }

    public mutating func forget(host: UUID) {
        order.removeAll { $0.hostID == host }
        overrides = overrides.filter { $0.key.hostID != host }
    }

    public mutating func prune(keeping hosts: Set<UUID>) {
        order.removeAll { !hosts.contains($0.hostID) }
        overrides = overrides.filter { hosts.contains($0.key.hostID) }
    }

    private mutating func remove(_ key: Key) {
        guard overrides[key] != nil else { return }
        overrides[key] = nil
        order.removeAll { $0 == key }
    }

    // MARK: Codable (ordered entries, so the cap stays deterministic after a reload)

    private struct Entry: Codable { var key: Key; var expanded: Bool }
    private enum CodingKeys: String, CodingKey { case entries }

    public init(from decoder: Decoder) throws {
        let entries = try decoder.container(keyedBy: CodingKeys.self).decode([Entry].self, forKey: .entries)
        for e in entries.suffix(Self.maxEntries) where overrides[e.key] == nil {
            overrides[e.key] = e.expanded
            order.append(e.key)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(order.compactMap { k in overrides[k].map { Entry(key: k, expanded: $0) } }, forKey: .entries)
    }
}

/// Persists `SidebarExpansion` in UserDefaults (corrupt or missing data starts empty).
@MainActor @Observable
public final class SidebarExpansionStore {
    public static let defaultsKey = "sidebarExpansion.v1"

    public private(set) var expansion: SidebarExpansion { didSet { save() } }
    @ObservationIgnored private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        expansion = defaults.data(forKey: Self.defaultsKey)
            .flatMap { try? JSONDecoder().decode(SidebarExpansion.self, from: $0) } ?? SidebarExpansion()
    }

    public func isExpanded(_ key: SidebarExpansion.Key, default def: Bool) -> Bool {
        expansion.isExpanded(key, default: def)
    }

    public func toggle(_ key: SidebarExpansion.Key, default def: Bool) { expansion.toggle(key, default: def) }
    public func forget(host: UUID) { expansion.forget(host: host) }
    public func prune(keeping hosts: Set<UUID>) { expansion.prune(keeping: hosts) }

    private func save() {
        if let data = try? JSONEncoder().encode(expansion) { defaults.set(data, forKey: Self.defaultsKey) }
    }
}
