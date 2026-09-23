import Foundation

/// Claude Code's folder trust, as it keeps it: `projects[<absolute path>].hasTrustDialogAccepted`
/// in its global config (`$CLAUDE_CONFIG_DIR/.claude.json`, else `~/.claude.json`).
///
/// How Claude Code 2.1.280 decides a folder is trusted (read from its bundle, and confirmed by
/// running it): the entry for the folder's *canonical* git root — for a linked worktree, the main
/// repo's root — or any entry on the walk from the folder up to its own git root. Nothing above
/// the git root counts. So a worktree of a trusted repo is already trusted today; the entry
/// written here is what keeps an unattended run from stalling on a version that resolves it any
/// other way.
///
/// The one write Synth makes to that file copies a decision the user already made — the repo is
/// trusted — onto a folder Synth itself just created for it. It never trusts anything else.
enum ClaudeTrust {
    struct Unwritable: Error, LocalizedError {
        let why: String
        var errorDescription: String? { why }
    }

    /// Claude's live config. Gates point Synth (and the Claude it spawns) at their own with
    /// `CLAUDE_CONFIG_DIR`, so a driven run never reads or writes the user's.
    static var configFile: URL {
        if let dir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir).appendingPathComponent(".claude.json")
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
    }

    /// Whether the user has trusted `repo` in Claude Code. An unreadable config is "no": the
    /// run goes ahead and says why it stalled, rather than Synth guessing.
    static func isTrusted(_ repo: URL) -> Bool {
        guard let projects = (try? read())?["projects"] as? [String: Any] else { return false }
        return keys(for: repo).contains { key in
            (projects[key] as? [String: Any])?["hasTrustDialogAccepted"] as? Bool == true
        }
    }

    /// Trust `folder` because `repo` is trusted. False, touching nothing, when the repo isn't
    /// (or there is no config at all). Only `projects[<folder>].hasTrustDialogAccepted` changes;
    /// every other key is carried through as read.
    @discardableResult
    static func inherit(_ folder: URL, from repo: URL) throws -> Bool {
        guard isTrusted(repo) else { return false }
        let key = realpath(folder)
        // Claude writes this file whenever it likes. Read again right before the write, so the
        // window in which one of its writes could be lost is one encode, not the whole start.
        guard var config = try read() else { return false }
        var projects = config["projects"] as? [String: Any] ?? [:]
        var entry = projects[key] as? [String: Any] ?? [:]
        if entry["hasTrustDialogAccepted"] as? Bool == true { return true }
        entry["hasTrustDialogAccepted"] = true
        projects[key] = entry
        config["projects"] = projects
        try write(config)
        return true
    }

    /// The spellings Claude may have filed the repo under: as given, and resolved.
    private static func keys(for repo: URL) -> Set<String> {
        var given = repo.path
        while given.count > 1, given.hasSuffix("/") { given.removeLast() }
        return [given, realpath(repo)]
    }

    /// The path as the kernel resolves it — Claude's own spelling. Not `resolvingSymlinksInPath`,
    /// which turns `/private/tmp/x` into `/tmp/x`, the one spelling Claude never writes.
    private static func realpath(_ url: URL) -> String {
        guard let resolved = Darwin.realpath(url.path, nil) else { return url.path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func read() throws -> [String: Any]? {
        let file = configFile
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let data = try Data(contentsOf: file)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Unwritable(why: "Claude Code's config isn't a JSON object.")
        }
        return object
    }

    /// Temp file beside the real one, then a rename: Claude never reads half a file. The
    /// temp is created 0600, as Claude creates its own, and a symlinked config is written
    /// through to its target.
    private static func write(_ config: [String: Any]) throws {
        let target = configFile.resolvingSymlinksInPath()
        let data = try JSONSerialization.data(withJSONObject: config,
                                              options: [.prettyPrinted, .withoutEscapingSlashes])
        let temp = target.deletingLastPathComponent()
            .appendingPathComponent(".\(target.lastPathComponent).synth-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: temp.path, contents: data,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw Unwritable(why: "Synth couldn't write beside Claude Code's config.")
        }
        guard rename(temp.path, target.path) == 0 else {
            let why = String(cString: strerror(errno))
            try? FileManager.default.removeItem(at: temp)
            throw Unwritable(why: "Synth couldn't replace Claude Code's config: \(why)")
        }
    }
}
