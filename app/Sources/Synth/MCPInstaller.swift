import Foundation
import os.log

/// Installs the bundled MCP servers — synth-browser (ADR-0011 stage two), synth-app
/// (approval-gated app control) and synth-simulator (ADR-0015) — and registers them
/// in every managed worktree.
///
/// Install: the repo's mcp/ (copied into Contents/Resources/mcp by dev.sh /
/// dist.sh) is synced to the channel's Application Support sandbox (AppSupport.root)
/// under browser-mcp/ at launch, with `npm install --omit=dev` run there when
/// node_modules is missing or
/// package.json changed — one shared install, stable path for every .mcp.json.
/// (The dir name predates the second server; renaming it would orphan nothing but
/// churn every config, so it stays.)
///
/// Registration: nothing is written into the worktree. The ENABLED servers (the
/// Settings → MCP servers toggles) are handed to each agent's launch as environment
/// (`launchEnv`), and `synth-hook` turns them into that agent's own registration —
/// `claude --mcp-config`, opencode's `OPENCODE_CONFIG_CONTENT`, and an
/// `.agents/mcp_config.json` inside the Synth-owned dir agy is handed via `--add-dir`.
/// A disabled server is simply absent, so its tools never appear to agents.
///
/// Synth used to write `.mcp.json`, `opencode.json` and `.agents/mcp_config.json` into
/// every managed worktree, which left three untracked files in every user repo (nobody
/// else's `.gitignore` names them) and cost an agent one approval prompt per server on
/// top of Claude's folder-trust prompt. Those files are now swept back up — see
/// `removeStrandedConfigs`.
@MainActor enum MCPInstaller {
    private static let log = Logger(subsystem: bundleIdentifier, category: "mcp")

    static let installDir = AppSupport.dir("browser-mcp")

    /// The bundled servers: registry name → entry script (shared.mjs serves all of them).
    nonisolated static let serverScripts = [
        "synth-browser": "server.mjs",
        "synth-app": "app-server.mjs",
        "synth-simulator": "simulator-server.mjs",
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

    // MARK: Per-launch agent config

    /// In-memory skip: the store re-states this on the autosave cadence, so an unchanged
    /// worktree set (with unchanged toggles) costs nothing.
    private static var lastSynced: (paths: [String], servers: [String: Bool])?
    /// The Settings toggle state, as the next launch should see it.
    private static var enabledServers: [String: Bool] = [:]
    /// Worktrees a launch may claim servers for — a terminal opened anywhere else (the user's
    /// own folder, a path Synth doesn't manage) gets none, because the servers scope every tool
    /// to a worktree Synth knows about and would fail on the first call.
    private static var liveWorktrees: Set<String> = []

    /// Adopt the live worktree set and the Settings toggles. Nothing is written: this only
    /// decides what the next agent launch in each worktree is handed (`launchEnv`), and sweeps
    /// up the config files older builds left in the tree.
    static func updateLaunchConfig(worktrees: [String], servers: [String: Bool]) {
        enabledServers = servers
        liveWorktrees = Set(worktrees.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path })
        guard lastSynced == nil || lastSynced! != (worktrees, servers) else { return }
        lastSynced = (worktrees, servers)
        for path in worktrees { removeStrandedConfigs(in: path) }
    }

    /// The enabled servers in each hosted agent's own schema, as `synth-hook` takes them.
    /// Empty when every server is off, so the launch stays bare, and empty outside a managed
    /// worktree. `SYNTH_WORKTREE` travels in every entry: the servers scope themselves to a
    /// worktree and this is the only thing that names it (`shared.mjs` prefers it over
    /// `CLAUDE_PROJECT_DIR`, which the other two agents don't set at all).
    static func launchEnv(worktree: String) -> [String: String] {
        let path = URL(fileURLWithPath: worktree).resolvingSymlinksInPath().path
        guard liveWorktrees.contains(path) else { return [:] }
        let names = enabledServers.filter(\.value).keys.sorted()
        guard !names.isEmpty else { return [:] }

        let env = channelEnv.merging(["SYNTH_WORKTREE": worktree]) { _, new in new }
        // Claude Code and agy share a schema (command + args + env); opencode takes the command
        // as one array and spells the environment differently.
        var claude: [String: Any] = [:]
        var opencode: [String: Any] = [:]
        for name in names {
            claude[name] = ["command": "node", "args": [serverPath(name)], "env": env]
            opencode[name] = ["type": "local", "command": ["node", serverPath(name)],
                              "enabled": true, "environment": env]
        }
        guard let claudeJSON = json(["mcpServers": claude]),
              let opencodeJSON = json(["mcp": opencode]) else { return [:] }
        return ["SYNTH_MCP_CLAUDE": claudeJSON,
                "SYNTH_MCP_OPENCODE": opencodeJSON,
                "SYNTH_MCP_AGY": claudeJSON]
    }

    private static func json(_ object: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Delete the per-worktree config files older builds wrote, in worktrees that still carry
    /// them. Not just tidying: a stale file registers the same servers a second time alongside
    /// the launch's own copy, and a stale entry points at whatever the toggles said back then.
    ///
    /// Only files that are provably still Synth's are removed — a user who has since put their
    /// own server (or any other opencode setting) in one owns it now, and it stays.
    private static func removeStrandedConfigs(in worktree: String) {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: worktree)
        for relative in [".mcp.json", "opencode.json", ".agents/mcp_config.json"]
        where isUnmodifiedSynthConfig(relative, inWorktree: worktree) {
            try? fm.removeItem(at: root.appendingPathComponent(relative))
            log.info("removed stranded \(relative) from \(worktree)")
        }
        // `.agents/` is agy's whole customization dir — skills, rules and hooks live there too —
        // so it goes only when Synth's file was the only thing in it.
        let agents = root.appendingPathComponent(".agents")
        if let contents = try? fm.contentsOfDirectory(atPath: agents.path), contents.isEmpty {
            try? fm.removeItem(at: agents)
        }
    }

    /// True when `relative` is one of the config files Synth used to write into every managed
    /// worktree AND the user has put nothing of their own in it.
    ///
    /// Deliberately not a bare filename allowlist: a user who added their own servers, or any
    /// other opencode setting, has real work in that file, and deleting it would be Synth
    /// throwing away something it never owned.
    nonisolated static func isUnmodifiedSynthConfig(_ relative: String, inWorktree worktree: String) -> Bool {
        let container: String
        let allowedTopLevel: Set<String>
        switch relative {
        case ".mcp.json":               container = "mcpServers"; allowedTopLevel = ["mcpServers"]
        case "opencode.json":           container = "mcp";        allowedTopLevel = ["mcp", "$schema"]
        case ".agents/mcp_config.json": container = "mcpServers"; allowedTopLevel = ["mcpServers"]
        default: return false
        }
        let file = URL(fileURLWithPath: worktree).appendingPathComponent(relative)
        guard let data = try? Data(contentsOf: file),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return false }
        guard Set(root.keys).isSubset(of: allowedTopLevel) else { return false }
        // Every registered server must be one of ours. An unknown name is the user's.
        let servers = root[container] as? [String: Any] ?? [:]
        return Set(servers.keys).isSubset(of: Set(serverScripts.keys))
    }

    private static func serverPath(_ name: String) -> String {
        installDir.appendingPathComponent(serverScripts[name] ?? "server.mjs").path
    }

    /// Which channel installed the server. The servers discover the running app through
    /// `<AppSupport.root>/instances`, and nothing else in their environment says which sandbox
    /// that is — so without this a dev build's agents find no instances at all, or worse, find a
    /// stable Synth and drive *its* browser. Names AppSupport's own override variable, which is
    /// how the app itself resolves the sandbox.
    private static var channelEnv: [String: String] {
        ["SYNTH_SUPPORT_DIR": AppSupport.root.path]
    }

}
