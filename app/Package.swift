// swift-tools-version:5.10
import PackageDescription
import Foundation

// Absolute path to the vendored libghostty static archive. `swift build` (the SwiftPM
// CLI) can't link a static-library xcframework directly, so we link the fat .a with an
// explicit -Xlinker flag instead and vend the C module from the `GhosttyKit` target's
// header. ld picks the matching arch slice from the fat archive.
let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let ghosttyArchive = packageDir + "/vendor/GhosttyKit.xcframework/macos-arm64_x86_64/ghostty-internal.a"

// System frameworks + libs the libghostty archive references (derived from its unresolved
// symbols). Ghostty resolves ObjC classes via the runtime, so only referenced C symbols
// need linking here.
let ghosttyLinkerSettings: [LinkerSetting] = [
    .linkedFramework("AppKit"),
    .linkedFramework("Metal"),
    .linkedFramework("QuartzCore"),
    .linkedFramework("CoreText"),
    .linkedFramework("CoreGraphics"),
    .linkedFramework("CoreVideo"),
    .linkedFramework("CoreFoundation"),
    .linkedFramework("IOSurface"),
    .linkedFramework("IOKit"),
    .linkedFramework("Carbon"),
    .linkedFramework("GameController"),
    .linkedLibrary("objc"),
    .linkedLibrary("z"),
    .linkedLibrary("c++"),
    .unsafeFlags(["-Xlinker", ghosttyArchive]),
]

let package = Package(
    name: "Synth",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Synth",
            dependencies: ["GhosttyKit"],
            linkerSettings: ghosttyLinkerSettings
        ),
        // Vends the `GhosttyKit` Clang module (ghostty.h) for `import GhosttyKit`. The
        // libghostty archive itself is linked via ghosttyLinkerSettings, not this target.
        .target(name: "GhosttyKit"),
        // Standalone CLI the Claude Code hooks call back into (Foundation only, no
        // SwiftUI/GhosttyKit). Two roles: `launch` (invoked as the `claude` shim, injects
        // hooks + session id and execs the real binary) and `event` (a hook fired mid-run,
        // classifies the event and writes a status signal to the app's unix socket).
        .executableTarget(name: "synth-hook"),
    ]
)
