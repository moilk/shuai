import Foundation

/// Pure subsequence fuzzy matcher for the quick switcher (case and diacritic insensitive).
/// Scores prefer prefixes, word starts (after space/`-_/.:`), consecutive runs and short
/// candidates; the best alignment is found with a small DP (candidates are short strings).
public enum FuzzyMatcher {
    public struct Match: Equatable, Sendable {
        public var score: Int
        /// Character offsets (into `text`) of the matched characters.
        public var indices: [Int]
    }

    /// `nil` = no match. An empty (or blank) query matches with score 0.
    public static func score(query: String, in text: String) -> Int? {
        match(query: query, in: text)?.score
    }

    public static func match(query: String, in text: String) -> Match? {
        let q = fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        if q.isEmpty { return Match(score: 0, indices: []) }
        let raw = Array(text)
        let t = fold(text)
        let n = q.count, m = t.count
        guard n <= m else { return nil }

        let neg = Int.min / 2
        // best[i][j]: best score matching q[0...i] with q[i] at text index j.
        var best = Array(repeating: Array(repeating: neg, count: m), count: n)
        var from = Array(repeating: Array(repeating: -1, count: m), count: n)

        for i in 0 ..< n {
            for j in i ..< m where t[j] == q[i] {
                let bonus = charBonus(raw, j)
                if i == 0 {
                    best[0][j] = 10 + bonus - min(j, 8)
                    continue
                }
                var top = neg, topK = -1
                for k in (i - 1) ..< j where best[i - 1][k] > neg {
                    let run = k == j - 1 ? 12 : -min(j - k - 1, 6)
                    let s = best[i - 1][k] + run
                    if s > top { top = s; topK = k }
                }
                if topK >= 0 {
                    best[i][j] = top + 10 + bonus
                    from[i][j] = topK
                }
            }
        }
        var endJ = -1, endScore = neg
        for j in 0 ..< m where best[n - 1][j] > endScore {
            endScore = best[n - 1][j]
            endJ = j
        }
        guard endJ >= 0 else { return nil }
        var indices = [Int](repeating: 0, count: n)
        var j = endJ
        for i in stride(from: n - 1, through: 0, by: -1) {
            indices[i] = j
            j = from[i][j]
        }
        let score = max(1, endScore - m / 4)
        return Match(score: score, indices: indices)
    }

    private static func fold(_ s: String) -> [String] {
        s.map { String($0).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
    }

    private static let separators: Set<Character> = [" ", "-", "_", "/", ".", ":", "\u{203A}"]

    /// Bonus for matching `raw[j]`: start of text or of a word.
    private static func charBonus(_ raw: [Character], _ j: Int) -> Int {
        if j == 0 { return 15 }
        let prev = raw[j - 1]
        if separators.contains(prev) { return 10 }
        if prev.isLowercase, raw[j].isUppercase { return 8 } // camelCase hump
        return 0
    }
}
