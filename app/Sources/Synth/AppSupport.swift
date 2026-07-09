import Foundation

/// The root of Synth's Application Support sandbox — the one place the channel's name
/// enters the filesystem. Stable runs as "Synth", the development build as "Synth Dev",
/// so the two never share state, worktrees, browser profiles, or instance registries and
/// can run side by side. The folder name is the app's `CFBundleName`; `SYNTH_SUPPORT_DIR`
/// overrides it outright (harness isolation), and a bare binary with no bundle falls back
/// to "Synth".
enum AppSupport {
    static let root: URL = {
        if let override = ProcessInfo.processInfo.environment["SYNTH_SUPPORT_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let name = (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? "Synth"
        return base.appendingPathComponent(name, isDirectory: true)
    }()

    /// A subdirectory of the sandbox, e.g. `AppSupport.dir("worktrees")`.
    static func dir(_ subpath: String) -> URL {
        root.appendingPathComponent(subpath, isDirectory: true)
    }
}
