// swift-tools-version:5.9
import PackageDescription

// Cross-platform package for the shared conversion engine. The macOS app itself
// is built by build.sh (swiftc -> .app bundle); this package exposes the engine as
// ReLayoutCore so the Windows port can `import` it and so `swift test` validates
// the engine on macOS AND Windows CI.
let package = Package(
    name: "reLayout",
    products: [
        .library(name: "ReLayoutCore", targets: ["ReLayoutCore"]),
    ],
    targets: [
        .target(name: "ReLayoutCore", path: "Core"),
        .testTarget(
            name: "ReLayoutCoreTests",
            dependencies: ["ReLayoutCore"],
            path: "Tests/ReLayoutCoreTests"
        ),
    ]
)
