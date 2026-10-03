import SwiftUI
import ShuaiCore

/// A pending tool-permission request: tool, input preview, Allow / Deny with an optional message.
/// Keyboard: ⌘↩ allows, ⌘⌫ denies (both disabled while the message field has focus: ⌘⌫ is
/// "delete to line start" there). Tool input is untrusted: rendered verbatim (no markdown, no links).
public struct PermissionCardView: View {
    public let item: PendingPermissionItem
    public var answering: AnswerState?
    public var errorMessage: String?
    public var onRespond: (_ allow: Bool, _ message: String?) -> Void

    @State private var message = ""
    @FocusState private var typing: Bool

    public init(
        item: PendingPermissionItem, answering: AnswerState? = nil, errorMessage: String? = nil,
        onRespond: @escaping (_ allow: Bool, _ message: String?) -> Void
    ) {
        self.item = item
        self.answering = answering
        self.errorMessage = errorMessage
        self.onRespond = onRespond
    }

    private var preview: PermissionPreview {
        PermissionPreview.make(toolName: item.request.toolName, inputJSON: item.request.toolInputJson)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(item.request.toolName, systemImage: "lock.shield").font(.headline)
                Spacer()
                if let cwd = item.session.cwd { Text(verbatim: cwd).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            previewBody
            TextField("Message to Claude (optional)", text: $message)
                .textFieldStyle(.roundedBorder)
                .focused($typing)
                .disabled(answering != nil)
            if let errorMessage { Text(verbatim: errorMessage).font(.caption).foregroundStyle(.red) }
            HStack {
                if let answering {
                    ProgressView().controlSize(.small)
                    Text(answering == .allowing ? "Allowing..." : "Denying...").font(.caption)
                }
                Spacer()
                Button("Deny", role: .destructive) { onRespond(false, trimmedMessage) }
                    .keyboardShortcut(typing ? nil : KeyboardShortcut(.delete, modifiers: .command))
                Button("Allow") { onRespond(true, trimmedMessage) }
                    .keyboardShortcut(typing ? nil : KeyboardShortcut(.return, modifiers: .command))
                    .buttonStyle(.borderedProminent)
            }
            .disabled(answering != nil)
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityIdentifier("permission-card")
    }

    private var trimmedMessage: String? {
        let t = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    @ViewBuilder private var previewBody: some View {
        let p = preview
        switch p.kind {
        case .command:
            Text(verbatim: p.primary).font(.system(.callout, design: .monospaced))
                .textSelection(.enabled).padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.black.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        case .edit, .write:
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: p.primary).font(.system(.callout, design: .monospaced)).fontWeight(.semibold)
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(p.diff.enumerated()), id: \.offset) { _, line in diffRow(line) }
                    }
                }
                .frame(maxHeight: 160)
                if p.truncated { Text(verbatim: "...").font(.caption).foregroundStyle(.secondary) }
            }
        case .other:
            Text(verbatim: p.primary).font(.system(.callout, design: .monospaced)).lineLimit(6)
        }
    }

    private func diffRow(_ line: PermissionPreview.DiffLine) -> some View {
        let (sign, text, color): (String, String, Color) = switch line {
        case .added(let s): ("+", s, .green)
        case .removed(let s): ("-", s, .red)
        }
        return Text(verbatim: "\(sign) \(text)").font(.system(.caption, design: .monospaced))
            .foregroundStyle(color).frame(maxWidth: .infinity, alignment: .leading)
    }
}

#if DEBUG
extension PendingPermissionItem {
    static func sample(tool: String, inputJSON: String) -> PendingPermissionItem {
        let req = FfiPendingPermission(
            requestId: "req-1", toolName: tool, inputPreview: "", toolInputJson: inputJSON, since: 0)
        let s = FfiAgentSession(
            host: "dev", sessionId: "s1", source: .claude, cwd: "/home/u/proj", title: nil, model: nil,
            tmuxPane: "%1", tmuxSocket: nil, pid: nil, state: .needsPermission, currentTool: tool,
            lastPrompt: nil, lastMessage: nil, pendingPermission: req, activeSubagents: 0, seen: false,
            needsAttention: true, badge: .needsPermission, updatedAt: 0, startedAt: 0)
        return PendingPermissionItem(key: FfiSessionKey(host: "dev", sessionId: "s1"), request: req, session: s)
    }
}

#Preview("Bash") {
    PermissionCardView(item: .sample(tool: "Bash", inputJSON: #"{"command":"rm -rf build && swift build"}"#)) { _, _ in }
        .padding()
}
#Preview("Edit") {
    PermissionCardView(
        item: .sample(tool: "Edit", inputJSON: #"{"file_path":"/home/u/a.swift","old_string":"let a = 1","new_string":"let a = 2\nlet b = 3"}"#),
        answering: .allowing
    ) { _, _ in }
    .padding()
}
#endif
