import ShuaiApp
import SwiftUI

struct HostEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private enum EditorPage: Hashable { case keys }

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

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                form
                    .onChange(of: scrollTarget) { _, target in
                        guard let target else { return }
                        withAnimation { proxy.scrollTo(target, anchor: .center) }
                        scrollTarget = nil
                    }
            }
            .navigationDestination(for: EditorPage.self) { _ in KeysView(placement: .pushed) }
            .navigationTitle(editing ? "Edit Host" : "New Host")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { if isDirty { confirmDiscard = true } else { close() } }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: attemptSave).accessibilityIdentifier("save-host-button")
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
            .onChange(of: model.keys.items.map(\.id)) { old, new in
                draft = draft.adoptingNewKey(before: old, after: new)
            }
            .onChange(of: isDirty, initial: true) { _, dirty in model.editorIsDirty = dirty }
        }
        // On the stack itself: its root content disappears when a page is pushed, the stack only
        // when the sheet goes away.
        .onDisappear {
            announcement?.cancel()
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
                        NavigationLink("Generate a key", value: EditorPage.keys)
                            .accessibilityIdentifier("editor-open-keys")
                    } else {
                        Picker("Key", selection: $draft.keyID) {
                            Text("Choose…").tag("")
                            ForEach(model.keys.items) { Text($0.name).tag($0.id) }
                        }
                        .id(Self.keyRow)
                        errorLabel(.key)
                    }
                case .password:
                    SecureField(editing ? "Password (leave empty to keep)" : "Password", text: $password)
                        .textContentType(.password)
                case .ask:
                    Text("You are asked for the password every time you connect.").font(.footnote).foregroundStyle(.chromeSecondary)
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

    private func attemptSave() {
        saveError = nil
        if let first = validation.attemptSave(draft) {
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
