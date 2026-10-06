import ShuaiApp
import SwiftUI

struct HostEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private enum AuthKind: String, CaseIterable, Identifiable {
        case key = "SSH key", password = "Password", ask = "Ask each time"
        var id: String { rawValue }
    }

    private enum EditorPage: Hashable { case keys }

    private let original: HostProfile?
    @State private var id: UUID
    @State private var name: String
    @State private var host: String
    @State private var portText: String
    @State private var username: String
    @State private var authKind: AuthKind
    @State private var keyID: String
    @State private var password = ""
    @State private var tmuxEnabled: Bool
    @State private var tmuxName: String
    @State private var startup: String
    @State private var attemptedSave = false
    @State private var saveError: String?

    init(target: HostEditorTarget) {
        switch target {
        case .new:
            original = nil
            let p = HostProfile(name: "", host: "", username: "")
            _id = State(initialValue: p.id)
            _name = State(initialValue: "")
            _host = State(initialValue: "")
            _portText = State(initialValue: "22")
            _username = State(initialValue: "")
            _authKind = State(initialValue: .ask)
            _keyID = State(initialValue: "")
            _tmuxEnabled = State(initialValue: true)
            _tmuxName = State(initialValue: "shuai")
            _startup = State(initialValue: "")
        case .edit(let p):
            original = p
            _id = State(initialValue: p.id)
            _name = State(initialValue: p.name)
            _host = State(initialValue: p.host)
            _portText = State(initialValue: String(p.port))
            _username = State(initialValue: p.username)
            switch p.auth {
            case .key(let k): _authKind = State(initialValue: .key); _keyID = State(initialValue: k)
            case .password: _authKind = State(initialValue: .password); _keyID = State(initialValue: "")
            case .ask: _authKind = State(initialValue: .ask); _keyID = State(initialValue: "")
            }
            _tmuxEnabled = State(initialValue: p.tmux.enabled)
            _tmuxName = State(initialValue: p.tmux.sessionName)
            _startup = State(initialValue: p.startupCommand ?? "")
        }
    }

    private var profile: HostProfile {
        let auth: HostAuth = switch authKind {
        case .key: .key(keyID: keyID)
        case .password: .password
        case .ask: .ask
        }
        let cmd = startup.trimmingCharacters(in: .whitespacesAndNewlines)
        return HostProfile(
            id: id, name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            host: host.trimmingCharacters(in: .whitespacesAndNewlines), port: Int(portText) ?? 0,
            username: username.trimmingCharacters(in: .whitespacesAndNewlines), auth: auth,
            tmux: TmuxPrefs(enabled: tmuxEnabled, sessionName: tmuxName),
            startupCommand: cmd.isEmpty ? nil : cmd, lastConnectedAt: original?.lastConnectedAt)
    }

    private var errors: Set<HostValidationError> { Set(profile.validationErrors) }

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    field("Name", text: $name, error: .name, message: "Enter a name.", id: "host-name-field")
                    field("Host or IP", text: $host, error: .host, message: "Enter a host name or IP address without spaces.", id: "host-address-field", keyboard: .URL)
                    field("Port", text: $portText, error: .port, message: "Port must be 1–65535.", id: "host-port-field", keyboard: .numberPad)
                    field("Username", text: $username, error: .username, message: "Enter a username.", id: "host-user-field")
                }
                Section("Authentication") {
                    Picker("Method", selection: $authKind) {
                        ForEach(AuthKind.allCases) { Text($0.rawValue).tag($0) }
                    }
                    switch authKind {
                    case .key:
                        if model.keys.items.isEmpty {
                            Text("No keys yet. Generate or import one in Keys.").foregroundStyle(.secondary)
                            NavigationLink("Open Keys", value: EditorPage.keys)
                                .accessibilityIdentifier("editor-open-keys")
                        } else {
                            Picker("Key", selection: $keyID) {
                                Text("Choose…").tag("")
                                ForEach(model.keys.items) { Text($0.name).tag($0.id) }
                            }
                            if attemptedSave, errors.contains(.key) { errorText("Choose a key.") }
                        }
                    case .password:
                        SecureField(original == nil ? "Password" : "Password (leave empty to keep)", text: $password)
                            .textContentType(.password)
                    case .ask:
                        Text("You are asked for the password every time you connect.").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section {
                    Toggle("Attach to tmux", isOn: $tmuxEnabled)
                    if tmuxEnabled {
                        field("Session name", text: $tmuxName, error: .tmuxSessionName, message: "Use a name without ':' or '.'.", id: "host-tmux-field")
                    }
                    TextField("Startup command (optional)", text: $startup)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                } header: {
                    Text("Session")
                } footer: {
                    Text("`tmux new -A -s NAME` keeps your session alive across disconnects. The startup command runs when the session is created.")
                }
                if let saveError { Section { errorText(saveError) } }
            }
            .navigationDestination(for: EditorPage.self) { _ in KeysView(placement: .pushed) }
            .navigationTitle(original == nil ? "New Host" : "Edit Host")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).accessibilityIdentifier("save-host-button")
                }
            }
            .onDisappear { password = "" }
        }
    }

    @ViewBuilder
    private func field(
        _ title: String, text: Binding<String>, error: HostValidationError, message: String, id: String,
        keyboard: UIKeyboardType = .default
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField(title, text: text)
                .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(keyboard)
                .accessibilityIdentifier(id)
            if attemptedSave, errors.contains(error) { errorText(message) }
        }
    }

    private func errorText(_ s: String) -> some View {
        Text(s).font(.caption).foregroundStyle(.red)
    }

    private func save() {
        attemptedSave = true
        guard errors.isEmpty else { return }
        let p = profile
        do {
            if original == nil { try model.hosts.add(p) } else { try model.hosts.update(p) }
            switch authKind {
            case .password:
                if !password.isEmpty { try model.passwords.setPassword(password, for: p.id) }
                password = ""
            case .key, .ask: try? model.passwords.deletePassword(for: p.id)
            }
            if model.selection == nil { model.selection = p.id }
            dismiss()
        } catch {
            saveError = "Could not save: \(error)"
        }
    }
}
