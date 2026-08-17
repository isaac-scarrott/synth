import Foundation
import os

/// Decides whether an archived worktree's folder may be reclaimed, and does the reclaiming.
///
/// The invariant every condition below refines, and the one thing to check a *new* condition
/// against: **every byte in this folder is reconstructible from a remote or from the repo's
/// shared object store, without the user doing anything clever.**
///
/// This is not a daemon. It runs in-process, only inside a live Synth, on an opportunistic
/// tick. There is no launchd job and no `NSBackgroundActivityScheduler`, deliberately — a
/// headless process deleting a user's folders with no UI attached is a different product, and
/// "clean up even when Synth is shut" should have to argue for itself from scratch.
///
/// Its terminal act is a rename, never an `rm`. `GitService.holdWorktree` moves the folder
/// aside with a timestamp in its name, and `GitService.reapHeldWorktrees` — which consults no
/// policy at all, only that timestamp — deletes it two weeks later. So no bug in any predicate
/// here can reach an irreversible act.
enum ArchiveSweeper {
    static let log = Logger(subsystem: "io.github.isaac-scarrott.synth", category: "sweeper")

    /// How long a held `.archived-…` folder survives before the reaper deletes it for real.
    /// This, not the grace, is the recovery window that matters.
    static var holdSeconds: TimeInterval {
        if let raw = ProcessInfo.processInfo.environment["SYNTH_ARCHIVE_HOLD_SECONDS"],
           let secs = TimeInterval(raw) { return secs }
        return 14 * 86_400
    }

    /// Two clean readings this far apart before anything is touched. A transient — mid-rebase,
    /// briefly offline, a checkout in flight — can produce one clean reading; it can't produce
    /// two a day apart. Also means a cold launch never sweeps on day one.
    static var secondOpinionGap: TimeInterval {
        if let raw = ProcessInfo.processInfo.environment["SYNTH_ARCHIVE_EVAL_GAP_SECONDS"],
           let secs = TimeInterval(raw) { return secs }
        return 86_400
    }

    /// At most this many folders held per tick, and per launch. Turns the worst case from
    /// "lost twenty worktrees" into "lost three, saw the card, turned it off".
    static let perTickCap = 3
    static let perLaunchCap = 10
    /// More than this many eligible at once and the sweeper does nothing, raising a card
    /// instead. Bulk unattended deletion after a long absence is where a human belongs.
    /// Overridable like the clocks above, so the card it raises is reachable in a test without
    /// a fixture that builds six disposable worktrees.
    static var bulkBrake: Int {
        if let raw = ProcessInfo.processInfo.environment["SYNTH_ARCHIVE_BULK_BRAKE"],
           let n = Int(raw) { return n }
        return 5
    }

    // MARK: Verdict

    enum Block: String {
        case notManaged, primaryCheckout, uncommitted, untracked, unpushed, noRemote
        case inProgress, detached, locked, nested, precious, submodules, sessions
        case processCwd, otherInstance, symlink, prUnknown, prOpen, prClosed, noPR
        case postMerge, probeFailed, secondOpinion

        /// The ⌘K ctx line. Every one of these ends "— kept", because the list exists to answer
        /// "why is this still here" without the user having to guess.
        var line: String {
            switch self {
            case .notManaged:      return "not a worktree Synth created — kept"
            case .primaryCheckout: return "the project's own checkout — kept"
            case .uncommitted:     return "uncommitted changes — kept"
            case .untracked:       return "untracked files — kept"
            case .unpushed:        return "commits not pushed anywhere — kept"
            case .noRemote:        return "no remote to recover from — kept"
            case .inProgress:      return "a git operation is half-finished — kept"
            case .detached:        return "detached HEAD — kept"
            case .locked:          return "the worktree is locked — kept"
            case .nested:          return "another worktree lives inside it — kept"
            case .precious:        return "local-only config inside — kept"
            case .submodules:      return "submodule changes — kept"
            case .sessions:        return "sessions still attached — kept"
            case .processCwd:      return "something is running in it — kept"
            case .otherInstance:   return "another Synth manages it — kept"
            case .symlink:         return "reached through a symlink — kept"
            case .prUnknown:       return "can't reach GitHub — kept"
            case .prOpen:          return "PR still open — kept"
            case .prClosed:        return "PR closed, not merged — kept"
            case .noPR:            return "never merged — kept"
            case .postMerge:       return "commits made after the merge — kept"
            case .probeFailed:     return "couldn't check — kept"
            case .secondOpinion:   return "checking…"
            }
        }

        /// The same reason on a chip, which sits on the row it is about: `line` minus its
        /// "— kept", because a row that is plainly still there has already said that word.
        var chip: String {
            let kept = " — kept"
            return line.hasSuffix(kept) ? String(line.dropLast(kept.count)) : line
        }
    }

    enum Verdict {
        /// Grace hasn't elapsed. `daysLeft` is what the ⌘K row counts down.
        case waiting(daysLeft: Int)
        case blocked(Block)
        /// Clean on everything, and this is the first clean reading — one more, a day from
        /// now, before anything moves.
        case needsSecondOpinion
        case eligible(mergedPR: Int?)

        var block: Block? { if case .blocked(let b) = self { return b }; return nil }

        /// Why this folder is still on disk, for the chip on its Archived row.
        var chip: String? {
            switch self {
            case .waiting(let days):   return Verdict.countdown(days)
            case .blocked(let b):      return b.chip
            case .needsSecondOpinion:  return Block.secondOpinion.chip
            case .eligible:            return "held aside next sweep"
            }
        }

        /// The same for ⌘K, where the reason is flat text with no row under it to carry the
        /// "kept" the chip can leave out.
        var line: String? {
            switch self {
            case .waiting(let days):   return Verdict.countdown(days)
            case .blocked(let b):      return b.line
            case .needsSecondOpinion:  return Block.secondOpinion.line
            case .eligible:            return "held aside next sweep"
            }
        }

        private static func countdown(_ days: Int) -> String {
            "\(days) day\(days == 1 ? "" : "s") left"
        }
    }

    // MARK: Disk budget

    /// One archived folder as the budget sees it: when it was put away, what it costs, and
    /// whether anything is currently holding it.
    struct BudgetEntry {
        let id: UUID
        let archivedAt: Date
        /// Unmeasured folders arrive as 0 — a size nobody has walked yet must not be what
        /// pushes the archive over its cap.
        let bytes: Int64
        let blocked: Bool
    }

    /// The oldest unblocked entries the caps have called early, as a set: enough of them to
    /// bring the archive back under both. `maxCount` / `maxBytes` of 0 is no cap.
    ///
    /// Blocked entries still count toward the budget — they are occupying the disk — they just
    /// can't pay it down, so the loop skips over them and keeps looking. That asymmetry is the
    /// whole design: being called early only expires a folder's *grace*, and it still has to
    /// clear every gate in `evaluate` afterwards. A cap that evicted the oldest folder
    /// regardless would be a hole straight through this file's invariant, so an over-budget
    /// archive full of unpushed work stays over budget and says so.
    static func overBudget(_ entries: [BudgetEntry], maxCount: Int, maxBytes: Int64) -> Set<UUID> {
        var called: Set<UUID> = []
        var count = entries.count
        var bytes = entries.reduce(0) { $0 + $1.bytes }
        for entry in entries.sorted(by: { $0.archivedAt < $1.archivedAt }) {
            if (maxCount == 0 || count <= maxCount) && (maxBytes == 0 || bytes <= maxBytes) { break }
            if entry.blocked { continue }
            called.insert(entry.id)
            count -= 1
            bytes -= entry.bytes
        }
        return called
    }

    /// Everything one candidate's evaluation needs, snapshotted on the main actor so the
    /// evaluation itself can run detached. Sendable by construction — no model objects.
    struct Candidate: Sendable {
        let branchID: UUID
        let name: String
        let repo: URL
        let worktree: URL
        let archivedAt: Date
        let lastCleanEval: Date?
        let hasSessions: Bool
        /// Worktree paths registered by *other* live Synth instances. Two sweepers racing a
        /// prune on one repo is corruption, and `runGit`'s serialisation is per-process.
        let foreignInstancePaths: Set<String>
    }

    // MARK: Evaluation

    /// Blocking. Runs one candidate's full evidence pass. Never call from the main actor.
    ///
    /// `cwdPaths` is one system-wide `lsof` shared across the tick — nil means the probe
    /// itself failed, which blocks rather than passes.
    static func evaluate(_ c: Candidate, graceSeconds: TimeInterval,
                         cwdPaths: Set<String>?, now: Date = Date()) -> Verdict {
        // Grace, on the wall clock. A backwards clock (NTP correction, timezone travel) must
        // never manufacture an expired grace — the store rewrites `archivedAt` in that case.
        let elapsed = now.timeIntervalSince(c.archivedAt)
        guard elapsed >= graceSeconds else {
            return .waiting(daysLeft: max(1, Int(((graceSeconds - elapsed) / 86_400).rounded(.up))))
        }

        // B0/B16/B1 — cheapest gates first, and the highest-value one is B0: anything Synth
        // didn't create under its own worktree root is out, which kills hand-made worktrees
        // Synth merely adopted, `.worktree/…` scratch trees and agent worktrees in one line.
        let resolved = c.worktree.resolvingSymlinksInPath().standardized
        guard resolved.path == c.worktree.standardized.path else { return .blocked(.symlink) }
        guard resolved.deletingLastPathComponent().standardized.path
                == GitService.worktreeRoot(for: c.repo).resolvingSymlinksInPath().standardized.path
        else { return .blocked(.notManaged) }
        guard resolved.path != c.repo.resolvingSymlinksInPath().standardized.path else {
            return .blocked(.primaryCheckout)
        }
        guard !c.hasSessions else { return .blocked(.sessions) }
        guard !c.foreignInstancePaths.contains(resolved.path) else { return .blocked(.otherInstance) }
        guard !GitService.hasIndexLock(at: c.worktree) else { return .blocked(.probeFailed) }

        // B14 — a process whose cwd is inside the folder. macOS cwd follows the inode, so the
        // rename doesn't stop it; it just makes its cwd invisible. A failed lsof is not a pass.
        guard let cwdPaths else { return .blocked(.probeFailed) }
        if cwdPaths.contains(where: { $0 == resolved.path || $0.hasPrefix(resolved.path + "/") }) {
            return .blocked(.processCwd)
        }

        // B8/B7/B9 — one `worktree list` answers locked, detached, and nesting.
        let all = GitService.worktrees(at: c.repo)
        guard let mine = all.first(where: {
            $0.path.resolvingSymlinksInPath().standardized.path == resolved.path
        }) else { return .blocked(.probeFailed) }
        guard !mine.isLocked else { return .blocked(.locked) }
        guard mine.branch != nil else { return .blocked(.detached) }
        let nestedWorktree = all.contains {
            $0.path.standardized.path.hasPrefix(resolved.path + "/")
        }
        guard !nestedWorktree, !hasNestedRepo(under: resolved) else { return .blocked(.nested) }

        // B5 — no remote means nothing is recoverable, so B4 would block everything anyway.
        // Say it as its own answer rather than as a confusing "not pushed".
        guard let remotes = GitService.remotes(at: c.repo).value else { return .blocked(.probeFailed) }
        guard !remotes.isEmpty else { return .blocked(.noRemote) }

        // B2/B3 — the measured loss case is B3, not B2: `git diff --quiet HEAD` reports clean
        // for a tree holding untracked source that exists in no commit and on no remote.
        guard let clean = GitService.cleanliness(at: c.worktree).value else { return .blocked(.probeFailed) }
        guard clean.tracked.isEmpty else { return .blocked(.uncommitted) }
        guard clean.untracked.isEmpty else { return .blocked(.untracked) }

        // B6 — a half-finished rebase leaves a clean worktree with unreplayed patches.
        guard let op = GitService.inProgressOperation(at: c.worktree).value else { return .blocked(.probeFailed) }
        guard op == nil else { return .blocked(.inProgress) }

        // B11
        guard let dirtySubs = GitService.hasDirtySubmodules(at: c.worktree).value else {
            return .blocked(.probeFailed)
        }
        guard !dirtySubs else { return .blocked(.submodules) }

        // B10 — precious ignored files, but only the ones that aren't reconstructible. This
        // repo's own worktree-create copies gitignored `.env` files in from the parent; a copy
        // that still byte-matches its source *is* reconstructible, and blocking on it would
        // make the sweeper permanently inert on every project that has a `.env`.
        guard let precious = GitService.preciousIgnored(at: c.worktree).value else {
            return .blocked(.probeFailed)
        }
        if precious.contains(where: { !matchesParent($0, worktree: c.worktree, repo: c.repo) }) {
            return .blocked(.precious)
        }

        // B4 — the load-bearing one. Commits reachable from no remote ref.
        guard let unpushed = GitService.commitsOnNoRemote(at: c.worktree).value else {
            return .blocked(.probeFailed)
        }
        guard unpushed == 0 else { return .blocked(.unpushed) }

        // Everything above answers "is the work recoverable". What follows answers the
        // separate question "is the folder still wanted" — and conflating the two is what made
        // the original "no open PR" condition unsafe.
        let verdict = relevance(c)
        if case .blocked = verdict { return verdict }

        // The second-opinion rule, last, so a candidate that fails anything above never banks a
        // clean reading it didn't earn.
        if let last = c.lastCleanEval, now.timeIntervalSince(last) >= secondOpinionGap {
            if case .eligible = verdict { return verdict }
        }
        return .needsSecondOpinion
    }

    /// Is this folder still wanted? Satisfied by an affirmative merged PR, or — for repos with
    /// no GitHub at all — by the branch already being an ancestor of the default branch.
    ///
    /// Note what is *not* accepted: "no PR" and "PR closed". A closed-unmerged PR means a human
    /// rejected or abandoned the work, which is the strongest possible reason to keep the
    /// folder, and "no PR at all" describes every parked spike branch — the exact case Archive
    /// exists to serve.
    private static func relevance(_ c: Candidate) -> Verdict {
        // The offline path first: it needs no `gh`, no auth, and no GitHub remote, so a repo
        // hosted anywhere else is not silently inert forever.
        //
        // Resolve the default branch rather than naming `origin/HEAD` outright. That ref is
        // absent more often than you'd think — a bare remote whose own HEAD was never set, a
        // remote added by hand — and a missing ref makes `merge-base` exit 128, which reads as
        // "couldn't tell" and drops every repo without it onto the `gh` path forever.
        // `defaultBase` is the same resolution the create path uses: origin/HEAD, else ask the
        // remote once, else local main/master.
        let base = GitService.defaultBase(at: c.repo)
        if base != "HEAD", case .known(true) = GitService.isAncestor("HEAD", of: base, at: c.worktree) {
            return .eligible(mergedPR: nil)
        }

        // Per-candidate, never the bulk map: `gh pr list --limit 100` silently drops a branch's
        // PR off the tail on a busy repo, and that reads exactly like "this branch has no PR".
        guard let asked = PRService.pullRequest(head: c.name, at: c.repo) else {
            return .blocked(.prUnknown)   // couldn't ask ≠ nothing to find
        }
        guard let pr = asked else { return .blocked(.noPR) }
        switch pr.state {
        case .open, .queued: return .blocked(.prOpen)
        case .closed:        return .blocked(.prClosed)
        case .merged:        break
        }
        // B20 — you merge, then commit more on the same branch; `gh` still says MERGED.
        if !pr.baseRefName.isEmpty {
            guard case .known(true) = GitService.isAncestor("HEAD", of: "origin/\(pr.baseRefName)",
                                                           at: c.worktree)
            else { return .blocked(.postMerge) }
        }
        return .eligible(mergedPR: pr.number)
    }

    /// True when the worktree's copy of an ignored file is identical to the parent repo's — a
    /// copy, not an original, and so reconstructible.
    private static func matchesParent(_ relative: String, worktree: URL, repo: URL) -> Bool {
        let mine = worktree.appendingPathComponent(relative)
        let theirs = repo.appendingPathComponent(relative)
        guard let a = try? Data(contentsOf: mine), let b = try? Data(contentsOf: theirs) else {
            return false
        }
        return a == b
    }

    /// A `.git` anywhere shallowly inside the folder — a nested clone or worktree whose commits
    /// an `rm -rf` of the parent would take with it.
    private static func hasNestedRepo(under root: URL) -> Bool {
        let fm = FileManager.default
        func scan(_ dir: URL, depth: Int) -> Bool {
            guard depth <= 4,
                  let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey])
            else { return false }
            for entry in entries {
                let name = entry.lastPathComponent
                if depth > 0, name == ".git" { return true }
                guard name != ".git", name != "node_modules",
                      (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                else { continue }
                if scan(entry, depth: depth + 1) { return true }
            }
            return false
        }
        return scan(root, depth: 0)
    }

    /// The cheap, fast-moving gates, re-read immediately before the rename inside the same
    /// serialised git chain. Everything in `evaluate` was a snapshot, and an agent may have
    /// written a file in the seconds since.
    ///
    /// This MUST agree with `evaluate` about what "clean" means — when it didn't, every
    /// candidate passed evaluation and then silently failed here, which presents as a sweeper
    /// that decides to act and then never does.
    static func isSettled(at worktree: URL) -> Bool {
        guard case .known(let clean) = GitService.cleanliness(at: worktree),
              clean.tracked.isEmpty,
              clean.untracked.isEmpty,
              !GitService.hasIndexLock(at: worktree)
        else { return false }
        return true
    }

    // MARK: lsof

    /// Every process cwd on the machine, in one pass. `lsof +D` would stat every file under
    /// each candidate — on a multi-GB tree that is the whole tick's budget — so this asks for
    /// cwd descriptors only and prefix-matches in memory.
    ///
    /// nil when `lsof` couldn't be trusted: a non-zero exit is indistinguishable from "nothing
    /// found" by content, and TCC or another user's processes can truncate it silently.
    static func processWorkingDirectories() -> Set<String>? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-w", "-n", "-d", "cwd", "-F", "n"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            // lsof exits 1 when *some* files couldn't be listed, which is normal for a
            // non-root run over other users' processes — but the paths it did print are still
            // real. Only a total failure (no output at all) is untrustworthy.
            let out = String(data: data, encoding: .utf8) ?? ""
            guard !out.isEmpty else { return nil }
            var paths: Set<String> = []
            for line in out.split(separator: "\n") where line.hasPrefix("n/") {
                paths.insert(String(line.dropFirst()))
            }
            return paths
        } catch {
            return nil
        }
    }
}
