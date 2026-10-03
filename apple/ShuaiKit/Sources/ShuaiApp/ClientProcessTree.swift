import Foundation

/// Tells our own tmux PTY client from other clients attached to the same session (a laptop, a
/// second device) using the remote process tree: the PTY client and the control client are both
/// spawned by the same SSH connection (the per-connection `sshd`), so among the candidates the one
/// sharing the deepest ancestor with the control client's process is ours. Pure; the monitor feeds
/// it the output of `ps -A -o pid= -o ppid=`.
enum ClientProcessTree {
    static let command = "ps -A -o pid= -o ppid="

    /// `pid -> ppid` from `ps` output; lines that are not two integers are skipped.
    static func parse(psOutput: String) -> [Int: Int] {
        var out: [Int: Int] = [:]
        for line in psOutput.split(whereSeparator: \.isNewline) {
            let f = line.split(whereSeparator: \.isWhitespace)
            guard f.count == 2, let pid = Int(f[0]), let ppid = Int(f[1]) else { continue }
            out[pid] = ppid
        }
        return out
    }

    /// Ancestors root-first, ending with `pid` itself (cycle safe).
    private static func chain(_ pid: Int, _ parents: [Int: Int]) -> [Int] {
        var seen: Set<Int> = [pid]
        var up = [pid]
        var cur = pid
        while let p = parents[cur], !seen.contains(p) {
            up.append(p)
            seen.insert(p)
            cur = p
        }
        return up.reversed()
    }

    /// The candidates that share the deepest ancestor with `control`. Every candidate is kept when
    /// the tree says nothing (control unknown, all equally far).
    static func closest(to control: Int, among candidates: [Int], parents: [Int: Int]) -> [Int] {
        guard parents[control] != nil else { return candidates }
        let mine = chain(control, parents)
        func shared(_ pid: Int) -> Int {
            zip(mine, chain(pid, parents)).prefix { $0 == $1 }.count
        }
        let depths = candidates.map(shared)
        guard let best = depths.max() else { return candidates }
        return zip(candidates, depths).filter { $0.1 == best }.map(\.0)
    }
}
