import Foundation

extension HostValidationError {
    /// User-facing copy for the inline field error.
    public var message: String {
        switch self {
        case .name: "Enter a name."
        case .host: "Enter a host name or IP address without spaces."
        case .port: "Port must be 1–65535."
        case .username: "Enter a username."
        case .key: "Choose a key."
        case .tmuxSessionName: "Use a name without ':' or '.'."
        }
    }
}

/// Everything the host editor edits, as text, without the password (which stays in view state and
/// goes only to the Keychain).
public struct HostEditorDraft: Equatable, Sendable {
    public enum AuthKind: String, CaseIterable, Identifiable, Sendable {
        case key = "SSH key", password = "Password", ask = "Ask each time"
        public var id: String { rawValue }
    }

    public var name: String
    public var host: String
    public var portText: String
    public var username: String
    public var authKind: AuthKind
    public var keyID: String
    public var tmuxEnabled: Bool
    public var tmuxName: String
    public var startup: String

    /// A blank draft for a new host; `keys` are the ids in the key library.
    public init(new keys: [String]) {
        let auth = Self.defaultAuth(keyIDs: keys)
        name = ""
        host = ""
        portText = "22"
        username = ""
        authKind = auth.0
        keyID = auth.1
        tmuxEnabled = true
        tmuxName = "shuai"
        startup = ""
    }

    public init(editing p: HostProfile) {
        name = p.name
        host = p.host
        portText = String(p.port)
        username = p.username
        switch p.auth {
        case .key(let k): authKind = .key; keyID = k
        case .password: authKind = .password; keyID = ""
        case .ask: authKind = .ask; keyID = ""
        }
        tmuxEnabled = p.tmux.enabled
        tmuxName = p.tmux.sessionName
        startup = p.startupCommand ?? ""
    }

    /// With keys, a new host defaults to key auth (the key preselected when it is the only one);
    /// without keys it asks for the password each time.
    public static func defaultAuth(keyIDs: [String]) -> (AuthKind, String) {
        guard !keyIDs.isEmpty else { return (.ask, "") }
        return (.key, keyIDs.count == 1 ? keyIDs[0] : "")
    }

    /// The draft after the key library changed: a newly created key is selected only while no key
    /// is chosen.
    public func adoptingNewKey(before: [String], after: [String]) -> HostEditorDraft {
        var d = self
        guard d.keyID.isEmpty, let new = after.first(where: { !before.contains($0) }) else { return d }
        d.keyID = new
        return d
    }

    /// A port that is not plain ASCII digits parses as 0, which validation rejects.
    private var port: Int {
        let t = portText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else { return 0 }
        return Int(t) ?? 0
    }

    public func profile(id: UUID, lastConnectedAt: Date?) -> HostProfile {
        let auth: HostAuth = switch authKind {
        case .key: .key(keyID: keyID)
        case .password: .password
        case .ask: .ask
        }
        let trim = { (s: String) in s.trimmingCharacters(in: .whitespacesAndNewlines) }
        let cmd = trim(startup)
        return HostProfile(
            id: id, name: trim(name), host: trim(host), port: port, username: trim(username), auth: auth,
            tmux: TmuxPrefs(enabled: tmuxEnabled, sessionName: tmuxName),
            startupCommand: cmd.isEmpty ? nil : cmd, lastConnectedAt: lastConnectedAt)
    }

    /// Invalid fields in form order.
    public var errors: [HostValidationError] {
        profile(id: UUID(), lastConnectedAt: nil).validationErrors
    }
}

/// Which field errors the editor shows: a field's error appears once it was left (or Save was
/// tapped) and disappears as soon as the field is valid.
public struct HostEditorValidation: Equatable, Sendable {
    public private(set) var touched: Set<HostValidationError> = []
    public private(set) var attemptedSave = false

    public init() {}

    public mutating func blur(_ error: HostValidationError) {
        touched.insert(error)
    }

    public func visibleMessage(for error: HostValidationError, in draft: HostEditorDraft) -> String? {
        guard attemptedSave || touched.contains(error), draft.errors.contains(error) else { return nil }
        return error.message
    }

    /// Marks Save as attempted; returns the first invalid field (to focus), or nil when valid.
    public mutating func attemptSave(_ draft: HostEditorDraft) -> HostValidationError? {
        attemptedSave = true
        return draft.errors.first
    }
}

public enum HostEditorDirty {
    /// A typed password counts as a change even though the draft does not hold it.
    public static func needsConfirmation(initial: HostEditorDraft, current: HostEditorDraft, passwordTyped: Bool) -> Bool {
        passwordTyped || initial != current
    }
}

public enum HostEditorSaveError {
    /// Fixed copy only: an underlying error's description can carry paths or Keychain details.
    public static func message(for error: Error, hostSaved: Bool) -> String {
        if hostSaved { return "Host saved, but the password could not be stored in the Keychain." }
        switch error as? HostStoreError {
        case .newerSchema?: return "The host list was written by a newer version of Shuai. Update the app to change hosts."
        case .corrupt?: return "The saved host list could not be read, so nothing was changed."
        case .notFound?: return "This host no longer exists."
        case .io?, nil: return "Could not save the host. Check that the storage is writable and try again."
        }
    }
}
