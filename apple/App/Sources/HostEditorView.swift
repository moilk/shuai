import ShuaiApp
import SwiftUI

struct HostEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private enum EditorPage: Hashable { case keys }

    private let original: HostProfile?
    private let id: UUID
    private let initial: HostEditorDraft
    @State private var draft: HostEditorDraft
    @State private var validation = HostEditorValidation()
    /// Held only here and written only to the Keychain; never part of the draft.
    @State private var password = ""
    @State private var saveError: String?
    @State private var hostPersisted = false
    @State private var confirmDiscard = false
    @FocusState private var focus: HostValidationError?

    init(target: HostEditorTarget, keyIDs: [String] = []) {
        switch target {
        case .new:
            original = nil
            id = UUID()
            initial = HostEditorDraft(new: keyIDs)
        case .edit(let p):
            original = p
            id = p.id
            initial = HostEditorDraft(editing: p)
        }
        _draft = State(initialValue: initial)
    }

    private var keyIDs: [String] { model.keys.items.map(\.id) }

    private var isDirty: Bool {
        HostEditorDirty.needsConfirmation(initial: initial, current: draft, passwordTyped: !password.isEmpty)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    field("Name", text: $draft.name, error: .name, id: "host-name-field")
                    field("Host or IP", text: $draft.host, error: .host, id: "host-address-field", keyboard: .URL)
                    field("Port", text: $draft.portText, error: .port, id: "host-port-field", keyboard: .numberPad)
                    field("Username", text: $draft.username, error: .username, id: "host-user-field")
                }
                Section("Authentication") {
                    Picker("Method", selection: $draft.authKind) {
                        ForEach(HostEditorDraft.AuthKind.allCases) { Text($0.rawValue).tag($0) }
                    }
                    switch draft.authKind {
                    case .key:
                        if model.keys.items.isEmpty {
                            Text("No keys yet.").foregroundStyle(.secondary)
                        } else {
                            Picker("Key", selection: $draft.keyID) {
                                Text("Choose…").tag("")
                                ForEach(model.keys.items) { Text($0.name).tag($0.id) }
                            }
                            errorLabel(.key)
                        }
                    case .password:
                        SecureField(original == nil ? "Password" : "Password (leave empty to keep)", text: $password)
                            .textContentType(.password)
                    case .ask:
                        Text("You are asked for the password every time you connect.").font(.footnote).foregroundStyle(.secondary)
                    }
                    if model.keys.items.isEmpty {
                        NavigationLink("Generate a key", value: EditorPage.keys)
                            .accessibilityIdentifier("editor-open-keys")
                    }
                }
                Section {
                    Toggle("Attach to tmux", isOn: $draft.tmuxEnabled)
                    if draft.tmuxEnabled {
                        field("Session name", text: $draft.tmuxName, error: .tmuxSessionName, id: "host-tmux-field")
                    }
                    TextField("Startup command (optional)", text: $draft.startup)
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
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { if isDirty { confirmDiscard = true } else { dismiss() } }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).accessibilityIdentifier("save-host-button")
                }
            }
            .confirmationDialog("Discard your changes?", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("Discard Changes", role: .destructive) { dismiss() }
                    .accessibilityIdentifier("discard-changes")
                Button("Keep Editing", role: .cancel) {}
                    .accessibilityIdentifier("keep-editing")
            }
            .interactiveDismissDisabled(isDirty)
            .onChange(of: focus) { old, _ in
                if let old { validation.blur(old) }
            }
            .onChange(of: model.keys.items.map(\.id)) { old, new in
                draft = draft.adoptingNewKey(before: old, after: new)
            }
            .onChange(of: isDirty, initial: true) { _, dirty in model.editorIsDirty = dirty }
            .onDisappear {
                password = ""
                model.editorIsDirty = false
            }
        }
    }

    @ViewBuilder
    private func field(
        _ title: String, text: Binding<String>, error: HostValidationError, id: String,
        keyboard: UIKeyboardType = .default
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField(title, text: text)
                .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(keyboard)
                .focused($focus, equals: error)
                .accessibilityIdentifier(id)
            errorLabel(error)
        }
    }

    @ViewBuilder
    private func errorLabel(_ error: HostValidationError) -> some View {
        if let message = validation.visibleMessage(for: error, in: draft) { errorText(message) }
    }

    private func errorText(_ s: String) -> some View {
        Label(s, systemImage: "exclamationmark.circle.fill").font(.caption).foregroundStyle(.red)
    }

    private func save() {
        saveError = nil
        if let first = validation.attemptSave(draft) {
            focus = first
            AccessibilityNotification.Announcement(first.message).post()
            return
        }
        let p = draft.profile(id: id, lastConnectedAt: original?.lastConnectedAt)
        do {
            if original == nil, !hostPersisted { try model.hosts.add(p) } else { try model.hosts.update(p) }
            hostPersisted = true
            switch draft.authKind {
            case .password:
                if !password.isEmpty { try model.passwords.setPassword(password, for: p.id) }
                password = ""
            case .key, .ask: try? model.passwords.deletePassword(for: p.id)
            }
            if model.selection == nil { model.selection = p.id }
            dismiss()
        } catch {
            saveError = HostEditorSaveError.message(for: error, hostSaved: hostPersisted)
        }
    }
}
