import Foundation
import Observation
import ShuaiCore

/// An in-app banner announcing that an agent wants the user.
public struct AttentionBanner: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case permission(requestId: String, tool: String, preview: String)
        case needsInput
        case done
        case failed(error: String)

        /// Lower = shown first.
        var priority: Int {
            switch self {
            case .permission: 0
            case .needsInput: 1
            case .failed: 2
            case .done: 3
            }
        }
    }

    public let id: UUID
    public let key: FfiSessionKey
    public let kind: Kind
}

/// Turns *live* tracker changes into a small queue of banners. Logic only (no UI); the monitor
/// feeds it live changes only, so replayed history never produces a banner.
///
/// * one banner per session: a newer transition replaces the older one;
/// * a permission banner disappears when the request is cleared (answered anywhere);
/// * the same permission request is never queued twice;
/// * `isSuppressed` lets the app hide banners for the session the user is looking at.
@MainActor @Observable
public final class AttentionBannerQueue {
    public private(set) var banners: [AttentionBanner] = []
    @ObservationIgnored private let capacity: Int
    @ObservationIgnored private let isSuppressed: (FfiSessionKey) -> Bool

    public init(capacity: Int = 5, isSuppressed: @escaping (FfiSessionKey) -> Bool = { _ in false }) {
        self.capacity = max(1, capacity)
        self.isSuppressed = isSuppressed
    }

    /// The banner to show now: permission requests first, then by recency.
    public var current: AttentionBanner? {
        banners.enumerated()
            .min { ($0.element.kind.priority, -$0.offset) < ($1.element.kind.priority, -$1.offset) }?
            .element
    }

    public func enqueue(_ changes: [FfiTrackerChange]) {
        for change in changes {
            switch change {
            case .permissionRequested(let key, let request):
                add(key, .permission(requestId: request.requestId, tool: request.toolName, preview: request.inputPreview))
            case .permissionCleared(let key):
                banners.removeAll { $0.key == key && $0.kind.isPermission }
            case .stateChanged(let key, _, let to):
                switch to {
                case .needsInput: add(key, .needsInput)
                case .done: add(key, .done)
                case .failed(let e): add(key, .failed(error: e))
                case .ended: remove(key)
                default: break  // working/starting/needsPermission (covered by permissionRequested)
                }
            case .sessionRemoved(let key):
                remove(key)
            case .sessionAdded:
                break
            }
        }
    }

    public func dismiss(_ id: UUID) { banners.removeAll { $0.id == id } }
    public func remove(_ key: FfiSessionKey) { banners.removeAll { $0.key == key } }
    public func removeAll() { banners.removeAll() }

    private func add(_ key: FfiSessionKey, _ kind: AttentionBanner.Kind) {
        guard !isSuppressed(key) else { return }
        if banners.contains(where: { $0.key == key && $0.kind == kind }) { return }
        // One banner per session: the newest transition wins.
        banners.removeAll { $0.key == key }
        banners.append(AttentionBanner(id: UUID(), key: key, kind: kind))
        if banners.count > capacity { banners.removeFirst(banners.count - capacity) }
    }
}

extension AttentionBanner.Kind {
    var isPermission: Bool { if case .permission = self { true } else { false } }
}
