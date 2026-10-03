// swift-tools-version: 6.0
import Foundation
import PackageDescription

// `SHUAI_FFI_TESTKIT=1 scripts/build-xcframework.sh` builds the Rust core with the `testkit`
// feature (in-process SSH server). Run `SHUAI_FFI_TESTKIT=1 swift test` against such a build to
// also compile the real-SSH tests (`#if SHUAI_TESTKIT`). The env var is the switch because
// SwiftPM caches manifest evaluation and would not notice a marker file appearing.
let hasTestkit = ProcessInfo.processInfo.environment["SHUAI_FFI_TESTKIT"] == "1"

let package = Package(
    name: "ShuaiKit",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "ShuaiCore", targets: ["ShuaiCore"]),
        .library(name: "ShuaiPlatform", targets: ["ShuaiPlatform"]),
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
        // Platform adapters (Keychain, known_hosts file, TOFU, connection/stream wrappers).
        .target(name: "ShuaiPlatform", dependencies: ["ShuaiCore"]),
        .testTarget(name: "ShuaiCoreTests", dependencies: ["ShuaiCore"]),
        .testTarget(
            name: "ShuaiPlatformTests",
            dependencies: ["ShuaiPlatform", "ShuaiCore"],
            swiftSettings: hasTestkit ? [.define("SHUAI_TESTKIT")] : []
        ),
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
