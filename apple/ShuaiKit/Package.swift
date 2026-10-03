// swift-tools-version: 6.0
import Foundation
import PackageDescription

// `SHUAI_FFI_TESTKIT=1 scripts/build-xcframework.sh` builds the Rust core with the `testkit`
// feature (in-process SSH server) and drops this marker; only then are the real-SSH tests built.
let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let hasTestkit = FileManager.default.fileExists(atPath: packageDir + "/.shuai-testkit")

let package = Package(
    name: "ShuaiKit",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "ShuaiCore", targets: ["ShuaiCore"]),
        .library(name: "ShuaiPlatform", targets: ["ShuaiPlatform"]),
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
    ]
)
