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

// Vendored CEF (vendor/fetch-cef.sh): the shim + helper targets only exist when the
// distro is staged, so `swift build` still completes on checkouts that never fetched
// CEF — CEFEngine.swift gates on canImport(CEFShim) and the factory reports the missing
// assets at runtime instead.
let cefDist = packageDir + "/vendor/cef/dist"
let cefWrapper = packageDir + "/vendor/cef/libcef_dll_wrapper.a"
let hasCEF = FileManager.default.fileExists(atPath: cefWrapper)
    && FileManager.default.fileExists(atPath: cefDist + "/include/cef_version.h")

// CEF headers are C++17; the wrapper archive is built -fno-rtti, so the shim must
// match or its vtables reference typeinfo the archive never emits.
let cefCxxFlags = ["-I", cefDist, "-std=c++17", "-fno-rtti", "-fobjc-arc"]
let cefLinkerSettings: [LinkerSetting] = [
    .linkedFramework("AppKit"),
    .linkedFramework("Cocoa"),
    .linkedFramework("IOSurface"),
    .linkedLibrary("pthread"),
    .unsafeFlags(["-Xlinker", cefWrapper]),
]

// Sparkle ships as a dynamic-framework binaryTarget. `swift build` copies Sparkle.framework
// into the bin dir but sets no rpath, so the bundled executable has to be told where
// lib.sh staged it (Contents/Frameworks).
var synthDependencies: [Target.Dependency] = [
    "GhosttyKit",
    .product(name: "Sparkle", package: "Sparkle"),
    .product(name: "PostHog", package: "posthog-ios"),
]
var synthLinkerSettings = ghosttyLinkerSettings + [
    LinkerSetting.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
]
var targets: [Target] = [
    // Vends the `GhosttyKit` Clang module (ghostty.h) for `import GhosttyKit`. The
    // libghostty archive itself is linked via ghosttyLinkerSettings, not this target.
    .target(name: "GhosttyKit"),
    // Standalone CLI the Claude Code hooks call back into (Foundation only, no
    // SwiftUI/GhosttyKit). Two roles: `launch` (invoked as the `claude` shim, injects
    // hooks + session id and execs the real binary) and `event` (a hook fired mid-run,
    // classifies the event and writes a status signal to the app's unix socket).
    .executableTarget(name: "synth-hook"),
]

if hasCEF {
    synthDependencies.append("CEFShim")
    synthLinkerSettings += cefLinkerSettings
    targets += [
        // ObjC++ bridge over the CEF C++ API: init/pump/shutdown once per process,
        // one CEFShimBrowser per browser session. Swift talks only to its ObjC header.
        .target(
            name: "CEFShim",
            cxxSettings: [.unsafeFlags(cefCxxFlags)]
        ),
        // CEF's four helper bundles all run this stub (bundle assembly copies it in
        // under the four required names).
        .executableTarget(
            name: "SynthBrowserHelper",
            cxxSettings: [.unsafeFlags(cefCxxFlags)],
            linkerSettings: cefLinkerSettings
        ),
    ]
}

targets.append(
    .executableTarget(
        name: "Synth",
        dependencies: synthDependencies,
        // CommentOverlay.js (ADR-0011 stage three): the page overlay, injected over
        // CDP. .copy — it must land byte-identical (dev.sh/dist.sh copy the
        // resource bundle into Contents/Resources so the bundled app finds it).
        resources: [.copy("Resources/CommentOverlay.js")],
        linkerSettings: synthLinkerSettings
    )
)

let package = Package(
    name: "Synth",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.4"),
        // Anonymous, opt-out product analytics (Analytics.swift). Client SDK only — the
        // project token it carries is publishable, not a secret.
        .package(url: "https://github.com/PostHog/posthog-ios", from: "3.59.3"),
    ],
    targets: targets
)
