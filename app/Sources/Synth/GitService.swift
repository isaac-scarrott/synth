import Foundation

/// Reads real data from a git repository. No mock data — everything the tree shows
/// about branches comes from here.
enum GitService {
    struct BranchInfo {
        let name: String
        let lastCommitUnix: TimeInterval
    }

    /// A branch the ⌘K worktree picker can check out — a local branch, or a
    /// remote-tracking branch not present locally. `remote` is nil for locals, else the
    /// remote's name (e.g. "origin") shown as the result's context tag.
    struct BranchRef {
        let name: String
        var isRemote: Bool { remote != nil }
        let remote: String?
    }

    /// Local branches (refs/heads), most-recently-committed first. Empty if the path
    /// isn't a git repository.
    static func branches(at url: URL) -> [BranchInfo] {
        guard isRepository(url) else { return [] }
        let out = run(["-C", url.path, "for-each-ref",
                       "--sort=-committerdate",
                       "--format=%(refname:short)\t%(committerdate:unix)",
                       "refs/heads"])
        return out.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2, let unix = TimeInterval(parts[1]) else { return nil }
            return BranchInfo(name: String(parts[0]), lastCommitUnix: unix)
        }
    }

    /// Every branch the worktree picker can reach — local (refs/heads) plus
    /// remote-tracking (refs/remotes, minus each remote's HEAD symref). A name present
    /// both locally and on a remote appears once, tagged local (locals are read first).
    /// Most-recently-committed first within each source.
    static func allBranches(at url: URL) -> [BranchRef] {
        guard isRepository(url) else { return [] }
        var seen = Set<String>()
        var result: [BranchRef] = []

        let local = run(["-C", url.path, "for-each-ref", "--sort=-committerdate",
                         "--format=%(refname:short)", "refs/heads"])
        for line in local.split(separator: "\n") {
            let name = String(line)
            guard !name.isEmpty, seen.insert(name).inserted else { continue }
            result.append(BranchRef(name: name, remote: nil))
        }

        let remote = run(["-C", url.path, "for-each-ref", "--sort=-committerdate",
                          "--format=%(refname:short)", "refs/remotes"])
        for line in remote.split(separator: "\n") {
            let short = String(line)   // e.g. "origin/feat/billing"; "origin" for origin/HEAD
            guard let slash = short.firstIndex(of: "/") else { continue }   // drops HEAD symref
            let name = String(short[short.index(after: slash)...])
            guard !name.isEmpty, seen.insert(name).inserted else { continue }
            result.append(BranchRef(name: name, remote: String(short[..<slash])))
        }
        return result
    }

    static func isRepository(_ url: URL) -> Bool {
        run(["-C", url.path, "rev-parse", "--is-inside-work-tree"]).trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    }

    // MARK: Worktrees

    struct WorktreeInfo {
        let path: URL
        let branch: String?   // nil when detached
    }

    /// Every worktree of the repo, including the main checkout (the repo root).
    static func worktrees(at url: URL) -> [WorktreeInfo] {
        let out = run(["-C", url.path, "worktree", "list", "--porcelain"])
        var result: [WorktreeInfo] = []
        var path: String?
        var branch: String?
        func flush() {
            if let p = path { result.append(WorktreeInfo(path: URL(fileURLWithPath: p), branch: branch)) }
            path = nil
            branch = nil
        }
        for line in out.split(separator: "\n") {
            if line.hasPrefix("worktree ") { flush(); path = String(line.dropFirst("worktree ".count)) }
            else if line.hasPrefix("branch refs/heads/") { branch = String(line.dropFirst("branch refs/heads/".count)) }
        }
        flush()
        return result
    }

    /// Where the app materialises worktrees. Default location for now — will be
    /// user-configurable later.
    static func worktreeRoot(for repo: URL) -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support
            .appendingPathComponent("Synth/worktrees", isDirectory: true)
            .appendingPathComponent("\(repo.lastPathComponent)-\(stableHash(repo.path))", isDirectory: true)
    }

    static func plannedWorktreePath(repo: URL, branch: String) -> URL {
        let folder = String(branch.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." ? $0 : "-" })
        return worktreeRoot(for: repo).appendingPathComponent(folder, isDirectory: true)
    }

    /// `git worktree add` for an existing branch. Nil on success, else git's message.
    static func addWorktree(repo: URL, path: URL, branch: String) -> String? {
        runWorktreeAdd(repo: repo, path: path, args: [path.path, branch])
    }

    /// `git worktree add -b` for a new branch off `base` (repo HEAD when nil).
    static func addWorktree(repo: URL, path: URL, newBranch: String, base: String?) -> String? {
        var args = ["-b", newBranch, path.path]
        if let base { args.append(base) }
        return runWorktreeAdd(repo: repo, path: path, args: args)
    }

    private static func runWorktreeAdd(repo: URL, path: URL, args: [String]) -> String? {
        try? FileManager.default.createDirectory(at: path.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        let (status, out) = runChecked(["-C", repo.path, "worktree", "add"] + args)
        return status == 0 ? nil : out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `git worktree remove --force` — detaches the worktree from git and deletes its
    /// folder on disk. `--force` so a dirty/locked checkout still goes. Nil on success,
    /// else git's message. The primary worktree (repo root) can't be removed this way;
    /// callers guard against that. `prune` cleans up the stale administrative entry.
    static func removeWorktree(repo: URL, path: URL) -> String? {
        let (status, out) = runChecked(["-C", repo.path, "worktree", "remove", "--force", path.path])
        if status == 0 { _ = runChecked(["-C", repo.path, "worktree", "prune"]); return nil }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Drop administrative entries whose checkout folder is gone (a fast delete's rename,
    /// or a folder removed outside Synth).
    static func pruneWorktrees(at repo: URL) {
        _ = runChecked(["-C", repo.path, "worktree", "prune"])
    }

    /// Phase one of a fast delete: atomically rename the checkout to a hidden
    /// `.deleting-…` sibling (same volume, so O(1) regardless of tree size) and prune
    /// git's administrative entry. Returns the moved folder for the caller to delete at
    /// leisure off the critical path, or nil when the rename failed — the caller falls
    /// back to the blocking `removeWorktree`.
    static func detachWorktree(repo: URL, path: URL) -> URL? {
        let trash = path.deletingLastPathComponent().appendingPathComponent(
            ".deleting-\(path.lastPathComponent)-\(UUID().uuidString.prefix(8))", isDirectory: true)
        do { try FileManager.default.moveItem(at: path, to: trash) } catch { return nil }
        _ = runChecked(["-C", repo.path, "worktree", "prune"])
        return trash
    }

    /// Launch sweep: delete `.deleting-…` folders a crash left behind under the app's
    /// worktree root (a detached delete that never finished its background rm).
    static func sweepDetachedWorktrees() {
        let fm = FileManager.default
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Synth/worktrees", isDirectory: true)
        guard let repos = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        for repo in repos {
            guard let entries = try? fm.contentsOfDirectory(at: repo, includingPropertiesForKeys: nil) else { continue }
            for entry in entries where entry.lastPathComponent.hasPrefix(".deleting-") {
                try? fm.removeItem(at: entry)
            }
        }
    }

    /// Repos sharing a folder name get distinct worktree roots. hashValue is seeded
    /// per launch, so roots must come from a stable hash to be reused across runs.
    private static func stableHash(_ s: String) -> String {
        var h: UInt32 = 5381
        for b in s.utf8 { h = h &* 33 &+ UInt32(b) }
        return String(format: "%08x", h)
    }

    /// Compact relative age, matching the mock's "2h" / "5d" style.
    static func compactAge(_ unix: TimeInterval) -> String {
        let secs = max(0, Date().timeIntervalSince1970 - unix)
        switch secs {
        case ..<60:        return "now"
        case ..<3_600:     return "\(Int(secs / 60))m"
        case ..<86_400:    return "\(Int(secs / 3_600))h"
        case ..<604_800:   return "\(Int(secs / 86_400))d"
        case ..<2_592_000: return "\(Int(secs / 604_800))w"
        default:           return "\(Int(secs / 2_592_000))mo"
        }
    }

    private static func run(_ args: [String]) -> String {
        runChecked(args).output
    }

    /// The configured git identity (global/user config — no repo needed). nil when unset.
    /// Feedback gates its author path on this matching a known author address.
    static func gitUserEmail() -> String? {
        let (status, out) = runChecked(["config", "--get", "user.email"])
        let email = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return status == 0 && !email.isEmpty ? email : nil
    }

    private static func runChecked(_ args: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
        } catch {
            return (-1, "\(error.localizedDescription)")
        }
    }
}
