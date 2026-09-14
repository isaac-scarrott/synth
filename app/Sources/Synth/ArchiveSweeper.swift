import Foundation
import os

/// When an archived worktree's folder goes. Archived is the whole decision: the user (or the
/// finished-row pass, for a merged branch) put the row away, and the folder is deleted once
/// the wait has run, or sooner when the archive is over its count or disk cap. Nothing about
/// the folder's contents is consulted — the branch is a git ref and the checkout is derived
/// from it, so a restore after the folder has gone cuts it again (`AppStore.restoreArchivedBranch`).
///
/// This is not a daemon. It runs in-process, only inside a live Synth, on an opportunistic
/// tick. There is no launchd job and no `NSBackgroundActivityScheduler`, deliberately — a
/// headless process deleting a user's folders with no UI attached is a different product.
enum ArchiveSweeper {
    static let log = Logger(subsystem: "io.github.isaac-scarrott.synth", category: "sweeper")

    /// One archived folder as the policy sees it: when it was put away and what it costs.
    struct Entry {
        let id: UUID
        let archivedAt: Date
        /// Unmeasured folders arrive as 0 — a size nobody has walked yet must not be what
        /// pushes the archive over its cap.
        let bytes: Int64
    }

    /// Every folder whose wait has run, plus — while the archive is still over either cap —
    /// the oldest of the rest until it is under both. `maxCount` / `maxBytes` of 0 is no cap.
    static func due(_ entries: [Entry], graceSeconds: TimeInterval,
                    maxCount: Int, maxBytes: Int64, now: Date = Date()) -> Set<UUID> {
        var due: Set<UUID> = []
        var count = entries.count
        var bytes = entries.reduce(0) { $0 + $1.bytes }
        for entry in entries.sorted(by: { $0.archivedAt < $1.archivedAt }) {
            let overCap = (maxCount > 0 && count > maxCount) || (maxBytes > 0 && bytes > maxBytes)
            guard overCap || now.timeIntervalSince(entry.archivedAt) >= graceSeconds else { continue }
            due.insert(entry.id)
            count -= 1
            bytes -= entry.bytes
        }
        return due
    }

    /// "6 days left", or "next clean-up" once it is due. What the Archived row and its ⌘K line say.
    static func countdown(archivedAt: Date, graceSeconds: TimeInterval, due: Bool, now: Date = Date()) -> String {
        let left = graceSeconds - now.timeIntervalSince(archivedAt)
        guard !due, left > 0 else { return "next clean-up" }
        let days = max(1, Int((left / 86_400).rounded(.up)))
        return "\(days) day\(days == 1 ? "" : "s") left"
    }

    // MARK: Branch refs

    /// At most this many folder-less rows examined per tick. Every archived row that still has
    /// a folder is rejected by a stat with no git at all, so a settled archive costs the pass
    /// nothing; a backlog drains a capped number of git chains per tick instead of hundreds.
    static let retireCap = 20

    /// Everything one row's ending needs, snapshotted on the main actor so the git chain can
    /// run detached. Sendable by construction — no model objects.
    struct Candidate: Sendable {
        let branchID: UUID
        let name: String
        let repo: URL
        let worktree: URL
        let hasSessions: Bool
    }

    /// How an archived row ends, once its folder is gone. A restore re-cuts the checkout from
    /// the branch, so the ref is what keeps the Archived list honest: when it goes, the row
    /// goes with it rather than sitting there as an entry that can no longer be restored.
    enum BranchEnd {
        /// Still wanted, or not answerable — the row stays exactly as it is.
        case keep
        /// Merged, and the remote has already dropped it: delete the ref, drop the row.
        case retire
        /// The ref is already gone — deleted by hand, or by another tool. Nothing to delete;
        /// the row is a pointer to nothing and is dropped on its own.
        case orphaned
    }

    /// The gate that carries the weight is the remote one. A merged branch the remote still
    /// lists is a branch somebody is keeping; a merged branch the remote has *dropped* was
    /// cleaned up when its PR landed, and every commit on it is reachable from the default
    /// branch. Blocking. Never call from the main actor.
    static func branchEnd(_ c: Candidate) -> BranchEnd {
        guard !c.hasSessions else { return .keep }
        // Nothing on disk, and nothing git thinks is on disk. The check is "does git name this
        // branch in a worktree", not "is the path listed" — a registration can outlive its
        // folder for the moment between a delete and its prune.
        guard !FileManager.default.fileExists(atPath: c.worktree.standardized.path) else { return .keep }
        guard !GitService.worktrees(at: c.repo).contains(where: { $0.branch == c.name }) else {
            return .keep
        }
        guard GitService.branchExists(c.name, at: c.repo) else { return .orphaned }
        let base = GitService.defaultBase(at: c.repo)
        guard base != "HEAD", c.name != base,
              case .known(true) = GitService.isAncestor(c.name, of: base, at: c.repo)
        else { return .keep }
        guard case .known(false) = GitService.remoteHasBranch(c.name, at: c.repo) else { return .keep }
        return .retire
    }
}
