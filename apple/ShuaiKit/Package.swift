// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ShuaiKit",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "ShuaiCore", targets: ["ShuaiCore"]),
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
    ]
)
