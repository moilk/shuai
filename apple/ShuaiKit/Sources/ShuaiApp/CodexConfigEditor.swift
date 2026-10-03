import Foundation

/// Minimal line-based editing of the top-level `notify` key of `~/.codex/config.toml`.
/// (Everything else in the file is left byte-for-byte alone.)
public enum CodexConfigEditor {
    /// Set `notify = [argv...]` as a top-level key, replacing an existing one (also a multi-line
    /// array); a new key goes first, before any `[table]`, where TOML requires it.
    public static func settingNotify(in text: String, argv: [String]) -> String {
        let line = "notify = [" + argv.map(tomlString).joined(separator: ", ") + "]\n"
        if let r = notifyRange(in: text) {
            return String(text[..<r.lowerBound]) + line + String(text[r.upperBound...])
        }
        return line + text
    }

    /// Remove the top-level `notify` only when it points at shuai-agent.
    public static func removingShuaiNotify(from text: String) -> String {
        guard let r = notifyRange(in: text), text[r].contains("shuai-agent") else { return text }
        return String(text[..<r.lowerBound]) + String(text[r.upperBound...])
    }

    private static func tomlString(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Range of the top-level `notify = ...` statement including its trailing newline.
    private static func notifyRange(in text: String) -> Range<String.Index>? {
        var idx = text.startIndex
        while idx < text.endIndex {
            let lineEnd = text[idx...].firstIndex(of: "\n").map { text.index(after: $0) } ?? text.endIndex
            let line = text[idx..<lineEnd].trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { return nil }  // tables start: no top-level notify after this
            if line.hasPrefix("notify"), line.dropFirst(6).trimmingCharacters(in: .whitespaces).hasPrefix("=") {
                var end = lineEnd
                var depth = bracketDepth(text[idx..<lineEnd])
                while depth > 0, end < text.endIndex {
                    let next = text[end...].firstIndex(of: "\n").map { text.index(after: $0) } ?? text.endIndex
                    depth += bracketDepth(text[end..<next])
                    end = next
                }
                return idx..<end
            }
            idx = lineEnd
        }
        return nil
    }

    private static func bracketDepth(_ s: Substring) -> Int {
        var d = 0
        var inString = false
        for c in s {
            if c == "\"" { inString.toggle() }
            if inString { continue }
            if c == "[" { d += 1 } else if c == "]" { d -= 1 }
        }
        return d
    }
}
