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
                    Text("Applies to new sessions; pinch or ⌘+ / ⌘− zoom an open one.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Keyboard") {
                    Picker("Accessory bar", selection: $settings.accessoryBar) {
                        Text("Docked above keyboard").tag(AppSettings.AccessoryBarStyle.docked)
                        Text("Floating").tag(AppSettings.AccessoryBarStyle.floating)
                    }
                    Toggle("Option key sends Alt (Esc prefix)", isOn: $settings.optionAsAlt)
                    Text("A hardware keyboard always uses the floating bar. Applies to new sessions.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("SSH") {
                    NavigationLink(value: SettingsPage.keys) {
                        LabeledContent("Keys", value: "\(model.keys.items.count)")
                    }
                    .accessibilityIdentifier("settings-keys-link")
                }
                Section {
                    Toggle("Notify when an agent needs me", isOn: Binding(
                        get: { settings.notificationsEnabled },
                        set: { on in
                            if on { model.enableNotifications() } else { settings.notificationsEnabled = false }
                        }))
                    NavigationLink(value: SettingsPage.push) {
                        LabeledContent("Background push (ntfy)", value: PushSettingsSummary.text(for: model.pushSettings))
                    }
                    .accessibilityIdentifier("push-settings-link")
                } header: {
                    Text("Notifications")
                } footer: {
                    Text("Local notifications are best effort: iOS suspends the app soon after you leave it.")
                }
                Section("About") {
                    LabeledContent("Core", value: coreVersionString)
                    LabeledContent("Terminal engine", value: "libghostty")
                }
            }
            .navigationDestination(for: SettingsPage.self) { page in
                switch page {
                case .keys: KeysView(placement: .pushed)
                case .push: PushSettingsView()
                case .root: EmptyView()
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
