import Foundation

/// The host editor's save flow, kept outside the view so it survives view rebuilds: one stable
/// host id, the draft the dirty check compares against, and whether the host is already stored
/// (so a retry updates instead of adding). The password is only a parameter of an attempt; it is
/// never stored here.
public struct HostEditorSave: Sendable {
    public enum Step: Equatable, Sendable { case add, update }
    public enum Result: Equatable, Sendable {
        case saved(HostProfile)
        case failed(message: String)
    }

    public let id: UUID
    /// The draft at open time, fixed for the editor's lifetime.
    public let initial: HostEditorDraft
    /// The host is in the store (editing, or a save of a new host went through).
    public private(set) var persisted: Bool

    public init(new keys: [String], id: UUID = UUID()) {
        self.id = id
        initial = HostEditorDraft(new: keys)
        persisted = false
    }

    public init(editing profile: HostProfile) {
        id = profile.id
        initial = HostEditorDraft(editing: profile)
        persisted = true
    }

    /// Writes the host, then the password (password auth) or removes it (other auth). An error
    /// message says "host saved" only when the host write of this very attempt succeeded.
    public mutating func attempt(
        _ draft: HostEditorDraft, password: String, lastConnectedAt: Date?,
        writeHost: (HostProfile, Step) throws -> Void,
        setPassword: (String, UUID) throws -> Void,
        deletePassword: (UUID) -> Void
    ) -> Result {
        let profile = draft.profile(id: id, lastConnectedAt: lastConnectedAt)
        var hostWritten = false
        do {
            try writeHost(profile, persisted ? .update : .add)
            hostWritten = true
            persisted = true
            switch draft.authKind {
            case .password:
                if !password.isEmpty { try setPassword(password, id) }
            case .key, .ask:
                deletePassword(id)
            }
            return .saved(profile)
        } catch {
            return .failed(message: HostEditorSaveError.message(for: error, hostSaved: hostWritten))
        }
    }
}
