import ShuaiApp
import ShuaiCore
import ShuaiPlatform
import ShuaiTerminal
import SwiftUI

/// Detail column: the terminal of one host plus connection overlays and prompts.
struct TerminalScreen: View {
    @Environment(AppModel.self) private var model
    let host: HostProfile

    var body: some View {
        let controller = model.sessions.controller(for: host)
        if let engine = model.engine(for: host) {
            TerminalSessionView(controller: controller, engine: engine, host: host)
        }
    }
}

private struct TerminalSessionView: View {
    @Environment(AppModel.self) private var model
    let controller: SessionController
    let engine: GhosttyEngine
    let host: HostProfile

    private var useFloatingBar: Bool {
        model.keyboard.isConnected || model.settings.accessoryBar == .floating
    }

    var body: some View {
        ZStack {
            Color(uiColor: UIColor(hex: model.settings.theme.terminalTheme.background)).ignoresSafeArea()
            TerminalContainerRepresentable(
                engine: engine, autoFocus: true,
                showsFloatingAccessoryBar: useFloatingBar,
                showsDockedAccessoryBar: !useFloatingBar
            )
            .ignoresSafeArea(.keyboard)
            .accessibilityIdentifier("terminal-view")

            overlay
            VStack {
                if let error = controller.tmuxActions.lastError {
                    NoticeView(text: error) { controller.tmuxActions.lastError = nil }
                        .task(id: error) {
                            try? await Task.sleep(for: .seconds(5))
                            controller.tmuxActions.lastError = nil
                        }
                }
                if let notice = controller.notice {
                    NoticeView(text: notice) { controller.dismissNotice() }
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                if let banner = controller.banner {
                    BannerView(note: banner) { controller.dismissBanner() }
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                Spacer()
            }
            .padding()
            .animation(.snappy, value: controller.banner)
            .animation(.snappy, value: controller.notice)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if model.columnVisibility == .detailOnly, controller.tmux.topology != nil {
                WindowTabStrip(host: host, controller: controller)
            }
        }
        .onAppear { bindShortcuts() }
        .onChange(of: model.shortcuts) { _, _ in bindShortcuts() }
        .confirmationDialog(
            controller.tmuxActions.pendingConfirmation?.title ?? "", isPresented: Binding(
                get: { controller.tmuxActions.pendingConfirmation != nil },
                set: { if !$0 { controller.tmuxActions.cancelPending() } }),
            titleVisibility: .visible
        ) {
            Button("Close", role: .destructive) {
                let actions = controller.tmuxActions
                Task { await actions.run { try await actions.confirmPending() } }
            }
            .accessibilityIdentifier("confirm-kill")
        } message: {
            Text(controller.tmuxActions.pendingConfirmation?.message ?? "")
        }
        .navigationTitle(controller.windowTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                StatusBadge(state: controller.state)
                if controller.state == .connected {
                    Button { Task { await controller.disconnect() } } label: { Label("Disconnect", systemImage: "xmark.circle") }
                        .accessibilityIdentifier("disconnect-button")
                } else {
                    Button { Task { await controller.reconnect() } } label: { Label("Connect", systemImage: "arrow.clockwise") }
                        .accessibilityIdentifier("connect-button")
                }
            }
        }
        .task(id: host.id) {
            if controller.state == .idle { await controller.connect() }
        }
        .sheet(item: Binding(
            get: { controller.pendingPrompt.map(PromptItem.init) },
            set: { if $0 == nil { dismissPrompt() } }
        )) { item in
            PromptSheet(controller: controller, prompt: item.prompt)
                .interactiveDismissDisabled()
        }
        .alert(clipboardTitle, isPresented: Binding(
            get: { controller.pendingClipboard != nil },
            set: { if !$0 { controller.pendingClipboard?.respond(allow: false); controller.pendingClipboard = nil } }
        )) {
            Button("Allow") { controller.pendingClipboard?.respond(allow: true); controller.pendingClipboard = nil }
            Button("Deny", role: .cancel) { controller.pendingClipboard?.respond(allow: false); controller.pendingClipboard = nil }
        } message: {
            Text(String((controller.pendingClipboard?.contents ?? "").prefix(300)))
        }
        .onChange(of: model.settings.theme) { _, _ in model.applyTheme() }
        #if DEBUG
        .task(id: controller.pendingPrompt) { await DebugLaunch.autoAnswer(controller: controller) }
        .task(id: controller.state) { await DebugLaunch.sendAfterConnect(controller: controller) }
        #endif
    }

    /// Delivers the shortcut map to the terminal view as key commands (first-responder only).
    private func bindShortcuts() {
        engine.view.keyBindings = model.shortcuts.terminalBindings
        engine.view.onKeyBinding = { [weak model] id in
            guard let model else { return }
            model.handleShortcut(id: id, host: host)
        }
    }

    private var clipboardTitle: String {
        switch controller.pendingClipboard?.kind {
        case .osc52Read: "The remote wants to read your clipboard"
        case .osc52Write: "The remote wants to write your clipboard"
        default: "Paste confirmation"
        }
    }

    /// Dismissing a prompt without answering rejects it.
    private func dismissPrompt() {
        switch controller.pendingPrompt {
        case .hostKey: controller.answerHostKey(accept: false)
        case .password: controller.answerPassword(nil)
        case .keyboardInteractive: controller.answerKeyboardInteractive(nil)
        case nil: break
        }
    }

    @ViewBuilder private var overlay: some View {
        switch controller.state {
        case .connecting, .authenticating, .hostKeyPrompt:
            ProgressCard(title: "Connecting to \(host.name)…", detail: host.displayTarget)
        case .reconnecting(let attempt, let retryAt):
            ReconnectOverlay(
                attempt: attempt, retryAt: retryAt,
                retryNow: { controller.retryNow() },
                cancel: { Task { await controller.cancelReconnect() } })
        case .failed(let error):
            ConnectionErrorView(
                error: error, host: host,
                retry: { Task { await controller.reconnect() } },
                edit: { model.editor = .edit(host) },
                openKeys: { model.showKeys = true })
        case .disconnected(let status):
            DisconnectedView(status: status) { Task { await controller.reconnect() } }
        case .idle, .connected:
            EmptyView()
        }
    }
}

private struct PromptItem: Identifiable {
    let prompt: SessionPrompt
    var id: String {
        switch prompt {
        case .hostKey(let c): "hostkey-\(c.fingerprint)"
        case .password: "password"
        case .keyboardInteractive(let n, _, _): "kbd-\(n)"
        }
    }
}

private extension UIColor {
    convenience init(hex rgb: TerminalRGB) {
        self.init(red: CGFloat(rgb.r) / 255, green: CGFloat(rgb.g) / 255, blue: CGFloat(rgb.b) / 255, alpha: 1)
    }
}

// MARK: - Overlays

private struct ProgressCard: View {
    let title: String
    let detail: String
    var body: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text(title).font(.headline)
            Text(detail).font(.footnote).foregroundStyle(.secondary)
        }
        .padding(24)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityIdentifier("connecting-card")
    }
}

struct ReconnectOverlay: View {
    let attempt: Int
    let retryAt: Date?
    let retryNow: () -> Void
    let cancel: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView()
                Text("Reconnecting…").font(.title3.bold())
                Group {
                    if let retryAt {
                        TimelineView(.periodic(from: .now, by: 1)) { ctx in
                            let s = max(0, Int(retryAt.timeIntervalSince(ctx.date).rounded(.up)))
                            Text("Attempt \(attempt) · retrying in \(s)s")
                        }
                    } else {
                        Text("Attempt \(attempt)")
                    }
                }
                .font(.subheadline).foregroundStyle(.secondary)
                HStack {
                    Button("Retry now", action: retryNow).buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("retry-now")
                    Button("Cancel", role: .cancel, action: cancel).buttonStyle(.bordered)
                        .accessibilityIdentifier("cancel-reconnect")
                }
            }
            .padding(24)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("reconnect-overlay")
    }
}

struct ConnectionErrorView: View {
    let error: SessionError
    let host: HostProfile
    let retry: () -> Void
    let edit: () -> Void
    let openKeys: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            ContentUnavailableView {
                Label("Can't connect to \(host.name)", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            } description: {
                Text(error.message)
            } actions: {
                Button("Retry", action: retry).buttonStyle(.borderedProminent).accessibilityIdentifier("retry-connect")
                switch error.kind {
                case .authFailed: Button("Edit host", action: edit)
                case .keyMissing: Button("Open keys", action: openKeys)
                default: EmptyView()
                }
            }
            .frame(maxWidth: 480)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        }
        .accessibilityIdentifier("connection-error")
    }
}

private struct DisconnectedView: View {
    let status: Int?
    let reconnect: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Text(status.map { "Session ended (exit status \($0))" } ?? "Disconnected").font(.headline)
            Button("Reconnect", action: reconnect).buttonStyle(.borderedProminent)
        }
        .padding(20)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityIdentifier("disconnected-card")
    }
}

private struct StatusBadge: View {
    let state: SessionState
    var body: some View {
        Circle().fill(color).frame(width: 10, height: 10).accessibilityHidden(true)
    }
    private var color: Color {
        switch state.status {
        case .off: .gray
        case .busy: .yellow
        case .connected: .green
        case .warning: .orange
        case .error: .red
        }
    }
}

/// Non-blocking info banner (the terminal stays usable underneath).
private struct NoticeView: View {
    let text: String
    let dismiss: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle.fill")
            Text(text).font(.subheadline)
            Spacer()
            Button(action: dismiss) { Image(systemName: "xmark") }
        }
        .padding(12)
        .frame(maxWidth: 520)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("session-notice")
    }
}

private struct BannerView: View {
    let note: TerminalNotification
    let dismiss: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "bell.fill")
            VStack(alignment: .leading) {
                if !note.title.isEmpty { Text(note.title).font(.headline) }
                if !note.body.isEmpty { Text(note.body).font(.subheadline) }
            }
            Spacer()
            Button(action: dismiss) { Image(systemName: "xmark") }
        }
        .padding(12)
        .frame(maxWidth: 520)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .task(id: note) {
            try? await Task.sleep(for: .seconds(6))
            dismiss()
        }
        .accessibilityIdentifier("notification-banner")
    }
}

// MARK: - Prompts

private struct PromptSheet: View {
    let controller: SessionController
    let prompt: SessionPrompt

    var body: some View {
        switch prompt {
        case .hostKey(let challenge): HostKeySheet(controller: controller, challenge: challenge)
        case .password(let host, let user): PasswordSheet(controller: controller, host: host, user: user)
        case .keyboardInteractive(let name, let instructions, let prompts):
            KeyboardInteractiveSheet(controller: controller, name: name, instructions: instructions, prompts: prompts)
        }
    }
}

private struct HostKeySheet: View {
    let controller: SessionController
    let challenge: HostKeyChallenge

    var body: some View {
        NavigationStack {
            Form {
                switch challenge.kind {
                case .unknown:
                    Section {
                        Text("The authenticity of \(challenge.host) can't be established. Check this fingerprint against your server (`ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub`) before trusting it.")
                    }
                    Section("Fingerprint (SHA256)") { fingerprint(challenge.fingerprint) }
                    Section {
                        Button("Trust and connect") { controller.answerHostKey(accept: true) }
                            .accessibilityIdentifier("trust-host-key")
                        Button("Cancel", role: .cancel) { controller.answerHostKey(accept: false) }
                            .accessibilityIdentifier("reject-host-key")
                    }
                case .changed(let expected):
                    Section {
                        Label("The host key has CHANGED", systemImage: "exclamationmark.octagon.fill")
                            .font(.headline).foregroundStyle(.red)
                        Text("Someone may be eavesdropping on this connection (man-in-the-middle), or the server was reinstalled. Do not continue unless you know why the key changed.")
                            .foregroundStyle(.red)
                    }
                    Section("Recorded fingerprint(s)") {
                        ForEach(expected, id: \.self) { fingerprint($0) }
                    }
                    Section("Presented by server now") { fingerprint(challenge.fingerprint) }
                    Section {
                        Button("Reject connection", role: .cancel) { controller.answerHostKey(accept: false) }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("reject-host-key")
                        Button("Replace saved key and connect", role: .destructive) { controller.answerHostKey(accept: true) }
                            .accessibilityIdentifier("replace-host-key")
                    }
                }
            }
            .navigationTitle(challenge.kind == .unknown ? "New host" : "Host key changed")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
        .accessibilityIdentifier("host-key-sheet")
    }

    private func fingerprint(_ s: String) -> some View {
        Text(s).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
    }
}

private struct PasswordSheet: View {
    let controller: SessionController
    let host: String
    let user: String
    @State private var password = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section("Password for \(user)@\(host)") {
                    SecureField("Password", text: $password)
                        .focused($focused)
                        .textContentType(.password)
                        .onSubmit(submit)
                        .accessibilityIdentifier("password-field")
                }
            }
            .navigationTitle("Authenticate")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { password = ""; controller.answerPassword(nil) } }
                ToolbarItem(placement: .confirmationAction) { Button("Connect", action: submit).disabled(password.isEmpty) }
            }
            .onAppear { focused = true }
            .onDisappear { password = "" }
        }
        .presentationDetents([.height(260)])
    }

    private func submit() {
        guard !password.isEmpty else { return }
        let typed = password
        password = ""
        controller.answerPassword(typed)
    }
}

private struct KeyboardInteractiveSheet: View {
    let controller: SessionController
    let name: String
    let instructions: String
    let prompts: [FfiKbdPrompt]
    @State private var answers: [String]

    init(controller: SessionController, name: String, instructions: String, prompts: [FfiKbdPrompt]) {
        self.controller = controller
        self.name = name
        self.instructions = instructions
        self.prompts = prompts
        _answers = State(initialValue: Array(repeating: "", count: prompts.count))
    }

    var body: some View {
        NavigationStack {
            Form {
                if !instructions.isEmpty { Section { Text(instructions) } }
                ForEach(prompts.indices, id: \.self) { i in
                    Section(prompts[i].prompt) {
                        if prompts[i].echo {
                            TextField("", text: $answers[i]).textInputAutocapitalization(.never).autocorrectionDisabled()
                        } else {
                            SecureField("", text: $answers[i])
                        }
                    }
                }
            }
            .navigationTitle(name.isEmpty ? "Authentication" : name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { controller.answerKeyboardInteractive(nil) } }
                ToolbarItem(placement: .confirmationAction) { Button("Submit") { controller.answerKeyboardInteractive(answers) } }
            }
        }
        .presentationDetents([.medium])
    }
}
