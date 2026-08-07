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

    /// The nearest folder at or above `url` holding a `.git` entry, or nil when there is none.
    /// A pure filesystem probe by design: `NSOpenPanel`'s `validate:` hook runs on the main
    /// thread with the modal panel up, where one git spawn against a stale network mount would
    /// beachball the app. Ancestors count because picking a subfolder of a repo means the repo,
    /// and `repositoryRoot` resolves it. `.git` is a *file* inside a linked worktree, so
    /// existence is the test — requiring a directory would reject every worktree Synth makes.
    static func enclosingRepositoryMarker(_ url: URL) -> URL? {
        var dir = url.standardizedFileURL
        while true {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent(".git").path) { return dir }
            let parent = dir.deletingLastPathComponent().standardizedFileURL
            if parent.path == dir.path { return nil }
            dir = parent
        }
    }

    /// The root of the working tree containing `url` — where a project gets added, so every
    /// branch of the repo is reachable from it and one repo can't become two projects. Picking
    /// a subfolder used to be accepted silently and was worse than a refusal: the row pointed at
    /// the repo root while `worktreeRoot` hashed the subpath, so the same repo added at two
    /// depths got two unrelated worktree roots. `--show-toplevel` also answers with the real
    /// on-disk path, collapsing the symlink, `/tmp`-vs-`/private/tmp` and case-only variants
    /// that would otherwise hash apart for one repo. Nil when `url` is in no working tree.
    static func repositoryRoot(_ url: URL) -> URL? {
        let (status, out) = runChecked(["-C", url.path, "rev-parse", "--show-toplevel"])
        let path = out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard status == 0, !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    // MARK: Worktrees

    struct WorktreeInfo {
        let path: URL
        let branch: String?   // nil when detached
        /// `git worktree lock` — a machine-readable "do not touch" the sweeper honours.
        var isLocked: Bool = false
        /// git already considers the checkout folder gone. An archived worktree reads
        /// prunable, because archiving renames the folder aside without pruning.
        var isPrunable: Bool = false
    }

    /// Every worktree of the repo, including the main checkout (the repo root).
    static func worktrees(at url: URL) -> [WorktreeInfo] {
        let out = run(["-C", url.path, "worktree", "list", "--porcelain"])
        var result: [WorktreeInfo] = []
        var path: String?
        var branch: String?
        var locked = false
        var prunable = false
        func flush() {
            if let p = path {
                result.append(WorktreeInfo(path: URL(fileURLWithPath: p), branch: branch,
                                           isLocked: locked, isPrunable: prunable))
            }
            path = nil
            branch = nil
            locked = false
            prunable = false
        }
        for line in out.split(separator: "\n") {
            // `locked` and `prunable` appear bare or with a trailing reason, so match the
            // prefix rather than the whole line.
            if line.hasPrefix("worktree ") { flush(); path = String(line.dropFirst("worktree ".count)) }
            else if line.hasPrefix("branch refs/heads/") { branch = String(line.dropFirst("branch refs/heads/".count)) }
            else if line == "locked" || line.hasPrefix("locked ") { locked = true }
            else if line == "prunable" || line.hasPrefix("prunable ") { prunable = true }
        }
        flush()
        return result
    }

    /// Where the app materialises worktrees. Default location for now — will be
    /// user-configurable later.
    static func worktreeRoot(for repo: URL) -> URL {
        return AppSupport.dir("worktrees")
            .appendingPathComponent("\(repo.lastPathComponent)-\(stableHash(repo.path))", isDirectory: true)
    }

    static func plannedWorktreePath(repo: URL, branch: String) -> URL {
        let folder = String(branch.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." ? $0 : "-" })
        return worktreeRoot(for: repo).appendingPathComponent(folder, isDirectory: true)
    }

    /// `git worktree add` for an existing branch. Nil on success, else git's message.
    static func addWorktree(repo: URL, path: URL, branch: String) -> String? {
        runWorktreeAdd(repo: repo, path: path, branch: branch, args: [path.path, branch])
    }

    /// `git worktree add -b` for a new branch. With no explicit `base`, forks off the
    /// repo's default branch (`defaultBase`) rather than whatever HEAD happens to be
    /// checked out — the base a caller passing nil means. Nil on success, else git's message.
    static func addWorktree(repo: URL, path: URL, newBranch: String, base: String?) -> String? {
        let from = base ?? defaultBase(at: repo)
        return runWorktreeAdd(repo: repo, path: path, branch: newBranch,
                              args: ["-b", newBranch, path.path, from])
    }

    // MARK: Default base

    /// The ref a new branch forks off by default: the repo's default branch as its
    /// locally-tracked remote ref (e.g. "origin/main"), so work starts from the shared
    /// baseline rather than the current checkout. Resolution, cheapest first: origin/HEAD's
    /// symref; if that's unset, ask the remote once (`set-head -a`) and re-read; then a local
    /// main/master; finally the repo's own HEAD (local-only repo with no default). No fetch —
    /// the tracked origin/<default> is fresh enough, and a network round-trip on the create
    /// path would cost the speed that's the point.
    static func defaultBase(at url: URL) -> String {
        guard isRepository(url) else { return "HEAD" }
        if let ref = originHead(at: url) { return ref }
        _ = runChecked(["-C", url.path, "remote", "set-head", "origin", "-a"])
        if let ref = originHead(at: url) { return ref }
        for name in ["main", "master"] where localBranchExists(name, at: url) { return name }
        return "HEAD"
    }

    /// origin/HEAD's target as a short remote ref ("origin/main"), or nil when it's unset.
    /// Status, not emptiness, decides. `git symbolic-ref` on a repo with no origin exits non-zero
    /// and prints "fatal: ref refs/remotes/origin/HEAD is not a symbolic ref" — which `run` folds
    /// into its output, so a non-empty check reads that sentence back as a ref name. `defaultBase`
    /// then returned it, `addWorktree` forked off it, and every create in a remote-less repo died
    /// on `not a valid object name: 'fatal: ref …'` — with the main/master fallbacks below
    /// unreachable, because this never answered nil.
    private static func originHead(at url: URL) -> String? {
        let (status, out) = runChecked(["-C", url.path, "symbolic-ref", "--short", "refs/remotes/origin/HEAD"])
        let ref = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return status == 0 && !ref.isEmpty ? ref : nil
    }

    private static func localBranchExists(_ name: String, at url: URL) -> Bool {
        runChecked(["-C", url.path, "rev-parse", "--verify", "--quiet", "refs/heads/\(name)"]).status == 0
    }

    /// The base's short display name for the "New branch off …" note — the remote prefix
    /// dropped ("origin/main" → "main"), so the UI names the branch, not the tracking ref.
    static func baseDisplayName(_ base: String) -> String {
        guard let slash = base.firstIndex(of: "/") else { return base }
        return String(base[base.index(after: slash)...])
    }

    /// A non-zero `worktree add` doesn't always mean no worktree: the checkout lands first
    /// and the repo's own post-checkout hook runs after it, so a failing hook (husky's
    /// `pnpm install` can't resolve pnpm on a GUI launch PATH) fails the command while
    /// leaving a fully materialised checkout behind. Trust the outcome, not the exit code:
    /// if the worktree is registered at `path` on `branch`, that's a success. This also
    /// absorbs the orphan a previous hook-failed create left ("branch already exists" on
    /// retry, but the worktree it wants is already there).
    private static func runWorktreeAdd(repo: URL, path: URL, branch: String, args: [String]) -> String? {
        try? FileManager.default.createDirectory(at: path.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        let (status, out) = runChecked(["-C", repo.path, "worktree", "add"] + args)
        if status == 0 { return nil }
        let planned = path.resolvingSymlinksInPath().path
        if worktrees(at: repo).contains(where: {
            $0.branch == branch && $0.path.resolvingSymlinksInPath().path == planned
        }) {
            NSLog("Synth: worktree add exited \(status) but \(branch) materialised — treating as success. git said: \(out.trimmingCharacters(in: .whitespacesAndNewlines))")
            return nil
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
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
    ///
    /// `prune` is repo-global: it drops the entry for *any* worktree of this repo whose
    /// folder is currently unreachable, not just the one the caller had in mind. An
    /// unmounted volume looks exactly like a deleted folder to it, so a prune while a
    /// worktree's disk is detached destroys that worktree's index and reflog for a folder
    /// that was never deleted. `pruneIsSafe` is the same reachability test the restore path
    /// uses (`AppStore.confirmedMissing`) — an absent path whose *parent* is also absent is
    /// unreachable, not gone.
    static func pruneWorktrees(at repo: URL) {
        guard pruneIsSafe(at: repo) else { return }
        _ = runChecked(["-C", repo.path, "worktree", "prune"])
    }

    /// False when any of the repo's worktrees sits on a path we can't currently see, which
    /// makes a prune destructive to a worktree nobody asked to touch.
    static func pruneIsSafe(at repo: URL) -> Bool {
        let fm = FileManager.default
        for wt in worktrees(at: repo) {
            let path = wt.path.path
            guard !fm.fileExists(atPath: path) else { continue }
            let parent = wt.path.deletingLastPathComponent().path
            if !fm.fileExists(atPath: parent) { return false }
        }
        return true
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
        pruneWorktrees(at: repo)
        return trash
    }

    // MARK: Archive hold

    static let archivePrefix = ".archived-"

    /// The sweeper's terminal act, and deliberately *not* a delete: rename the checkout to a
    /// hidden `.archived-<name>-<epoch>-<id>` sibling and stop. The folder is intact and one
    /// `mv` from being restored for `archiveHold` days, after which `reapHeldWorktrees` — which
    /// reads nothing but the epoch in the filename — deletes it for real.
    ///
    /// Crucially this does **not** prune. Pruning drops `<repo>/.git/worktrees/<name>/`, which
    /// holds the worktree's index and its HEAD reflog; that would make the hold recover files
    /// but not git state, and "reversible" would be a lie. Leaving the entry costs a line of
    /// `prunable` in `worktree list` and buys a restore that is exactly `mv` back. The prune
    /// happens at reap, once the folder is genuinely gone.
    ///
    /// Returns the held folder, or nil when the rename failed.
    static func holdWorktree(repo: URL, path: URL, now: Date = Date()) -> URL? {
        let stamp = Int(now.timeIntervalSince1970)
        let held = path.deletingLastPathComponent().appendingPathComponent(
            "\(archivePrefix)\(path.lastPathComponent)-\(stamp)-\(UUID().uuidString.prefix(8))",
            isDirectory: true)
        do { try FileManager.default.moveItem(at: path, to: held) } catch { return nil }
        return held
    }

    /// Undo a hold: move the folder back to where git still expects it. No `worktree repair`
    /// is needed precisely because `holdWorktree` never pruned. Returns true on success.
    static func releaseHeldWorktree(from held: URL, to path: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: held.path), !fm.fileExists(atPath: path.path) else { return false }
        do { try fm.moveItem(at: held, to: path) } catch { return false }
        return true
    }

    /// The epoch a `.archived-…` folder was held at, or nil when the name doesn't carry one.
    static func heldAt(_ folder: URL) -> Date? {
        let name = folder.lastPathComponent
        guard name.hasPrefix(archivePrefix) else { return nil }
        // …-<epoch>-<id>: the id is the last field, the epoch the one before it.
        let fields = name.split(separator: "-")
        guard fields.count >= 2, let epoch = TimeInterval(fields[fields.count - 2]) else { return nil }
        return Date(timeIntervalSince1970: epoch)
    }

    /// Launch sweep: delete `.deleting-…` folders a crash left behind under the app's
    /// worktree root (a detached delete that never finished its background rm).
    static func sweepDetachedWorktrees() {
        forEachWorktreeRootEntry { _, entry in
            guard entry.lastPathComponent.hasPrefix(".deleting-") else { return }
            try? FileManager.default.removeItem(at: entry)
        }
    }

    /// The reaper. Deletes `.archived-…` folders whose hold has expired, then prunes the repo
    /// they belonged to. This is the only irreversible step in the whole archive path, and it
    /// is deliberately the dumbest code in it: it consults no policy, no PR state, and no
    /// persisted store — only a timestamp in a folder name. No bug in the sweep predicate can
    /// reach it early.
    static func reapHeldWorktrees(hold: TimeInterval, now: Date = Date()) {
        var touched = Set<URL>()
        forEachWorktreeRootEntry { root, entry in
            guard let at = heldAt(entry), now.timeIntervalSince(at) >= hold else { return }
            do { try FileManager.default.removeItem(at: entry) } catch { return }
            touched.insert(root)
        }
        // The folders are gone for real now, so the entries they left behind are safe to drop.
        // Each root maps back to one repo via the worktree its entries name.
        for root in touched { pruneRepoBehind(root) }
    }

    /// `worktreeRoot(for:)` hashes the repo path, so a root can't be reversed into a repo.
    /// Any surviving sibling worktree names it, though — that folder is a checkout of the
    /// repo, and `rev-parse` inside it points at the common dir.
    private static func pruneRepoBehind(_ root: URL) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        for entry in entries where !entry.lastPathComponent.hasPrefix(".") {
            let (status, out) = runChecked(["-C", entry.path, "rev-parse", "--path-format=absolute",
                                            "--git-common-dir"], timeout: 10)
            guard status == 0 else { continue }
            let common = out.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !common.isEmpty else { continue }
            let repo = URL(fileURLWithPath: common).deletingLastPathComponent()
            pruneWorktrees(at: repo)
            return
        }
    }

    private static func forEachWorktreeRootEntry(_ body: (_ root: URL, _ entry: URL) -> Void) {
        let fm = FileManager.default
        let root = AppSupport.dir("worktrees")
        guard let repos = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        for repo in repos {
            guard let entries = try? fm.contentsOfDirectory(at: repo, includingPropertiesForKeys: nil) else { continue }
            for entry in entries { body(repo, entry) }
        }
    }

    // MARK: Sweep probes
    //
    // Everything the archive sweeper asks git before it will touch a folder. Each probe
    // answers `.unknown` when git couldn't be asked — a non-zero exit, a timeout, an
    // unparseable answer. `.unknown` is never "clean": `runChecked` merges stderr into
    // stdout, so a `fatal:` is indistinguishable from porcelain by content, and inferring
    // a clean tree from a failed probe is how a sweeper deletes work.

    /// A probe's answer, or the fact that there isn't one.
    enum Probe<T> {
        case known(T)
        case unknown

        var value: T? {
            if case .known(let v) = self { return v }
            return nil
        }
    }

    struct Cleanliness {
        /// Staged, unstaged, or unmerged changes to tracked files.
        var tracked: [String] = []
        /// Untracked and unignored — source that exists in no commit and on no remote.
        var untracked: [String] = []
    }

    /// `--no-optional-locks` matters: without it `status` refreshes and writes the worktree's
    /// index, which races a live agent working in that folder.
    static func cleanliness(at wt: URL) -> Probe<Cleanliness> {
        let (status, out) = runChecked(["-C", wt.path, "--no-optional-locks", "status",
                                        "--porcelain=v2", "-uall", "--ignore-submodules=none"],
                                       timeout: probeTimeout)
        guard status == 0 else { return .unknown }
        var result = Cleanliness()
        for line in out.split(separator: "\n") {
            if line.hasPrefix("1 ") || line.hasPrefix("2 ") || line.hasPrefix("u ") {
                result.tracked.append(String(line))
            } else if line.hasPrefix("? ") {
                result.untracked.append(String(line.dropFirst(2)))
            }
        }
        return .known(result)
    }

    /// Commits on this worktree's HEAD that no remote-tracking ref can reach — the one check
    /// that actually answers "would deleting this folder lose work".
    ///
    /// Deliberately `--not --remotes` and not `@{upstream}`: with `autoSetupMerge` a branch
    /// cut off `origin/main` has upstream `origin/main`, so "ahead 3" only means "not in
    /// main" and says nothing about whether the commits are pushed anywhere. Branches with no
    /// upstream at all make `@{upstream}` an error rather than an answer.
    static func commitsOnNoRemote(at wt: URL) -> Probe<Int> {
        let (status, out) = runChecked(["-C", wt.path, "rev-list", "--count", "HEAD", "--not", "--remotes"],
                                       timeout: probeTimeout)
        guard status == 0, let n = Int(out.trimmingCharacters(in: .whitespacesAndNewlines)) else { return .unknown }
        return .known(n)
    }

    static func remotes(at repo: URL) -> Probe<[String]> {
        let (status, out) = runChecked(["-C", repo.path, "remote"], timeout: probeTimeout)
        guard status == 0 else { return .unknown }
        return .known(out.split(separator: "\n").map(String.init))
    }

    /// A half-finished rebase leaves a *clean* worktree with unreplayed patches sitting in
    /// `rebase-merge/`. None of this surfaces in `status --porcelain`, so it has to be read
    /// off the git dir directly. Returns the operation's name, or nil when there isn't one.
    static func inProgressOperation(at wt: URL) -> Probe<String?> {
        guard let dir = gitDir(at: wt) else { return .unknown }
        let fm = FileManager.default
        let markers = [("rebase-merge", "rebase"), ("rebase-apply", "rebase"), ("MERGE_HEAD", "merge"),
                       ("CHERRY_PICK_HEAD", "cherry-pick"), ("REVERT_HEAD", "revert"),
                       ("BISECT_LOG", "bisect"), ("sequencer", "revert"), ("AUTO_MERGE", "merge")]
        for (file, name) in markers where fm.fileExists(atPath: dir.appendingPathComponent(file).path) {
            return .known(name)
        }
        return .known(nil)
    }

    /// Ignored files whose loss would hurt and that no remote can restore — the `.env` class.
    /// `--directory` collapses whole ignored trees (`node_modules/`) to one entry, which is
    /// what keeps this cheap enough to run on a tick. Paths are worktree-relative; the caller
    /// decides whether each one is reconstructible from the parent repo.
    static func preciousIgnored(at wt: URL) -> Probe<[String]> {
        let (status, out) = runChecked(["-C", wt.path, "ls-files", "--others", "--ignored",
                                        "--exclude-standard", "--directory"], timeout: probeTimeout)
        guard status == 0 else { return .unknown }
        let hits = out.split(separator: "\n").map(String.init).filter { path in
            guard path.split(separator: "/").count <= 3 else { return false }
            let name = (path as NSString).lastPathComponent
            if name.hasPrefix(".env") { return true }
            return [".pem", ".key", ".db", ".sqlite", ".sqlite3"].contains { name.hasSuffix($0) }
        }
        return .known(hits)
    }

    /// Stash entries whose subject names this branch. Stashes live in the repo, not the
    /// worktree, so they *survive* the folder — this is lost context, not lost work.
    static func stashSubjects(at repo: URL) -> Probe<[String]> {
        let (status, out) = runChecked(["-C", repo.path, "stash", "list", "--format=%gs"],
                                       timeout: probeTimeout)
        guard status == 0 else { return .unknown }
        return .known(out.split(separator: "\n").map(String.init))
    }

    static func hasDirtySubmodules(at wt: URL) -> Probe<Bool> {
        guard FileManager.default.fileExists(atPath: wt.appendingPathComponent(".gitmodules").path) else {
            return .known(false)
        }
        let (status, out) = runChecked(["-C", wt.path, "submodule", "status", "--recursive"],
                                       timeout: probeTimeout)
        guard status == 0 else { return .unknown }
        return .known(out.split(separator: "\n").contains { $0.hasPrefix("+") || $0.hasPrefix("U") })
    }

    /// `git merge-base --is-ancestor` — 0 when `ancestor` is reachable from `descendant`.
    /// Exit 1 is a real "no"; anything else (a missing ref, say) is `.unknown`.
    static func isAncestor(_ ancestor: String, of descendant: String, at wt: URL) -> Probe<Bool> {
        let (status, _) = runChecked(["-C", wt.path, "merge-base", "--is-ancestor", ancestor, descendant],
                                     timeout: probeTimeout)
        switch status {
        case 0:  return .known(true)
        case 1:  return .known(false)
        default: return .unknown
        }
    }

    /// A held index lock means something else is mid-write in this worktree.
    static func hasIndexLock(at wt: URL) -> Bool {
        guard let dir = gitDir(at: wt) else { return false }
        return FileManager.default.fileExists(atPath: dir.appendingPathComponent("index.lock").path)
    }

    /// `git fetch --prune`, so `--not --remotes` is answering against refs the remote still
    /// has. A stale remote-tracking ref can make a force-pushed branch read as fully pushed.
    static func fetchPrune(at repo: URL) -> Bool {
        runChecked(["-C", repo.path, "fetch", "--prune", "--quiet", "origin"], timeout: 30).status == 0
    }

    // MARK: Worktree diffstat
    //
    // What a branch's worktree has done to the codebase, for the sidebar's hover card:
    // "+412 −128 · 6 ahead of main". Same `Probe` contract as the sweep probes — nothing
    // here infers "no changes" from a git that couldn't be asked.

    struct DiffCounts: Sendable, Equatable {
        var insertions: Int = 0
        var deletions: Int = 0
    }

    /// Lines added and removed against `base` — committed work and uncommitted work counted
    /// together, as one number.
    ///
    /// Deliberately the merge base diffed against the *working tree*, not `base...HEAD` plus a
    /// second diff of the working tree against HEAD. Summing those two double-counts every line
    /// a commit touched and the user has since edited again, so a worktree mid-change would
    /// inflate the moment it got interesting. One diff from the fork point to what's on disk is
    /// the number the card claims to show.
    ///
    /// Untracked files are absent, because `git diff` never sees them: a file in no commit and
    /// no index has no before-state to count lines against.
    ///
    /// `--no-optional-locks` for the same reason `cleanliness` uses it — a diff against the
    /// working tree refreshes and writes the index, which races a live agent in that folder.
    static func diffStat(against base: String, at wt: URL) -> Probe<DiffCounts> {
        let (baseStatus, baseOut) = runChecked(["-C", wt.path, "merge-base", base, "HEAD"],
                                               timeout: probeTimeout)
        let forkPoint = baseOut.trimmingCharacters(in: .whitespacesAndNewlines)
        guard baseStatus == 0, !forkPoint.isEmpty else { return .unknown }
        let (status, out) = runChecked(["-C", wt.path, "--no-optional-locks", "diff",
                                        "--shortstat", forkPoint], timeout: probeTimeout)
        guard status == 0 else { return .unknown }
        return .known(parseShortstat(out))
    }

    /// ` 12 files changed, 412 insertions(+), 128 deletions(-)`. Either half is omitted when it
    /// is zero, both are when nothing changed at all (git prints an empty line), and each is
    /// singular at one ("1 deletion(-)") — so match the prefix and let a missing field stay 0.
    private static func parseShortstat(_ out: String) -> DiffCounts {
        var stat = DiffCounts()
        for field in out.split(separator: ",") {
            let words = field.split(separator: " ")
            guard words.count >= 2, let n = Int(words[0]) else { continue }
            if words[1].hasPrefix("insertion") { stat.insertions = n }
            if words[1].hasPrefix("deletion") { stat.deletions = n }
        }
        return stat
    }

    /// Commits on this worktree's HEAD that `base` can't reach — the "6 ahead of main" half.
    ///
    /// Not `commitsOnNoRemote`, which answers a different question (unpushed anywhere) and
    /// would read as a lie under this label: work pushed to a PR branch is 0 by that count and
    /// still very much ahead of main.
    static func commitsAhead(of base: String, at wt: URL) -> Probe<Int> {
        let (status, out) = runChecked(["-C", wt.path, "rev-list", "--count", "\(base)..HEAD"],
                                       timeout: probeTimeout)
        guard status == 0, let n = Int(out.trimmingCharacters(in: .whitespacesAndNewlines)) else { return .unknown }
        return .known(n)
    }

    /// The first of `candidates` this worktree can actually resolve to a commit, else nil.
    ///
    /// Each candidate is tried on the remote first: a PR's `baseRefName` is a bare branch name
    /// ("main") naming a branch on GitHub, and the local branch of the same name is whatever
    /// was last pulled — often many commits behind, which would inflate the ahead count. A name
    /// that only exists locally still resolves on the second try, and an already-qualified
    /// "origin/main" simply fails "origin/origin/main" and falls through to itself.
    static func resolvableRef(_ candidates: [String], at wt: URL) -> String? {
        for candidate in candidates where !candidate.isEmpty {
            for ref in ["origin/\(candidate)", candidate] where resolvesToCommit(ref, at: wt) {
                return ref
            }
        }
        return nil
    }

    private static func resolvesToCommit(_ ref: String, at wt: URL) -> Bool {
        runChecked(["-C", wt.path, "rev-parse", "--verify", "--quiet", "\(ref)^{commit}"],
                   timeout: probeTimeout).status == 0
    }

    /// `defaultBase` with the network step removed: origin/HEAD's symref when it is already
    /// set, else a local main/master, else nil.
    ///
    /// `defaultBase` falls back to `git remote set-head -a`, which talks to the remote on a
    /// `runChecked` with no timeout — right on the create path, where the user asked for a
    /// branch and one round-trip buys the correct base. Wrong on a hover path: hovering is
    /// involuntary, and a repo whose origin/HEAD was never set is exactly the repo where that
    /// call would block a pool thread until the network answers. Nil rather than a guessed
    /// "main" — a card that names the wrong base is worse than a card with no second half.
    static func localDefaultBase(at wt: URL) -> String? {
        if let ref = originHead(at: wt) { return ref }
        for name in ["main", "master"] where localBranchExists(name, at: wt) { return name }
        return nil
    }

    /// This worktree's own git dir (`<repo>/.git/worktrees/<name>`), not the common dir.
    static func gitDir(at wt: URL) -> URL? {
        let (status, out) = runChecked(["-C", wt.path, "rev-parse", "--path-format=absolute", "--git-dir"],
                                       timeout: probeTimeout)
        let path = out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard status == 0, !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

    private static let probeTimeout: TimeInterval = 10

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

    /// `timeout` nil means wait forever, which is right for the interactive paths — a
    /// checkout the user is watching should finish, not get cut off. The sweeper always
    /// passes one: it runs unattended on a repeating tick, and `readDataToEndOfFile` blocks
    /// a cooperative-pool thread until git exits, so one `status` against a hung network
    /// volume or a locked index would leak a thread per tick, forever. Killing the child
    /// closes the pipe, which is what unblocks the read.
    private static func runChecked(_ args: [String],
                                   timeout: TimeInterval? = nil) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            var killer: DispatchWorkItem?
            if let timeout {
                let item = DispatchWorkItem { if process.isRunning { process.terminate() } }
                killer = item
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: item)
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            killer?.cancel()
            return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
        } catch {
            return (-1, "\(error.localizedDescription)")
        }
    }
}
