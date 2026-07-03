import Foundation

/// Reads real data from a git repository. No mock data — everything the tree shows
/// about branches comes from here.
enum GitService {
    struct BranchInfo {
        let name: String
        let lastCommitUnix: TimeInterval
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
