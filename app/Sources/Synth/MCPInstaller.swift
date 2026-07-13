import Foundation
import os.log

/// Installs the bundled MCP servers — synth-browser (ADR-0011 stage two) and
/// synth-app (approval-gated app control) — and registers them in every managed
/// worktree.
///
/// Install: the repo's mcp/ (copied into Contents/Resources/mcp by dev.sh /
/// dist.sh) is synced to the channel's Application Support sandbox (AppSupport.root)
/// under browser-mcp/ at launch, with `npm install --omit=dev` run there when
/// node_modules is missing or
/// package.json changed — one shared install, stable path for every .mcp.json.
/// (The dir name predates the second server; renaming it would orphan nothing but
/// churn every config, so it stays.)
///
/// Registration: each worktree root gets .mcp.json with the ENABLED servers (the
/// Settings → MCP servers toggles: browser on by default, app off), MERGED into any
/// existing file (other servers preserved), skipped when already correct; a disabled
/// server's entry is removed, so its tools never even appear to agents. Project scope
/// is the point — the file must NOT be gitignored (any Claude session in the worktree
/// should see the tools) — but Synth never commits it.
@MainActor enum MCPInstaller {
    private static let log = Logger(subsystem: bundleIdentifier, category: "mcp")

    static let installDir = AppSupport.dir("browser-mcp")

    /// The bundled servers: registry name → entry script (shared.mjs serves both).
    private static let serverScripts = [
        "synth-browser": "server.mjs",
        "synth-app": "app-server.mjs",
    ]

    /// Copy the bundled servers into the shared install dir and (re)install their deps
    /// when needed. npm runs off-main — launch must not wait on the network.
    static func refreshServerInstall() {
        let fm = FileManager.default
        guard let source = Bundle.main.resourceURL?.appendingPathComponent("mcp", isDirectory: true),
              fm.fileExists(atPath: source.appendingPathComponent("server.mjs").path) else {
            log.error("bundled mcp/ missing from app resources — MCP servers not installed (bare-binary run?)")
            return
        }
        do {
            try fm.createDirectory(at: installDir, withIntermediateDirectories: true)
            let packageChanged = try syncFile(from: source, name: "package.json")
            _ = try syncFile(from: source, name: "shared.mjs")
            for script in serverScripts.values { _ = try syncFile(from: source, name: script) }
            let needsInstall = packageChanged
                || !fm.fileExists(atPath: installDir.appendingPathComponent("node_modules").path)
            if needsInstall { runNpmInstall() }
        } catch {
            log.error("MCP server install failed: \(error.localizedDescription)")
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
                    Logger(subsystem: bundleIdentifier, category: "mcp")
                        .info("browser MCP deps installed in \(dir.path)")
                } else {
                    let text = String(data: out.fileHandleForReading.readDataToEndOfFile(),
                                      encoding: .utf8) ?? ""
                    Logger(subsystem: bundleIdentifier, category: "mcp")
                        .error("npm install failed (\(task.terminationStatus)): \(text.suffix(400))")
                }
            } catch {
                Logger(subsystem: bundleIdentifier, category: "mcp")
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

    // MARK: Per-worktree agent config

    /// In-memory skip: the sync runs on the autosave cadence, so an unchanged
    /// worktree set (with unchanged toggles) costs nothing.
    private static var lastSynced: (paths: [String], servers: [String: Bool])?

    /// Each agent discovers project MCP servers from its own file, with its own schema. Both
    /// are written into every worktree: whichever agent runs there finds the enabled servers
    /// already registered, and the other's file is inert. `servers` is the Settings toggle
    /// state — a false entry actively REMOVES that server from the configs.
    static func syncWorktreeConfigs(_ worktreePaths: [String], servers: [String: Bool]) {
        guard lastSynced == nil || lastSynced! != (worktreePaths, servers) else { return }
        lastSynced = (worktreePaths, servers)
        for path in worktreePaths {
            writeClaudeConfig(atWorktree: path, servers: servers)
            writeOpencodeConfig(atWorktree: path, servers: servers)
        }
    }

    private static func serverPath(_ name: String) -> String {
        installDir.appendingPathComponent(serverScripts[name] ?? "server.mjs").path
    }

    /// Claude Code: `.mcp.json` → `mcpServers.<name>.{command,args}`.
    private static func writeClaudeConfig(atWorktree path: String, servers: [String: Bool]) {
        var built: [String: [String: Any]?] = [:]
        for (name, enabled) in servers {
            built.updateValue(enabled ? ["command": "node", "args": [serverPath(name)]] : nil,
                              forKey: name)
        }
        merge(atWorktree: path, file: ".mcp.json", container: "mcpServers", entries: built)
    }

    /// opencode: `opencode.json` → `mcp.<name>.{type,command,enabled,environment}`. A single
    /// `command` array rather than command+args, and the worktree travels in the env because
    /// the server can no longer read Claude's `CLAUDE_PROJECT_DIR`.
    private static func writeOpencodeConfig(atWorktree path: String, servers: [String: Bool]) {
        var built: [String: [String: Any]?] = [:]
        for (name, enabled) in servers {
            let entry: [String: Any] = [
                "type": "local",
                "command": ["node", serverPath(name)],
                "enabled": true,
                "environment": ["SYNTH_WORKTREE": path],
            ]
            built.updateValue(enabled ? entry : nil, forKey: name)
        }
        merge(atWorktree: path, file: "opencode.json", container: "mcp", entries: built,
              extra: ["$schema": "https://opencode.ai/config.json"])
    }

    /// Reconcile Synth's servers under `container` in `file` — set enabled entries, drop
    /// disabled ones (an inner nil) — preserving whatever else the user keeps there. A
    /// no-op when everything is already correct: the worktree is the user's working tree,
    /// and a needless rewrite shows up as a dirty file in their `git status`.
    private static func merge(atWorktree path: String, file name: String, container: String,
                              entries: [String: [String: Any]?], extra: [String: Any] = [:]) {
        guard FileManager.default.fileExists(atPath: path) else { return }
        let file = URL(fileURLWithPath: path).appendingPathComponent(name)

        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: file) {
            guard let existing = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                // Unparseable user file — leave it alone rather than clobber.
                log.error("\(file.path) exists but isn't a JSON object — not touching it")
                return
            }
            root = existing
        }
        var servers = root[container] as? [String: Any] ?? [:]
        var changed = false
        for (key, entry) in entries {
            if let entry {
                if let current = servers[key] as? [String: Any],
                   NSDictionary(dictionary: current).isEqual(to: entry) { continue }
                servers[key] = entry
                changed = true
            } else if servers[key] != nil {
                servers.removeValue(forKey: key)
                changed = true
            }
        }
        guard changed else { return }
        root[container] = servers
        for (k, v) in extra where root[k] == nil { root[k] = v }
        guard let data = try? JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: file, options: .atomic)
    }
}
