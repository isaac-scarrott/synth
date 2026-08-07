import Foundation
import Observation

/// What a branch has done, as one line: `+412 −128 · 6 ahead of main`. The sidebar's branch
/// hover card is the only surface that asks — the row itself has no room for it, and a card
/// that opens on a worktree without saying how far it has diverged is showing the branch's
/// name back to the pointer already on it.
enum DiffStat {
    /// Blocking. Three to five `git` spawns. Never call this from the main actor —
    /// `DiffStatCache` exists so nothing has to.
    ///
    /// Nil for every way this can fail to be a question: no folder on disk, no repository, no
    /// base branch that resolves, or a base that resolves but leaves nothing worth saying.
    /// Silent in all of them, because a hover happens by accident.
    static func line(at worktree: URL, prBase: String?) -> String? {
        guard FileManager.default.fileExists(atPath: worktree.path) else { return nil }
        guard GitService.isRepository(worktree) else { return nil }
        guard let base = base(at: worktree, prBase: prBase) else { return nil }
        let counts = GitService.diffStat(against: base, at: worktree).value
        let ahead = GitService.commitsAhead(of: base, at: worktree).value
        return format(insertions: counts?.insertions ?? 0, deletions: counts?.deletions ?? 0,
                      ahead: ahead ?? 0, base: GitService.baseDisplayName(base))
    }

    /// The ref this branch is measured against, cheapest and most exact first: the PR's own
    /// base when GitHub has already told us (free, and the only answer that is certainly the
    /// branch this work merges into), then the repo's default branch read without touching the
    /// network (`localDefaultBase`).
    ///
    /// Nil when neither resolves. No hardcoded "main" fallback: a diffstat against the wrong
    /// base is not a smaller version of the truth, it is a different number wearing the right
    /// label, and the card would state it with the same confidence as a correct one.
    private static func base(at worktree: URL, prBase: String?) -> String? {
        if let prBase, let ref = GitService.resolvableRef([prBase], at: worktree) { return ref }
        guard let fallback = GitService.localDefaultBase(at: worktree) else { return nil }
        return GitService.resolvableRef([fallback], at: worktree)
    }

    /// working.html's card: `+412 −128 · 6 ahead of main`, either half dropped when it has
    /// nothing to report, nil when both do.
    ///
    /// U+2212 MINUS for the deletions, not a hyphen — the design's glyph, and the one that is
    /// the same width as the `+` it sits beside, so two rows of counts line up.
    static func format(insertions: Int, deletions: Int, ahead: Int, base: String) -> String? {
        var parts: [String] = []
        if insertions > 0 || deletions > 0 { parts.append("+\(insertions) −\(deletions)") }
        if ahead > 0 { parts.append("\(ahead) ahead of \(base)") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// Measured diffstat lines, per branch. The hover card reads it during layout and must never
/// block; the git spawns happen off the main actor and land here, and `@Observable` fills the
/// line in when they do.
///
/// Unlike `FolderSizeCache` this does re-measure. An archived folder's bytes are settled, but a
/// worktree's diff is the thing the user is actively changing — a line measured before a commit
/// and never refreshed is a wrong number the card keeps insisting on. `staleAfter` is the floor
/// that keeps that from meaning a git spawn per frame; re-measurement is lazy, driven by the
/// next `warm` past the floor, so a branch nobody hovers costs nothing and no timer exists to
/// wake the app up over a label.
@MainActor @Observable final class DiffStatCache {
    static let shared = DiffStatCache()

    private var lines: [Branch.ID: String] = [:]
    /// Not observed: a measurement starting is not a fact any view renders, and publishing it
    /// would invalidate the card twice per measurement.
    @ObservationIgnored private var inFlight: Set<Branch.ID> = []
    /// When each branch last finished measuring — the staleness floor's clock. Separate from
    /// `lines` because "measured, and there was nothing to say" is a result, and re-measuring
    /// it every frame is exactly what the floor is for.
    @ObservationIgnored private var measuredAt: [Branch.ID: Date] = [:]
    private static let staleAfter: TimeInterval = 30

    /// nil = not measured yet, or nothing worth saying. Callers render no line rather than a
    /// zero — a branch claiming `+0 −0` reads as a measurement, and it isn't one.
    func line(for branch: Branch) -> String? { lines[branch.id] }

    /// Measure anything unmeasured, stale, or not already in flight. Called from a SwiftUI body
    /// on every re-render, so the dedupe and the floor are the whole point: without them one
    /// hovered card would spawn a fresh `git diff` per frame.
    ///
    /// A pending branch is skipped — its worktree is still being created, so there is no
    /// checkout to diff and the answer would be a nil we'd re-ask for 30 seconds later anyway.
    func warm(_ branches: [Branch]) {
        let now = Date()
        for branch in branches where !branch.isPending && !inFlight.contains(branch.id) {
            if let at = measuredAt[branch.id], now.timeIntervalSince(at) < Self.staleAfter { continue }
            let id = branch.id
            // Read off the branch here, on the main actor: the detached task gets values, never
            // the `@Observable` model object.
            let worktree = branch.worktreeURL
            let prBase = branch.pr?.baseRefName
            inFlight.insert(id)
            Task.detached(priority: .utility) {
                let measured = DiffStat.line(at: worktree, prBase: prBase)
                await MainActor.run {
                    // nil clears the entry rather than leaving the last one: a branch whose work
                    // just merged away has no diff, and the line it used to have is now wrong.
                    self.lines[id] = measured
                    self.measuredAt[id] = Date()
                    self.inFlight.remove(id)
                }
            }
        }
    }
}
