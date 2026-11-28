import ShuaiApp
import ShuaiTerminal
import SwiftUI

struct HostEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private enum EditorPage: Hashable { case keys }

    private struct ConnectionInputs: Equatable {
        let host: String
        let port: String
        let user: String
        let authentication: HostEditorDraft.AuthKind
        let key: String?
        let password: String?
    }

    private static let keyRow = "editor-key-row"

    private let editing: Bool
    /// Stable for the editor's lifetime: the sheet content is rebuilt when the app model changes,
    /// so the host id, the initial snapshot and the save progress live in `@State`.
    @State private var save: HostEditorSave
    @State private var draft: HostEditorDraft
    @State private var validation = HostEditorValidation()
    /// Held only here and written only to the Keychain; never part of the draft.
    @State private var password = ""
    @State private var saveError: String?
    @State private var confirmDiscard = false
    @State private var scrollTarget: String?
    @State private var announcement: Task<Void, Never>?
    @State private var probe: SessionController?
    @State private var verifiedInputs: ConnectionInputs?
    @State private var tmuxSessions: [String]?
    @State private var useCustomSession = false
    @FocusState private var focus: HostValidationError?

    init(target: HostEditorTarget, keyIDs: [String] = []) {
        let s: HostEditorSave
        switch target {
        case .new:
            editing = false
            s = HostEditorSave(new: keyIDs)
        case .edit(let p):
            editing = true
            s = HostEditorSave(editing: p)
        }
        _save = State(initialValue: s)
        _draft = State(initialValue: s.initial)
    }

    private var isDirty: Bool {
        HostEditorDirty.needsConfirmation(initial: save.initial, current: draft, passwordTyped: !password.isEmpty)
    }

    private var connectionInputs: ConnectionInputs {
        ConnectionInputs(
            host: draft.host, port: draft.portText, user: draft.username, authentication: draft.authKind,
            key: draft.authKind == .key ? draft.keyID : nil,
            password: draft.authKind == .password && !password.isEmpty ? password : nil)
    }

    private var connectionVerified: Bool { verifiedInputs == connectionInputs }


    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                form
                    .disabled(probe != nil)
                    .onChange(of: scrollTarget) { _, target in
                        guard let target else { return }
                        withAnimation { proxy.scrollTo(target, anchor: .center) }
                        scrollTarget = nil
                    }
            }
            .navigationDestination(for: EditorPage.self) { _ in
                KeysView(placement: .pushed, onAdded: { item in draft.keyID = item.id })
            }
            .navigationTitle(editing ? "Edit Host" : "New Host")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(probe != nil ? "Stop Testing" : "Cancel") {
                        if probe != nil { cancelProbe() }
                        else if isDirty { confirmDiscard = true }
                        else { close() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: attemptSave)
                        .accessibilityIdentifier("save-host-button")
                        .disabled(probe != nil)
                }
            }
            .confirmationDialog("Discard changes?", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("Discard Changes", role: .destructive) { discard() }
                    .accessibilityIdentifier("discard-changes")
                // No `.cancel` role: iPad's popover presentation omits cancel-role buttons.
                Button("Keep Editing") {}
                    .accessibilityIdentifier("keep-editing")
            } message: {
                Text(save.discardMessage)
            }
            .interactiveDismissDisabled(isDirty)
            .onChange(of: focus) { old, _ in
                if let old { validation.blur(old) }
            }
            .onChange(of: connectionInputs) { invalidateVerification() }
            .onChange(of: model.keys.items.map(\.id)) { _, ids in
                if draft.authKind == .key && !ids.contains(draft.keyID) { draft.keyID = "" }
            }
            .sheet(item: Binding(
                get: { probe?.pendingPrompt.map(PromptItem.init) },
                set: { _ in }
            )) { item in
                if let probe {
                    PromptSheet(controller: probe, prompt: item.prompt)
                        .presentationBackground(.chromeSurface)
                        .interactiveDismissDisabled()
                }
            }
            .onChange(of: isDirty, initial: true) { _, dirty in model.editorIsDirty = dirty }
        }
        // On the stack itself: its root content disappears when a page is pushed, the stack only
        // when the sheet goes away.
        .onDisappear {
            announcement?.cancel()
            cancelProbe()
            password = ""
            model.editorIsDirty = false
        }
    }

    private var form: some View {
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
                        Text("No keys yet.").foregroundStyle(.chromeSecondary).id(Self.keyRow)
                        errorLabel(.key)
                    } else {
                        Picker("Key", selection: $draft.keyID) {
                            Text("Choose…").tag("")
                            ForEach(model.keys.items) { Text($0.name).tag($0.id) }
                        }
                        .id(Self.keyRow)
                        errorLabel(.key)
                    }
                    NavigationLink(value: EditorPage.keys) {
                        Label("Add or Import SSH Key", systemImage: "key")
                    }
                    .accessibilityIdentifier("editor-open-keys")
                    if let key = model.keys.items.first(where: { $0.id == draft.keyID }) {
                        ShareLink(item: key.publicLine) { Label("Share Public Key", systemImage: "square.and.arrow.up") }
                    }
                case .password:
                    SecureField(editing ? "Password (leave empty to keep)" : "Password", text: $password)
                        .textContentType(.password)
                case .ask:
                    Text("You are asked for the password every time you connect.").font(.footnote).foregroundStyle(.chromeSecondary)
                }
            }
            Section {
                Button(action: testConnection) {
                    if probe != nil {
                        ProgressView("Testing SSH connection…")
                    } else {
                        Label(connectionVerified ? "Test Again" : "Test Connection", systemImage: "network")
                    }
                }
                .accessibilityIdentifier("test-host-button")
                if connectionVerified {
                    Label("SSH connection verified", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.chromeSecondary)
                }
                if let saveError {
                    errorText(saveError).accessibilityIdentifier("host-connection-error")
                }
            } footer: {
                if !editing { Text("Verify the SSH connection before saving this host.") }
            }
            Section {
                Toggle("Attach to tmux", isOn: $draft.tmuxEnabled)
                if draft.tmuxEnabled {
                    if let sessions = tmuxSessions, !sessions.isEmpty {
                        Picker("Session", selection: Binding<String?>(
                            get: { !useCustomSession && sessions.contains(draft.tmuxName) ? draft.tmuxName : nil },
                            set: { choice in
                                useCustomSession = choice == nil
                                if let choice { draft.tmuxName = choice }
                                else if sessions.contains(draft.tmuxName) { draft.tmuxName = "" }
                            }
                        )) {
                            ForEach(sessions, id: \.self) { Text($0).tag(Optional($0)) }
                            Text("Enter a session name").tag(nil as String?)
                        }
                    }
                    if useCustomSession || !(tmuxSessions?.contains(draft.tmuxName) ?? false) {
                        field("Session name", text: $draft.tmuxName, error: .tmuxSessionName, id: "host-tmux-field")
                    }
                }
                TextField("Startup command (optional)", text: $draft.startup)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            } header: {
                Text("Session")
            } footer: {
                if draft.tmuxEnabled && connectionVerified && (tmuxSessions?.isEmpty ?? true) {
                    Text("No tmux sessions were found. Enter a name to create one when you connect. If tmux is unavailable, Shuai opens a shell.")
                } else {
                    Text("The startup command runs when a new session is created.")
                }
            }
        }
        .chromeForm()
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
        Label(s, systemImage: "exclamationmark.circle.fill").font(.caption).foregroundStyle(.chromeError)
    }

    private func discard() {
        // A new host that an earlier Save already stored stays; make it reachable.
        if save.keepsSavedNewHost, model.selection == nil { model.selection = save.id }
        close()
    }

    private func close() {
        password = ""
        model.editorIsDirty = false
        dismiss()
    }

    private func invalidateVerification() {
        verifiedInputs = nil
        tmuxSessions = nil
        useCustomSession = false
        saveError = nil
    }

    private func cancelProbe() {
        guard let active = probe else { return }
        probe = nil
        Task { await active.disconnect() }
    }

    private func testConnection() {
        saveError = nil
        if let first = draft.errors.first(where: { $0 != .name && $0 != .tmuxSessionName }) {
            validation.blur(first)
            reveal(first)
            return
        }
        invalidateVerification()
        focus = nil
        let profile = draft.profile(id: save.id, lastConnectedAt: nil)
        let controller = model.sessions.verificationController(for: profile, engine: GhosttyEngine())
        let inputs = connectionInputs
        probe = controller
        Task {
            guard probe === controller else { return }
            do {
                let names = try await controller.verifyAccess(password: inputs.password)
                guard probe === controller else { return }
                probe = nil
                guard connectionInputs == inputs else { return }
                tmuxSessions = names
                if !editing, draft.tmuxName == save.initial.tmuxName,
                   let names, !names.contains(draft.tmuxName), let first = names.first {
                    draft.tmuxName = first
                }
                verifiedInputs = inputs
            } catch {
                guard probe === controller else { return }
                saveError = SessionError(error).message
                probe = nil
            }
        }
    }

    private func reveal(_ first: HostValidationError) {
        // The key choice is a picker, which takes no text focus: scroll to it instead.
        if first == .key { scrollTarget = Self.keyRow } else { focus = first }
        let message = first.message
        // Let VoiceOver finish announcing the focus change before the message.
        announcement?.cancel()
        announcement = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            AccessibilityNotification.Announcement(message).post()
        }
    }

    private func attemptSave() {
        saveError = nil
        if !editing && !connectionVerified {
            if let first = draft.errors.first(where: { $0 != .tmuxSessionName }) {
                validation.blur(first)
                reveal(first)
            } else {
                testConnection()
            }
            return
        }
        if let first = validation.attemptSave(draft) {
            reveal(first)
            return
        }
        let result = save.attempt(
            draft, password: password, lastConnectedAt: model.hosts.host(id: save.id)?.lastConnectedAt,
            writeHost: { p, step in
                switch step {
                case .add: try model.hosts.add(p)
                case .update: try model.hosts.update(p)
                }
            },
            setPassword: { pw, id in try model.passwords.setPassword(pw, for: id) },
            deletePassword: { id in _ = try? model.passwords.deletePassword(for: id) })
        switch result {
        case .saved(let p):
            if model.selection == nil { model.selection = p.id }
            close()
        case .failed(let message):
            saveError = message
        }
    }
}
