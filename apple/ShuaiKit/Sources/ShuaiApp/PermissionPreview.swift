import Foundation

/// What the permission card shows for a tool request (pure; the view just renders it).
public struct PermissionPreview: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case command, edit, write, other }
    public enum DiffLine: Equatable, Sendable {
        case added(String)
        case removed(String)
    }

    public static let maxDiffLines = 40

    public var kind: Kind
    /// Bash command, file path, or compact JSON.
    public var primary: String
    public var diff: [DiffLine]
    /// More lines existed than `maxDiffLines`.
    public var truncated: Bool

    public static func make(toolName: String, inputJSON: String) -> PermissionPreview {
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(inputJSON.utf8))) as? [String: Any] else {
            return PermissionPreview(kind: .other, primary: inputJSON, diff: [], truncated: false)
        }
        func str(_ k: String) -> String? { obj[k] as? String }
        switch toolName {
        case "Bash":
            if let c = str("command") { return .init(kind: .command, primary: c, diff: [], truncated: false) }
        case "Edit", "MultiEdit":
            if let p = str("file_path") {
                var lines: [DiffLine] = []
                let edits = (obj["edits"] as? [[String: Any]]) ?? [obj]
                for e in edits {
                    lines += split(e["old_string"] as? String).map(DiffLine.removed)
                    lines += split(e["new_string"] as? String).map(DiffLine.added)
                }
                return capped(kind: .edit, primary: p, lines)
            }
        case "Write":
            if let p = str("file_path") {
                return capped(kind: .write, primary: p, split(str("content")).map(DiffLine.added))
            }
        default:
            break
        }
        let compact = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]))
            .map { String(decoding: $0, as: UTF8.self) } ?? inputJSON
        let summary = str("command") ?? str("file_path") ?? str("url") ?? str("pattern") ?? compact
        return PermissionPreview(kind: .other, primary: summary == compact ? compact : summary, diff: [], truncated: false)
    }

    private static func split(_ s: String?) -> [String] {
        guard let s, !s.isEmpty else { return [] }
        return s.components(separatedBy: "\n")
    }

    private static func capped(kind: Kind, primary: String, _ lines: [DiffLine]) -> PermissionPreview {
        lines.count > maxDiffLines
            ? PermissionPreview(kind: kind, primary: primary, diff: Array(lines.prefix(maxDiffLines)), truncated: true)
            : PermissionPreview(kind: kind, primary: primary, diff: lines, truncated: false)
    }
}
