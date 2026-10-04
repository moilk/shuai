import Foundation

/// Stub (tests first).
public final class DeviceReplyGuard: @unchecked Sendable {
    public init(maxAge: TimeInterval = 3) {}
    public func noteOutput(_ data: Data, at now: Date) {}
    public func admit(_ data: Data, at now: Date) -> Bool { true }
    public func reset() {}
}
