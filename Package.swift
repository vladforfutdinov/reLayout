// swift-tools-version:5.9
import PackageDescription

// Cross-platform package for the shared conversion engine. The macOS app itself
// is built by build.sh (swiftc -> .app bundle); this package exposes the engine as
// ReLayoutCore so the Windows port can `import` it and so `swift test` validates
// the engine on macOS AND Windows CI.
var targets: [Target] = [
    .target(name: "ReLayoutCore", path: "Core"),
    .testTarget(
        name: "ReLayoutCoreTests",
        dependencies: ["ReLayoutCore"],
        path: "Tests/ReLayoutCoreTests"
    ),
]

// The Windows app target uses WinSDK, so include it only when building on Windows
// (the manifest is evaluated on the build host). macOS `swift test` ignores it.
#if os(Windows)
targets.append(
    .executableTarget(name: "ReLayoutWin", dependencies: ["ReLayoutCore"], path: "windows")
)
#endif

let package = Package(
    name: "reLayout",
    products: [
        .library(name: "ReLayoutCore", targets: ["ReLayoutCore"]),
    ],
    targets: targets
)
