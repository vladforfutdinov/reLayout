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
    // COM (UI Automation) is unusable from Swift, so the text read is one C++ file.
    .target(name: "RelayoutUIA", path: "windows/uia", publicHeadersPath: "include")
)
targets.append(
    .executableTarget(
        name: "ReLayoutWin",
        dependencies: ["ReLayoutCore", "RelayoutUIA"],
        path: "windows",
        exclude: ["uia"],
        // Link as a GUI-subsystem app so launching it does NOT pop a console
        // window — reLayout is a tray app. /ENTRY:mainCRTStartup keeps the
        // normal C `main` entry (the GUI subsystem would otherwise want WinMain).
        linkerSettings: [
            .unsafeFlags(["-Xlinker", "/SUBSYSTEM:WINDOWS",
                          "-Xlinker", "/ENTRY:mainCRTStartup"]),
            .linkedLibrary("comctl32"),  // SysLink control in the Settings window
            .linkedLibrary("ole32"),     // UI Automation lives behind COM
            .linkedLibrary("oleaut32"),  // BSTR
            .linkedLibrary("uuid")       // CLSID_CUIAutomation
        ]
    )
)
#endif

let package = Package(
    name: "reLayout",
    products: [
        .library(name: "ReLayoutCore", targets: ["ReLayoutCore"]),
    ],
    targets: targets
)
