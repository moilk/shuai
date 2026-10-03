iPad Pro 13" (M5) simulator (Apple Silicon host), Debug build, 120x40, fixture = 46758 bytes, N=50 (2.34 MB total)

| engine    | feed() calls | until parsed | MB/s  | phys_footprint before -> after replay -> after bench |
|-----------|--------------|--------------|-------|------------------------------------------------------|
| ghostty   | 0.1 ms (async enqueue) | 0.111 s | 21.0 | 18.5 -> 19.0 -> 20.7 MB |
| swiftterm | 1.62 s (sync, main thread, incl. view updates) | 1.62 s | 1.44 | 18.5 -> 21.3 -> 28.1 MB |

Caveat: Ghostty parses on a background queue and renders on a display link, so its number is parser
throughput; SwiftTerm's is parser + main-thread view bookkeeping. Debug build, simulator: indicative only.
