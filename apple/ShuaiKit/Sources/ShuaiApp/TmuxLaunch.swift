import Foundation

/// How shuai attaches to tmux. The command runs directly on the PTY channel (no typed text).
public enum TmuxLaunch {
    /// tmux rewrites ':' and '.' in session names; reject them up front (also empty/control chars).
    public static func isValidSessionName(_ name: String) -> Bool {
        !name.isEmpty
            && name.trimmingCharacters(in: .whitespaces) == name
            && !name.contains(where: { $0 == ":" || $0 == "." || $0.isNewline || $0.asciiValue.map { $0 < 0x20 } == true })
    }

    /// DEBUG-only extra tmux args (e.g. `-L shuaidbg -vv`), set from the `-debugHostFile` JSON. Always empty in Release.
    nonisolated(unsafe) public static var debugArgs = ""

    /// POSIX single-quote quoting.
    public static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// `tmux new -A -s 'NAME'` (attach if it exists, create otherwise). A startup command runs
    /// only when the session is created; afterwards the user's shell takes over.
    public static func command(sessionName: String, startupCommand: String? = nil) -> String {
        var cmd = "tmux\(debugArgs) new -A -s \(shellQuote(sessionName))"
        if let s = startupCommand?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
            cmd += " " + shellQuote("\(s); exec \"${SHELL:-/bin/sh}\"")
        }
        return cmd
    }
}
