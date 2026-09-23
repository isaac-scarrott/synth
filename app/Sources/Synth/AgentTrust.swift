import Foundation

/// An agent's own record of the folders the user has trusted, as that agent keeps it. A folder it
/// has never seen opens on a trust prompt, and a routine has nobody there to answer it.
///
/// The one write Synth makes to either file copies a decision the user already made — the repo is
/// trusted — onto a folder Synth itself just created for it. It never trusts anything else.
enum AgentTrust {
    /// Claude Code: `projects[<absolute path>].hasTrustDialogAccepted` in its global config
    /// (`$CLAUDE_CONFIG_DIR/.claude.json`, else `~/.claude.json`).
    ///
    /// How 2.1.280 decides a folder is trusted (read from its bundle, and confirmed by running it):
    /// the entry for the folder's *canonical* git root — for a linked worktree, the main repo's
    /// root — or any entry on the walk from the folder up to its own git root. Nothing above the
    /// git root counts. So a worktree of a trusted repo is already trusted today; the entry
    /// written here is what keeps an unattended run from stalling on a version that resolves it
    /// any other way.
    case claude
    /// Antigravity (`agy`): the `trustedWorkspaces` array in `~/.gemini/antigravity-cli/settings.json`.
    ///
    /// How 1.2.9 decides (run in a pty against an isolated HOME): the folder is trusted only when
    /// the list holds its working directory *exactly* as Go's `os.Getwd` spells it — `$PWD` when
    /// that names the folder, else the kernel's path. No walk to a parent or a git root, no
    /// resolving symlinks, and a trailing slash is a different folder. Accepting its prompt
    /// appends that same spelling. So a worktree of a trusted repo is *not* trusted, and every
    /// run in a folder Synth cut would stop at the prompt without the entry written here.
    case antigravity

    struct Unwritable: Error, LocalizedError {
        let why: String
        var errorDescription: String? { why }
    }

    /// The name the user knows the agent by, in the sentence a stalled run says.
    var agentName: String {
        switch self {
        case .claude: "Claude Code"
        case .antigravity: "Antigravity"
        }
    }

    /// The agent's live file. Gates point Synth at their own, so a driven run never reads or
    /// writes the user's: `CLAUDE_CONFIG_DIR`, which Claude honours too, and `SYNTH_AGY_SETTINGS`,
    /// which only Synth does — `agy` has no override of its own and always reads `$HOME`'s.
    var file: URL {
        let env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch self {
        case .claude:
            if let dir = env["CLAUDE_CONFIG_DIR"], !dir.isEmpty {
                return URL(fileURLWithPath: dir).appendingPathComponent(".claude.json")
            }
            return home.appendingPathComponent(".claude.json")
        case .antigravity:
            if let path = env["SYNTH_AGY_SETTINGS"], !path.isEmpty { return URL(fileURLWithPath: path) }
            return home.appendingPathComponent(".gemini/antigravity-cli/settings.json")
        }
    }

    /// Whether the user has trusted `repo` in this agent. An unreadable file is "no": the run
    /// goes ahead and says why it stalled, rather than Synth guessing.
    func isTrusted(_ repo: URL) -> Bool {
        guard let config = try? read() else { return false }
        let spellings = Self.spellings(of: repo)
        switch self {
        case .claude:
            guard let projects = config["projects"] as? [String: Any] else { return false }
            return spellings.contains { key in
                (projects[key] as? [String: Any])?["hasTrustDialogAccepted"] as? Bool == true
            }
        case .antigravity:
            let trusted = config["trustedWorkspaces"] as? [String] ?? []
            return spellings.contains(where: trusted.contains)
        }
    }

    /// Trust `folder` because `repo` is trusted. False, touching nothing, when the repo isn't
    /// (or there is no file at all). Only the folder's own entry changes; every other key is
    /// carried through as read.
    @discardableResult
    func inherit(_ folder: URL, from repo: URL) throws -> Bool {
        guard isTrusted(repo) else { return false }
        // Both agents write this file whenever they like. Read again right before the write, so
        // the window in which one of their writes could be lost is one encode, not the whole start.
        guard var config = try read() else { return false }
        switch self {
        case .claude:
            let key = Self.realpath(folder)
            var projects = config["projects"] as? [String: Any] ?? [:]
            var entry = projects[key] as? [String: Any] ?? [:]
            if entry["hasTrustDialogAccepted"] as? Bool == true { return true }
            entry["hasTrustDialogAccepted"] = true
            projects[key] = entry
            config["projects"] = projects
        case .antigravity:
            // The terminal is handed the folder as given; `agy` sees that spelling when the shell
            // keeps it as `$PWD`, the resolved one when it doesn't. Both name this one folder.
            var trusted = config["trustedWorkspaces"] as? [String] ?? []
            let missing = Self.spellings(of: folder).sorted().filter { !trusted.contains($0) }
            if missing.isEmpty { return true }
            trusted += missing
            config["trustedWorkspaces"] = trusted
        }
        try write(config)
        return true
    }

    /// The spellings a folder may be filed under: as given, and resolved.
    private static func spellings(of url: URL) -> Set<String> {
        var given = url.path
        while given.count > 1, given.hasSuffix("/") { given.removeLast() }
        return [given, realpath(url)]
    }

    /// The path as the kernel resolves it — Claude's own spelling. Not `resolvingSymlinksInPath`,
    /// which turns `/private/tmp/x` into `/tmp/x`, the one spelling Claude never writes.
    private static func realpath(_ url: URL) -> String {
        guard let resolved = Darwin.realpath(url.path, nil) else { return url.path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private func read() throws -> [String: Any]? {
        let file = file
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let data = try Data(contentsOf: file)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Unwritable(why: "\(agentName)'s config isn't a JSON object.")
        }
        return object
    }

    /// Temp file beside the real one, then a rename: the agent never reads half a file. The
    /// temp is created 0600, as both agents create their own, and a symlinked file is written
    /// through to its target.
    private func write(_ config: [String: Any]) throws {
        let target = file.resolvingSymlinksInPath()
        let data = try JSONSerialization.data(withJSONObject: config,
                                              options: [.prettyPrinted, .withoutEscapingSlashes])
        let temp = target.deletingLastPathComponent()
            .appendingPathComponent(".\(target.lastPathComponent).synth-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: temp.path, contents: data,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw Unwritable(why: "Synth couldn't write beside \(agentName)'s config.")
        }
        guard rename(temp.path, target.path) == 0 else {
            let why = String(cString: strerror(errno))
            try? FileManager.default.removeItem(at: temp)
            throw Unwritable(why: "Synth couldn't replace \(agentName)'s config: \(why)")
        }
    }
}
