import Foundation

struct Fixture {
    struct Chunk { let delay: Double; let bytes: Data }
    let all: Data
    let header: Data
    let chunks: [Chunk]
    let footer: Data

    static func load(out: String = "claude-cjk-120x40") -> Fixture {
        let o = Bundle.main.url(forResource: out, withExtension: "out")!
        let all = try! Data(contentsOf: o)
        var chunks: [Chunk] = []
        var headerLen = 0
        var consumed = 0
        if let t = Bundle.main.url(forResource: out, withExtension: "tim"),
           let txt = try? String(contentsOf: t, encoding: .utf8) {
            headerLen = (all.firstIndex(of: 0x0A) ?? -1) + 1
            var pos = headerLen
            for line in txt.split(separator: "\n") {
                let p = line.split(separator: " ")
                guard p.count == 2, let d = Double(p[0]), let n = Int(p[1]), pos + n <= all.count else { continue }
                chunks.append(Chunk(delay: d, bytes: all.subdata(in: pos..<pos + n)))
                pos += n
            }
            consumed = pos
        }
        return Fixture(all: all, header: all.prefix(headerLen), chunks: chunks, footer: all.suffix(from: consumed))
    }
}
