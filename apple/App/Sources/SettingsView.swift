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
