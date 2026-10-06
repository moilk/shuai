import ShuaiApp
import SwiftUI
import UniformTypeIdentifiers

struct KeysView: View {
    enum Placement {
        /// The root of its own sheet: shows Done.
        case sheetRoot
        /// Pushed inside the editor or Settings sheet: the back button returns.
        case pushed
    }

    let placement: Placement

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var generateAlgorithm: GeneratedKeyAlgorithm?
    @State private var newKeyName = ""
    @State private var showImporter = false
    @State private var showPaste = false
    @State private var pendingData: Data?
    @State private var pendingName = ""
    @State private var passphrase = ""
    @State private var askPassphrase = false
    @State private var pendingDelete: KeyLibrary.Item?
    @State private var errorMessage: String?

    var body: some View {
        List {
            if model.keys.items.isEmpty {
                ContentUnavailableView(
                    "No keys", systemImage: "key",
                    description: Text("Generate a key on this iPad and add its public key to ~/.ssh/authorized_keys on your server, or import an existing private key."))
            }
            ForEach(model.keys.items) { item in
                KeyRow(item: item, onDelete: { pendingDelete = item })
            }
        }
        .navigationTitle("Keys")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if placement == .sheetRoot {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Generate ed25519 key") { newKeyName = ""; generateAlgorithm = .ed25519 }
                    Button("Generate ECDSA P-256 key") { newKeyName = ""; generateAlgorithm = .ecdsaP256 }
                    Divider()
                    Button("Import from Files…") { showImporter = true }
                    Button("Paste private key…") { showPaste = true }
                } label: { Label("Add Key", systemImage: "plus") }
                    .accessibilityIdentifier("add-key-menu")
            }
        }
        .alert("Generate key", isPresented: Binding(get: { generateAlgorithm != nil }, set: { if !$0 { generateAlgorithm = nil } })) {
            TextField("Name", text: $newKeyName)
            Button("Generate") {
                if let alg = generateAlgorithm {
                    run { _ = try model.keys.generate(name: newKeyName, algorithm: alg) }
                }
                generateAlgorithm = nil
            }
            Button("Cancel", role: .cancel) {}
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.data, .text, .item]) { result in
            switch result {
            case .success(let url):
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                if let data = try? Data(contentsOf: url) {
                    beginImport(data: data, name: url.lastPathComponent)
                } else {
                    errorMessage = "Could not read the file."
                }
            case .failure(let e): errorMessage = e.localizedDescription
            }
        }
        .sheet(isPresented: $showPaste) {
            PasteKeySheet { text, name in
                beginImport(data: Data(text.utf8), name: name)
            }
        }
        .alert("Passphrase required", isPresented: $askPassphrase) {
            SecureField("Passphrase", text: $passphrase)
            Button("Import") {
                let typed = passphrase
                passphrase = ""
                if let data = pendingData { importNow(data, passphrase: typed) }
            }
            Button("Cancel", role: .cancel) { pendingData = nil; passphrase = "" }
        } message: {
            Text("This key is encrypted. It is stored decrypted in the device Keychain.")
        }
        .confirmationDialog(
            "Delete key \(pendingDelete?.name ?? "")?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete key", role: .destructive) {
                if let k = pendingDelete { run { try model.keys.delete(id: k.id) } }
                pendingDelete = nil
            }
        } message: {
            Text("Hosts that use this key will no longer be able to log in with it. This cannot be undone.")
        }
        .alert("Error", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
    }

    private func run(_ body: () throws -> Void) {
        do { try body() } catch { errorMessage = String(describing: error) }
    }

    private func beginImport(data: Data, name: String) {
        pendingName = name
        importNow(data, passphrase: nil)
    }

    private func importNow(_ data: Data, passphrase: String?) {
        do {
            _ = try model.keys.importKey(data: data, name: pendingName, passphrase: passphrase)
            pendingData = nil
        } catch KeyLibraryError.needsPassphrase {
            pendingData = data
            askPassphrase = true
        } catch KeyLibraryError.wrongPassphrase {
            pendingData = data
            errorMessage = "Wrong passphrase."
            askPassphrase = true
        } catch KeyLibraryError.invalidKey {
            errorMessage = "This is not a supported private key (OpenSSH, PEM PKCS#1/PKCS#8, SEC1)."
        } catch {
            errorMessage = String(describing: error)
        }
    }
}

private struct KeyRow: View {
    let item: KeyLibrary.Item
    let onDelete: () -> Void
    @State private var copied = false

    var body: some View {
        DisclosureGroup {
            Text(item.randomart)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .padding(.vertical, 4)
            Text(item.publicLine)
                .font(.system(.caption2, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(4)
            HStack {
                Button(copied ? "Copied" : "Copy public key", systemImage: "doc.on.doc") {
                    UIPasteboard.general.string = item.publicLine
                    copied = true
                }
                ShareLink(item: item.publicLine) { Label("Share", systemImage: "square.and.arrow.up") }
                Spacer()
                Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
            }
            .buttonStyle(.bordered)
            .padding(.top, 4)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(.headline)
                Text("\(item.algorithm)  \(item.fingerprint)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
        }
        .swipeActions { Button("Delete", role: .destructive, action: onDelete) }
    }
}

private struct PasteKeySheet: View {
    @Environment(\.dismiss) private var dismiss
    let onImport: (String, String) -> Void
    @State private var text = ""
    @State private var name = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                Section("Private key") {
                    TextEditor(text: $text)
                        .font(.system(.footnote, design: .monospaced))
                        .frame(minHeight: 220)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
            }
            .navigationTitle("Paste key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") { onImport(text, name); dismiss() }.disabled(text.isEmpty)
                }
            }
        }
    }
}
