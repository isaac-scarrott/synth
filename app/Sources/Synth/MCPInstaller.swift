import Foundation
import os.log

/// Installs the bundled browser MCP server (ADR-0011 stage two) and registers it in
/// every managed worktree.
///
/// Install: the repo's mcp/ (copied into Contents/Resources/mcp by dev.sh /
/// build-app.sh) is synced to ~/Library/Application Support/Synth/browser-mcp/ at
/// launch, with `npm install --omit=dev` run there when node_modules is missing or
/// package.json changed — one shared install, stable path for every .mcp.json.
///
/// Registration: each worktree root gets .mcp.json with the synth-browser server,
/// MERGED into any existing file (other servers preserved), skipped when already
/// correct. Project scope is the point — the file must NOT be gitignored (any Claude
/// session in the worktree should see the tools) — but Synth never commits it.
@MainActor enum MCPInstaller {
    private static let log = Logger(subsystem: "tech.holibob.synth", category: "mcp")

    static let installDir = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Synth/browser-mcp", isDirectory: true)

    /// Copy the bundled server into the shared install dir and (re)install its deps
    /// when needed. npm runs off-main — launch must not wait on the network.
    static func refreshServerInstall() {
        let fm = FileManager.default
        guard let source = Bundle.main.resourceURL?.appendingPathComponent("mcp", isDirectory: true),
              fm.fileExists(atPath: source.appendingPathComponent("server.mjs").path) else {
            log.error("bundled mcp/ missing from app resources — browser MCP server not installed (bare-binary run?)")
            return
        }
        do {
            try fm.createDirectory(at: installDir, withIntermediateDirectories: true)
            let packageChanged = try syncFile(from: source, name: "package.json")
            _ = try syncFile(from: source, name: "server.mjs")
            let needsInstall = packageChanged
                || !fm.fileExists(atPath: installDir.appendingPathComponent("node_modules").path)
            if needsInstall { runNpmInstall() }
        } catch {
            log.error("browser MCP install failed: \(error.localizedDescription)")
        }
    }

    /// Returns true when the destination changed (was missing or had different bytes).
    private static func syncFile(from source: URL, name: String) throws -> Bool {
        let src = source.appendingPathComponent(name)
        let dst = installDir.appendingPathComponent(name)
        let srcData = try Data(contentsOf: src)
        if let existing = try? Data(contentsOf: dst), existing == srcData { return false }
        try srcData.write(to: dst, options: .atomic)
        return true
    }

    private static func runNpmInstall() {
        guard let npm = resolveNpm() else {
            log.error("npm not found (checked PATH, homebrew, /usr/local, nvm) — run `npm install --omit=dev` in \(installDir.path) by hand")
            return
        }
        let dir = installDir
        Thread.detachNewThread {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: npm)
            task.arguments = ["install", "--omit=dev", "--no-audit", "--no-fund"]
            task.currentDirectoryURL = dir
            // npm re-execs node from PATH; make sure its own bin dir is on it.
            var env = ProcessInfo.processInfo.environment
            let npmDir = (npm as NSString).deletingLastPathComponent
            env["PATH"] = npmDir + ":" + (env["PATH"] ?? "/usr/bin:/bin")
            task.environment = env
            let out = Pipe()
            task.standardOutput = out
            task.standardError = out
            do {
                try task.run()
                task.waitUntilExit()
                if task.terminationStatus == 0 {
                    Logger(subsystem: "tech.holibob.synth", category: "mcp")
                        .info("browser MCP deps installed in \(dir.path)")
                } else {
                    let text = String(data: out.fileHandleForReading.readDataToEndOfFile(),
                                      encoding: .utf8) ?? ""
                    Logger(subsystem: "tech.holibob.synth", category: "mcp")
                        .error("npm install failed (\(task.terminationStatus)): \(text.suffix(400))")
                }
            } catch {
                Logger(subsystem: "tech.holibob.synth", category: "mcp")
                    .error("npm launch failed: \(error.localizedDescription)")
            }
        }
    }

    /// A GUI app's PATH rarely has node — check it anyway, then the usual installs,
    /// then nvm (newest version wins).
    private static func resolveNpm() -> String? {
        let fm = FileManager.default
        var candidates = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map { String($0) + "/npm" }
        candidates += ["/opt/homebrew/bin/npm", "/usr/local/bin/npm"]
        let nvmVersions = fm.homeDirectoryForCurrentUser
            .appendingPathComponent(".nvm/versions/node", isDirectory: true)
        if let versions = try? fm.contentsOfDirectory(atPath: nvmVersions.path) {
            candidates += versions.sorted { $0.compare($1, options: .numeric) == .orderedDescending }
                .map { nvmVersions.appendingPathComponent($0).appendingPathComponent("bin/npm").path }
        }
        return candidates.first { fm.isExecutableFile(atPath: $0) }
    }

    // MARK: Per-worktree .mcp.json

    /// In-memory skip: the sync runs on the autosave cadence, so an unchanged
    /// worktree set costs nothing.
    private static var lastSyncedPaths: [String]?

    static func syncWorktreeConfigs(_ worktreePaths: [String]) {
        guard worktreePaths != lastSyncedPaths else { return }
        lastSyncedPaths = worktreePaths
        for path in worktreePaths { writeConfig(atWorktree: path) }
    }

    private static func writeConfig(atWorktree path: String) {
        guard FileManager.default.fileExists(atPath: path) else { return }
        let file = URL(fileURLWithPath: path).appendingPathComponent(".mcp.json")
        let entry: [String: Any] = [
            "command": "node",
            "args": [installDir.appendingPathComponent("server.mjs").path],
        ]

        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: file) {
            guard let existing = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                // Unparseable user file — leave it alone rather than clobber.
                log.error("\(file.path) exists but isn't a JSON object — not touching it")
                return
            }
            root = existing
        }
        var servers = root["mcpServers"] as? [String: Any] ?? [:]
        if let current = servers["synth-browser"] as? [String: Any],
           NSDictionary(dictionary: current).isEqual(to: entry) {
            return   // already correct — never dirty the worktree needlessly
        }
        servers["synth-browser"] = entry
        root["mcpServers"] = servers
        guard let data = try? JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: file, options: .atomic)
    }
}
