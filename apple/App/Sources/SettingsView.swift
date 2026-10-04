import ShuaiApp
import ShuaiTerminal
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var settings = model.settings
        NavigationStack {
            Form {
                Section("Terminal") {
                    Picker("Theme", selection: $settings.theme) {
                        Text("Dark").tag(AppSettings.Theme.dark)
                        Text("Light").tag(AppSettings.Theme.light)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: settings.theme) { _, _ in model.applyTheme() }
                    Stepper(
                        "Font size: \(settings.fontSize) pt", value: $settings.fontSize,
                        in: FontSizeModel.range)
                    Text("Font size applies to sessions opened afterwards. Pinch or ⌘+ / ⌘− zoom an open terminal.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Keyboard") {
                    Picker("Accessory bar", selection: $settings.accessoryBar) {
                        Text("Docked above keyboard").tag(AppSettings.AccessoryBarStyle.docked)
                        Text("Floating").tag(AppSettings.AccessoryBarStyle.floating)
                    }
                    Toggle("Option key sends Alt (Esc prefix)", isOn: $settings.optionAsAlt)
                    Text("With a hardware keyboard the compact floating bar is always used. Option-as-Alt applies to sessions opened afterwards.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("AI integration") {
                    Toggle("Notify when an agent needs me", isOn: Binding(
                        get: { settings.notificationsEnabled },
                        set: { on in
                            if on { model.enableNotifications() } else { settings.notificationsEnabled = false }
                        }))
                    Text("Local notifications while the app is in the background. iOS suspends apps soon after you leave them, so this is best effort.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                PushSettingsSection()
                Section("SSH") {
                    Button("Manage keys…") { dismiss(); model.showKeys = true }
                }
                Section("About") {
                    LabeledContent("Core", value: coreVersionString)
                    LabeledContent("Terminal engine", value: "libghostty")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private var coreVersionString: String {
        // Resolved lazily to keep this view free of FFI imports in previews.
        CoreInfo.version
    }
}

/// Background push through ntfy: the agent on the host posts a status-only message (what happened,
/// which host and tmux window) to a private topic; the official ntfy app shows it.
private struct PushSettingsSection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var testResult: PushTestResult?
    @State private var testing = false
    @State private var confirmRegenerate = false
    @State private var copied = false

    var body: some View {
        @Bindable var push = model.pushSettings
        Section {
            Toggle("Push notifications (ntfy)", isOn: $push.enabled)
                .accessibilityIdentifier("push-enabled-toggle")
            TextField("Server", text: $push.serverText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .accessibilityIdentifier("push-server-field")
            switch push.serverValidation {
            case .invalid(let reason):
                Label(reason.message, systemImage: "xmark.octagon.fill").foregroundStyle(.red).font(.footnote)
            case .insecure:
                Label(NtfyServer.insecureWarning, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.footnote)
            case .valid: EmptyView()
            }
            LabeledContent("Topic") {
                Text(push.topic).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                    .accessibilityIdentifier("push-topic")
            }
            HStack {
                Button(copied ? "Copied" : "Copy topic", systemImage: "doc.on.doc") {
                    UIPasteboard.general.string = push.topic
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(2)); copied = false }
                }
                Spacer()
                Button("New topic", systemImage: "arrow.clockwise", role: .destructive) { confirmRegenerate = true }
                    .accessibilityIdentifier("push-regenerate")
            }
            .buttonStyle(.borderless)
            SecureField("Access token (optional)", text: $push.token)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("push-token-field")
            Button("Open in ntfy app", systemImage: "arrow.up.forward.app") { openNtfy(push) }
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
                }
            }
            .disabled(testing || push.serverValidation.url == nil)
            .accessibilityIdentifier("push-send-test")
            switch testResult {
            case .sent?: Label("Sent. It should arrive in the ntfy app within seconds.", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.footnote)
            case .failed(let m)?: Label(m, systemImage: "xmark.octagon.fill").foregroundStyle(.red).font(.footnote)
            case nil: EmptyView()
            }
            Button("Sync to connected hosts", systemImage: "arrow.triangle.2.circlepath") { model.syncNotificationSettingsToConnectedHosts() }
                .accessibilityIdentifier("push-sync")
        } header: {
            Text("Background notifications")
        } footer: {
            Text("When no Shuai window is watching, the agent on your host sends a push through ntfy. The official ntfy app (free, from the App Store) shows it; subscribe to the topic above with “Open in ntfy app”. Pushes contain status only, such as “Claude needs approval” and the host and tmux window name, never commands, prompts, messages or paths. The default server is the public ntfy.sh; anyone who knows the topic can read these status messages, so keep it private, or use your own server and an access token. Changes reach each host on its next connect, or right away with “Sync to connected hosts”.")
        }
        .confirmationDialog("Create a new topic?", isPresented: $confirmRegenerate, titleVisibility: .visible) {
            Button("New topic", role: .destructive) {
                push.regenerateTopic()
                testResult = nil
            }
        } message: {
            Text("Subscribe to the new topic in the ntfy app. Hosts get it on their next connect.")
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
