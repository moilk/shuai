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
            // A new controller (an edited profile) brings a new engine; the representable hosts
            // `engine.view` once, so the view is rebuilt with the controller.
            TerminalSessionView(controller: controller, engine: engine, host: host)
                .id(ObjectIdentifier(controller))
        }
    }
}

private struct TerminalSessionView: View {
    @Environment(AppModel.self) private var model
    let controller: SessionController
    let engine: GhosttyEngine
    let host: HostProfile
    @State private var areaWidth: CGFloat = 1000

    private var chrome: ChromeDecision {
        let topology = controller.tmux.topology
        return ChromePolicy.decide(ChromeInputs(
            hasTopology: topology != nil,
            windowCount: controller.tmuxActions.viewedSession?.windows.count ?? 0,
            sessionCount: topology?.sessions.count ?? 0,
            sidebarCollapsed: model.columnVisibility == .detailOnly, fullScreen: model.fullScreenActive,
            tabStrip: model.settings.tabStrip, preferFloatingBar: model.settings.accessoryBar == .floating,
            hardwareKeyboardBar: model.settings.hardwareKeyboardBar,
            hardwareKeyboard: model.keyboard.isConnected,
            softwareKeyboardVisible: model.keyboard.softwareKeyboardVisible,
            status: controller.state.status,
            permissionPendingForHost: model.agentHub.pendingPermissions.contains { $0.profileID == host.id }))
    }

    /// Connection strip, then notices. Permission cards are drawn on top in the trailing column,
    /// so the stack leaves that column free; when the area is too narrow for both, the stack moves
    /// to the bottom instead (`NoticeLayout`).
    private var topStack: some View {
        let cards = !model.agentHub.pendingPermissions.isEmpty
        let placement = NoticeLayout.placement(width: areaWidth, cardsPending: cards)
        return VStack(spacing: 8) {
            if placement == .bottom { Spacer() }
            connectionStrip
            NoticeStackView()
            if placement == .top { Spacer() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.trailing, NoticeLayout.reservedTrailing(width: areaWidth, cardsPending: cards))
        .padding()
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { areaWidth = geo.size.width }
                    .onChange(of: geo.size.width) { _, w in areaWidth = w }
            }
            .allowsHitTesting(false))
    }

    var body: some View {
        ZStack {
            Color(uiColor: UIColor(hex: model.settings.theme.terminalTheme.background)).ignoresSafeArea()
            TerminalContainerRepresentable(
                engine: engine, autoFocus: true,
                showsFloatingAccessoryBar: chrome.accessory == .floating,
                showsDockedAccessoryBar: chrome.accessory == .docked
            )
            .ignoresSafeArea(.keyboard)
            .accessibilityIdentifier("terminal-view")

            overlay
            topStack
            // Last, so a permission card is never covered by a notice.
            PermissionCardStack()
            if chrome.showsHandle, !chrome.showsTabStrip {
                fullScreenHandle.padding(8).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
        }
        .accessibilityAction(.escape) { if model.fullScreenActive { model.setFullScreen(false) } }
        .toolbar(chrome.showsNavigationBar ? .visible : .hidden, for: .navigationBar)
        .toolbarBackground(.chromeSurface, for: .navigationBar)
        .statusBarHidden(chrome.hidesStatusBar)
        .persistentSystemOverlays(chrome.hidesHomeIndicator ? .hidden : .automatic)
        .safeAreaInset(edge: .top, spacing: 0) {
            if chrome.showsTabStrip {
                WindowTabStrip(host: host, controller: controller, handle: chrome.showsHandle ? fullScreenHandle : nil)
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
                // Captured now: the dialog's dismissal clears the pending value right after this.
                guard let pending = actions.pendingConfirmation else { return }
                Task { await actions.run { try await actions.confirm(pending) } }
            }
            .accessibilityIdentifier("confirm-kill")
        } message: {
            Text(controller.tmuxActions.pendingConfirmation?.message ?? "")
        }
        .navigationTitle(controller.windowTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { connectionMenu }
        }
        .task(id: host.id) {
            #if DEBUG
            if DebugLaunch.agentFixture { await DebugLaunch.seedFixtureTerminal(engine); return }
            if DebugLaunch.connectionState != nil { return }
            #endif
            if controller.state == .idle { await controller.connect() }
        }
        .sheet(item: Binding(
            get: { controller.pendingPrompt.map(PromptItem.init) },
            set: { if $0 == nil { dismissPrompt() } }
        )) { item in
            PromptSheet(controller: controller, prompt: item.prompt)
                .presentationBackground(.chromeSurface)
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

    private var fullScreenHandle: FullScreenHandle {
        FullScreenHandle(
            presentation: presentation, prominent: chrome.handleIsProminent, connected: controller.state == .connected,
            disconnect: { Task { await controller.disconnect() } },
            reconnect: { Task { await controller.reconnect() } })
    }

    /// The status indicator opens a menu with the host's state and the one action that applies, so
    /// no single tap disconnects.
    private var connectionMenu: some View {
        Menu {
            Section {
                Text(verbatim: presentation.accessibilityLabel)
            }
            if controller.state == .connected {
                Button("Disconnect", systemImage: "bolt.slash", role: .destructive) {
                    Task { await controller.disconnect() }
                }
                .accessibilityIdentifier("disconnect-button")
            } else {
                Button("Reconnect", systemImage: "arrow.clockwise") {
                    Task { await controller.reconnect() }
                }
                .accessibilityIdentifier("connect-button")
            }
        } label: {
            StatusIndicator(presentation: presentation)
        }
        .accessibilityHint("Opens the connection menu")
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
        #if DEBUG
        if DebugLaunch.agentFixture && DebugLaunch.connectionState == nil { EmptyView() } else { connectionOverlay }
        #else
        connectionOverlay
        #endif
    }

    private var presentation: ConnectionPresentation {
        #if DEBUG
        if let fixed = DebugLaunch.connectionPresentation(hostName: host.name, target: host.displayTarget) { return fixed }
        #endif
        return ConnectionPresentation.make(controller.state, hostName: host.name, target: host.displayTarget)
    }

    @ViewBuilder private var connectionOverlay: some View {
        let p = presentation
        if p.placement == .card {
            ConnectionCard(presentation: p, perform: perform)
        }
    }

    /// Non-blocking states sit under the window tab strip and above the notices.
    @ViewBuilder private var connectionStrip: some View {
        let p = presentation
        if p.placement == .strip, !suppressesConnectionUI {
            ConnectionStrip(presentation: p, perform: perform)
        }
    }

    private var suppressesConnectionUI: Bool {
        #if DEBUG
        DebugLaunch.agentFixture && DebugLaunch.connectionState == nil
        #else
        false
        #endif
    }

    private func perform(_ action: ConnectionPresentation.Action) {
        switch action {
        case .retryNow: controller.retryNow()
        case .cancelReconnect: Task { await controller.cancelReconnect() }
        case .cancelConnect: Task { await controller.disconnect() }
        case .retry, .reconnect: Task { await controller.reconnect() }
        case .editHost: model.request(.editHost(host.id))
        case .openKeys: model.request(.keys)
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
                            .font(.headline).foregroundStyle(.chromeError)
                        Text("Someone may be eavesdropping on this connection (man-in-the-middle), or the server was reinstalled. Do not continue unless you know why the key changed.")
                            .foregroundStyle(.chromeError)
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
            .chromeForm()
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
            .chromeForm()
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
            .chromeForm()
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
