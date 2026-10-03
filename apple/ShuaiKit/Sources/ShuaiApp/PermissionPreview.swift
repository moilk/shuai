import Foundation

/// What the permission card shows for a tool request (pure; the view just renders it).
public struct PermissionPreview: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case command, edit, write, other }
    public enum DiffLine: Equatable, Sendable {
        case added(String)
        case removed(String)
    }

    public static let maxDiffLines = 40
    /// Untrusted tool input is shown, never trusted: everything is length-capped so a huge
    /// `tool_input` cannot stall layout or fill the screen.
    public static let maxPrimaryChars = 2_000
    public static let maxLineChars = 300
    /// Raw JSON above this size is not even parsed.
    static let maxParseBytes = 256 * 1024

    public var kind: Kind
    /// Bash command, file path, or compact JSON.
    public var primary: String
    public var diff: [DiffLine]
    /// More lines existed than `maxDiffLines`.
    public var truncated: Bool

    public static func make(toolName: String, inputJSON: String) -> PermissionPreview {
        guard inputJSON.utf8.count <= maxParseBytes,
            let obj = (try? JSONSerialization.jsonObject(with: Data(inputJSON.utf8))) as? [String: Any]
        else {
            let c = clip(inputJSON, maxPrimaryChars)
            return PermissionPreview(kind: .other, primary: c.text, diff: [], truncated: c.cut)
        }
        func str(_ k: String) -> String? { obj[k] as? String }
        switch toolName {
        case "Bash":
            if let c = str("command") {
                let t = clip(c, maxPrimaryChars)
                return .init(kind: .command, primary: t.text, diff: [], truncated: t.cut)
            }
        case "Edit", "MultiEdit":
            if let p = str("file_path") {
                var lines: [DiffLine] = []
                let edits = (obj["edits"] as? [[String: Any]]) ?? [obj]
                for e in edits {
                    lines += split(e["old_string"] as? String).map(DiffLine.removed)
                    lines += split(e["new_string"] as? String).map(DiffLine.added)
                }
                return capped(kind: .edit, primary: clip(p, maxLineChars).text, lines)
            }
        case "Write":
            if let p = str("file_path") {
                return capped(kind: .write, primary: clip(p, maxLineChars).text, split(str("content")).map(DiffLine.added))
            }
        default:
            break
        }
        let compact = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]))
            .map { String(decoding: $0, as: UTF8.self) } ?? inputJSON
        let summary = str("command") ?? str("file_path") ?? str("url") ?? str("pattern") ?? compact
        let t = clip(summary, maxPrimaryChars)
        return PermissionPreview(kind: .other, primary: t.text, diff: [], truncated: t.cut)
    }

    private static func clip(_ s: String, _ limit: Int) -> (text: String, cut: Bool) {
        guard s.count > limit else { return (s, false) }
        return (String(s.prefix(limit)) + "…", true)
    }

    /// At most `maxDiffLines + 1` lines of at most `maxLineChars` characters.
    private static func split(_ s: String?) -> [String] {
        guard let s, !s.isEmpty else { return [] }
        return s.split(separator: "\n", maxSplits: maxDiffLines, omittingEmptySubsequences: false)
            .map { clip(String($0), maxLineChars).text }
    }

    private static func capped(kind: Kind, primary: String, _ lines: [DiffLine]) -> PermissionPreview {
        let longLine = lines.contains { l in
            switch l { case .added(let s), .removed(let s): s.hasSuffix("…") }
        }
        return lines.count > maxDiffLines
            ? PermissionPreview(kind: kind, primary: primary, diff: Array(lines.prefix(maxDiffLines)), truncated: true)
            : PermissionPreview(kind: kind, primary: primary, diff: lines, truncated: longLine)
    }
}
