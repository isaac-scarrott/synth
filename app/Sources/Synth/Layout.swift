import Foundation
import CoreGraphics
import Observation

/// A split's axis: `row` lays children side by side, `col` stacks them (working.html dir).
enum SplitDir: String, Codable, Sendable { case row, col }

/// The layout spine (009): a branch's content surface is a **binary pane tree**. A node is either
/// a LEAF binding exactly one session — or a still-materialising branch's setup skeleton, which
/// counts as bound, so there is never an empty pane (ADR §2) — or a SPLIT of two children divided
/// along `dir`, where child `a` holds `split` of the space. The single-pane case is a one-leaf
/// tree, so today's behaviour is the degenerate case. Mirrors working.html's `layout` node shape.
///
/// Reference type + `@Observable`: tree ops mutate nodes **in place** (so a subdivided leaf keeps
/// its identity and parent links, like the mock's `splitPane`), and each pane view observes its
/// own leaf so a fraction change or reparent re-renders without tearing down live sibling surfaces.
@MainActor @Observable final class PaneNode: Identifiable {
    let id = UUID()
    // Leaf payload — exactly one is non-nil on a leaf; both nil on a split.
    var sessionID: UUID?
    var setupBranchID: UUID?
    // Split payload — a non-nil `dir` marks a split.
    var dir: SplitDir?
    var split: Double = 0.5   // child a's fraction of the axis
    var a: PaneNode?
    var b: PaneNode?

    var isLeaf: Bool { dir == nil }

    init(leafSession id: UUID) { self.sessionID = id }
    init(leafSetup branchID: UUID) { self.setupBranchID = branchID }
    init(dir: SplitDir, split: Double, a: PaneNode, b: PaneNode) {
        self.dir = dir; self.split = split; self.a = a; self.b = b
    }
}

// MARK: - The pane tree lives in the store (ADR-0003: the layout is observable state)

extension AppStore {
    /// Min-pane floor (004 §3): a hard stop for both drops and resizes. A drop or resize that would
    /// breach it is refused. Carried here on the spine; the gesture/resize slices clamp against it.
    static let paneMinW: CGFloat = 360
    static let paneMinH: CGFloat = 240

    // MARK: Tree walking

    func eachLeaf(_ node: PaneNode?, _ fn: (PaneNode) -> Void) {
        guard let node else { return }
        if node.isLeaf { fn(node) } else { eachLeaf(node.a, fn); eachLeaf(node.b, fn) }
    }

    func firstLeaf(_ node: PaneNode) -> PaneNode { node.isLeaf ? node : firstLeaf(node.a!) }

    /// The leaf binding `sessionID` in the on-screen layout, if any.
    func leaf(of sessionID: UUID) -> PaneNode? {
        var hit: PaneNode?
        eachLeaf(layout) { if $0.sessionID == sessionID { hit = $0 } }
        return hit
    }

    /// Is the whole layout an on-screen (≥2-pane) split? A lone leaf is the degenerate case.
    var isSplit: Bool { if let l = layout, !l.isLeaf { return true } else { return false } }

    /// Is this session a member of an on-screen split — i.e. is there something to unsplit it out of?
    func inSplit(_ sessionID: UUID) -> Bool { isSplit && leaf(of: sessionID) != nil }

    /// The session-bound leaves in reading order (the tree flattened a-before-b) — what ⌘1…9 and
    /// cycle walk, and the sidebar echo mirrors.
    var paneLeaves: [PaneNode] {
        var out: [PaneNode] = []
        eachLeaf(layout) { if $0.sessionID != nil { out.append($0) } }
        return out
    }

    /// The branch with this id, if it still exists (setup-leaf resolution + persistence restore).
    func branch(id: UUID) -> Branch? {
        for ws in workspaces {
            if let br = ws.branches.first(where: { $0.id == id }) { return br }
        }
        return nil
    }

    // MARK: Active pane + the openEl mirror

    /// Move the active pane and mirror it into the sidebar "you are here" state — the DOM-cheap
    /// half of activation (working.html setActivePane), no content teardown, so clicking between
    /// panes never restarts a live surface.
    func setActivePane(_ leaf: PaneNode) {
        activePane = leaf
        syncActive()
    }

    /// Keep the single-session facts (`openSessionID` / `openSetupBranchID`) pointing at the active
    /// pane — working.html's `openEl` survives as the active pane's mirror, so every existing
    /// single-session subsystem (notifications, ⌘K context, header) keeps reading one "you are here".
    func syncActive() {
        if let leaf = activePane, let sid = leaf.sessionID {
            openSessionID = sid
            openSetupBranchID = nil
            session(sid)?.unread = false
            clearNotif(sid)
        } else if let leaf = activePane, let bid = leaf.setupBranchID {
            openSessionID = nil
            openSetupBranchID = bid
        } else {
            openSessionID = nil
            openSetupBranchID = nil
        }
    }

    // MARK: Tree ops (the whole vocabulary — every gesture and chord funnels through these)

    /// Drop leaves whose session / setup branch no longer resolves and collapse the split above
    /// each — the surviving sibling reflows into the freed space (001). Re-seats `activePane` if it
    /// was pruned. Returns true if it changed the tree.
    @discardableResult
    func pruneLayout() -> Bool {
        var changed = false
        func alive(_ n: PaneNode) -> Bool {
            if let sid = n.sessionID { return session(sid) != nil }
            if let bid = n.setupBranchID { return branch(id: bid) != nil }
            return false
        }
        func walk(_ n: PaneNode?) -> PaneNode? {
            guard let n else { return nil }
            if n.isLeaf { if alive(n) { return n }; changed = true; return nil }
            let a = walk(n.a), b = walk(n.b)
            if let a, let b { n.a = a; n.b = b; return n }
            return a ?? b   // collapse: the survivor takes the split's place
        }
        layout = walk(layout)
        guard let root = layout else { activePane = nil; return changed }
        var ok = false
        eachLeaf(root) { if $0 === activePane { ok = true } }
        if !ok { activePane = firstLeaf(root) }
        return changed
    }

    /// Subdivide a leaf: it becomes a binary split of itself + a new pane bound to `session`, which
    /// lands active. Mutated in place so parent links survive — the only way a split is born; the
    /// gesture (010) and chord (007) layers drive it. `before` puts the incoming pane in slot a.
    func splitPane(_ target: PaneNode, session sessionID: UUID, dir: SplitDir, before: Bool) {
        guard target.isLeaf else { return }
        stashedSplit = nil   // deliberately building a split commits the current view as durable (014)
        let incoming = PaneNode(leafSession: sessionID)
        let kept: PaneNode = target.sessionID.map { PaneNode(leafSession: $0) }
            ?? PaneNode(leafSetup: target.setupBranchID ?? UUID())
        target.sessionID = nil
        target.setupBranchID = nil
        target.dir = dir
        target.split = 0.5
        target.a = before ? incoming : kept
        target.b = before ? kept : incoming
        activePane = incoming
        renderLayout()
    }

    /// Split the whole surface: the entire current tree becomes one child of a fresh root split,
    /// the incoming session the other. Rim-drop (010) drives this; `splitPane` handles per-pane edges.
    func splitRoot(session sessionID: UUID, dir: SplitDir, before: Bool) {
        guard let root = layout else { return }
        stashedSplit = nil
        let incoming = PaneNode(leafSession: sessionID)
        layout = PaneNode(dir: dir, split: 0.5,
                          a: before ? incoming : root, b: before ? root : incoming)
        activePane = incoming
        renderLayout()
    }

    /// Detach one leaf and collapse the split above it — the surviving sibling reflows into the
    /// freed space (001). Used to MOVE a session between panes on drop (010); unsplit/close is 013.
    func removeLeaf(_ target: PaneNode) {
        func walk(_ n: PaneNode?) -> PaneNode? {
            guard let n else { return nil }
            if n.isLeaf { return n === target ? nil : n }
            let a = walk(n.a), b = walk(n.b)
            if let a, let b { n.a = a; n.b = b; return n }
            return a ?? b
        }
        layout = walk(layout)
    }

    /// Unsplit (013): the flat route out of a split. Detach the session's leaf, collapse the split
    /// above it, and let the surviving sibling reflow (001). Focus falls to the survivor. Same tree
    /// op as a close, minus killing the session.
    func unsplitSession(_ sessionID: UUID) {
        guard inSplit(sessionID), let leaf = leaf(of: sessionID) else { return }
        removeLeaf(leaf)
        if let root = layout {
            var ok = false
            eachLeaf(root) { if $0 === activePane { ok = true } }
            if !ok { activePane = firstLeaf(root) }
        } else {
            activePane = nil
        }
        renderLayout()
    }

    /// The single choke point every mutation flows through (working.html renderLayout): prune dead
    /// leaves, re-seat the active pane, mirror it into the sidebar. The SwiftUI views observe the
    /// tree, so this needs no manual DOM rebuild — it just settles the model. Persistence (014)
    /// hangs off this later.
    func renderLayout() {
        pruneLayout()
        syncActive()
    }

    // MARK: Min-pane floor geometry (resize/drop slices clamp against this)

    /// The smallest length a subtree can hold along `axis` before some pane hits the 360×240 floor
    /// (001) — the rule the seam drag (011) and keyboard resize clamp against.
    func paneMinAlong(_ node: PaneNode, axis: SplitDir) -> CGFloat {
        if node.isLeaf { return axis == .row ? Self.paneMinW : Self.paneMinH }
        let a = paneMinAlong(node.a!, axis: axis)
        let b = paneMinAlong(node.b!, axis: axis)
        return node.dir == axis ? a + b : max(a, b)
    }
}
