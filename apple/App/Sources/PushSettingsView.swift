import ShuaiApp
import SwiftUI
import UniformTypeIdentifiers

/// Background push through ntfy: the agent on the host posts a status-only message (what happened,
/// which host and tmux window) to a private topic; the official ntfy app shows it. Pushed inside
/// the Settings navigation stack.
struct PushSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var testResult: PushTestResult?
    @State private var testing = false
    @State private var confirmRegenerate = false
    @State private var copied = false
    @State private var revealed = false
    @State private var copiedReset: Task<Void, Never>?
    @Environment(\.scenePhase) private var scenePhase

    private static let rowHeight: CGFloat = 44

    var body: some View {
        @Bindable var push = model.pushSettings
        Form {
            Section {
                Toggle("Push notifications", isOn: $push.enabled)
                    .accessibilityIdentifier("push-enabled-toggle")
                DisclosureGroup("What is sent") {
                    Text("Pushes contain status only, such as “Claude needs approval” with the host and the tmux session and window number, never commands, prompts, messages or paths. tmux names windows after the command running in them, so window names are left out unless you turn on “Include tmux window names”. The default server is the public ntfy.sh; anyone who knows the topic can read these status messages, so keep it private, or use your own server and an access token. A new topic or turning push on or off reaches connected hosts right away; other changes on each host’s next connect, or with “Sync to connected hosts”.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } footer: {
                Text("Status-only pushes through ntfy when no shuai window is watching. Anyone with the topic can read them on a public server.")
            }

            Section {
                topicRow(push.topic)
                Button {
                    copyTopic(push.topic)
                } label: {
                    Label(copied ? "Copied" : "Copy topic", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .frame(maxWidth: .infinity, minHeight: Self.rowHeight, alignment: .leading)
                }
                .accessibilityIdentifier("push-copy-topic")
                Button { openNtfy(push) } label: {
                    Label("Open in ntfy app", systemImage: "arrow.up.forward.app")
                        .frame(maxWidth: .infinity, minHeight: Self.rowHeight, alignment: .leading)
                }
                .accessibilityIdentifier("push-open-ntfy")
                Button {
                    testing = true
                    testResult = nil
                    Task {
                        testResult = await push.sendTest()
                        testing = false
                    }
                } label: {
                    HStack {
                        Label("Send test notification", systemImage: "paperplane")
                        if testing { ProgressView() }
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, minHeight: Self.rowHeight, alignment: .leading)
                }
                .disabled(testing || push.serverValidation.url == nil)
                .accessibilityIdentifier("push-send-test")
                switch testResult {
                case .sent?:
                    Label("Sent. It should arrive in the ntfy app within seconds.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green).font(.footnote)
                case .failed(let m)?:
                    Label(m, systemImage: "xmark.octagon.fill").foregroundStyle(.red).font(.footnote)
                case nil: EmptyView()
                }
            } header: {
                Text("Subscribe")
            } footer: {
                Text("Subscribe to this topic in the free ntfy app from the App Store.")
            }

            Section("Server") {
                TextField("Server", text: $push.serverText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .frame(minHeight: Self.rowHeight)
                    .accessibilityIdentifier("push-server-field")
                switch push.serverValidation {
                case .invalid(let reason):
                    Label(reason.message, systemImage: "xmark.octagon.fill").foregroundStyle(.red).font(.footnote)
                case .insecure:
                    Label(NtfyServer.insecureWarning, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange).font(.footnote)
                case .valid: EmptyView()
                }
                SecureField("Access token (optional)", text: $push.token)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .frame(minHeight: Self.rowHeight)
                    .accessibilityIdentifier("push-token-field")
            }

            Section {
                Toggle("Include tmux window names", isOn: $push.includeWindowNames)
                    .accessibilityIdentifier("push-window-names-toggle")
            } header: {
                Text("Content")
            } footer: {
                Text("tmux names a window after the command running in it, so names are left out unless you turn this on.")
            }

            Section {
                Button { model.syncNotificationSettingsToConnectedHosts() } label: {
                    Label("Sync to connected hosts", systemImage: "arrow.triangle.2.circlepath")
                        .frame(maxWidth: .infinity, minHeight: Self.rowHeight, alignment: .leading)
                }
                .accessibilityIdentifier("push-sync")
            } header: {
                Text("Hosts")
            } footer: {
                Text("A new topic or turning push on or off reaches connected hosts right away; other changes on each host’s next connect, or with Sync.")
            }

            Section {
                Button(role: .destructive) { confirmRegenerate = true } label: {
                    Label("New topic…", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity, minHeight: Self.rowHeight, alignment: .leading)
                }
                .accessibilityIdentifier("push-regenerate")
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if !TopicRevealPolicy.shouldKeepRevealed(isActive: phase == .active) { revealed = false }
        }
        .onDisappear {
            revealed = false
            copiedReset?.cancel()
        }
        .navigationTitle("Background push (ntfy)")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Create a new topic?", isPresented: $confirmRegenerate, titleVisibility: .visible) {
            Button("New topic", role: .destructive) {
                push.regenerateTopic()
                testResult = nil
                revealed = false
            }
        } message: {
            Text("Connected hosts get the new topic right away, others on their next connect. Subscribe to the new topic in the ntfy app.")
        }
    }

    /// The topic is a secret: shown masked (also to VoiceOver) until the user reveals it.
    @ViewBuilder
    private func topicRow(_ topic: String) -> some View {
        HStack {
            Text("Topic").foregroundStyle(.secondary)
            Spacer(minLength: 8)
            if revealed {
                Text(topic).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                    .accessibilityIdentifier("push-topic")
            } else {
                Text(NtfyTopic.masked(topic)).font(.system(.footnote, design: .monospaced))
                    .accessibilityLabel(NtfyTopic.maskedSpoken(topic))
                    .accessibilityIdentifier("push-topic")
            }
            Button(revealed ? "Hide" : "Show") { revealed.toggle() }
                .buttonStyle(.borderless)
                .accessibilityLabel(revealed ? "Hide topic" : "Show topic")
                .accessibilityIdentifier("push-topic-reveal")
        }
        .frame(minHeight: Self.rowHeight)
    }

    private func copyTopic(_ topic: String) {
        // Expires after two minutes; not local-only, so Universal Clipboard keeps working.
        UIPasteboard.general.setItems(
            [[UTType.plainText.identifier: topic]],
            options: [.expirationDate: Date().addingTimeInterval(120)])
        copied = true
        copiedReset?.cancel()
        copiedReset = Task {
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { copied = false }
        }
    }

    private func openNtfy(_ push: PushSettings) {
        if let link = push.appLink {
            openURL(link) { accepted in
                if !accepted { openURL(PushSettings.appStoreURL) }
            }
        } else {
            openURL(PushSettings.appStoreURL)
        }
    }
}
