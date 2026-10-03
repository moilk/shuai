// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ShuaiKit",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "ShuaiCore", targets: ["ShuaiCore"]),
        .library(name: "ShuaiTerminal", targets: ["ShuaiTerminal"]),
    ],
    dependencies: [
        // Pinned exactly: single-maintainer wrapper tracking Ghostty tip (see docs/adr/0001).
        .package(url: "https://github.com/Lakr233/libghostty-spm.git", exact: "1.6.20261003"),
    ],
    targets: [
        // Built by scripts/build-xcframework.sh (gitignored).
        .binaryTarget(name: "ShuaiCoreFFI", path: "ShuaiCoreFFI.xcframework"),
        .target(
            name: "ShuaiCore",
            dependencies: ["ShuaiCoreFFI"],
            // Generated UniFFI code is not yet Swift 6 strict-concurrency clean.
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(name: "ShuaiCoreTests", dependencies: ["ShuaiCore"]),
        .target(
            name: "ShuaiTerminal",
            dependencies: [
                // GhosttyTerminal's UIKit views are iOS-only here; logic is platform-neutral.
                .product(name: "GhosttyTerminal", package: "libghostty-spm", condition: .when(platforms: [.iOS])),
            ]
        ),
        .testTarget(name: "ShuaiTerminalTests", dependencies: ["ShuaiTerminal"]),
    ]
)
