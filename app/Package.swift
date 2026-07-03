// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Synth",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.2.0"),
    ],
    targets: [
        .executableTarget(
            name: "Synth",
            dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm")]
        ),
        // Standalone CLI the Claude Code hooks call back into (Foundation only, no
        // SwiftUI/SwiftTerm). Two roles: `launch` (invoked as the `claude` shim, injects
        // hooks + session id and execs the real binary) and `event` (a hook fired mid-run,
        // classifies the event and writes a status signal to the app's unix socket).
        .executableTarget(name: "synth-hook"),
    ]
)
