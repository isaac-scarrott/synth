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

    /// Prove once, at launch, that the sandbox can be written. Nothing here ever created or
    /// tested `root` — every consumer did its own `try? createDirectory` and carried on — so a
    /// read-only or full Application Support folder made persistence, crash markers, the MCP
    /// install, the hook shims and the simulator claims each fail separately and silently, and
    /// the app looked fine until the user relaunched into an empty tree. One probe collapses
    /// all of that into a single sentence, said once.
    @discardableResult static func probeWritable() -> Bool {
        let probe = root.appendingPathComponent(".writable")
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data().write(to: probe)
            try FileManager.default.removeItem(at: probe)
            return true
        } catch {
            Fault.surface(.persistence, .supportDirUnwritable, severity: .blocked,
                          say: .init(title: "Synth can't save anything this run"),
                          details: [.posixErrno(errno), .stage(.write)],
                          evidence: "Application Support isn't writable.")
            return false
        }
    }
}
