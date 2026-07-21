import Foundation
import CoreGraphics
import Observation

/// A split's axis: `row` lays children side by side, `col` stacks them (working.html dir).
enum SplitDir: String, Codable, Sendable { case row, col }

/// A directional arrow chord — the shared vocabulary for keyboard focus / resize / create.
/// `axis` is the split axis the arrow acts along (left/right = row, up/down = col).
enum ArrowDir { case left, right, up, down
    var axis: SplitDir { (self == .left || self == .right) ? .row : .col }
    /// The side a create-toward-arrow puts the new pane on: left/up = before (slot a).
    var before: Bool { self == .left || self == .up }
}

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

    /// Is this session a member of a split there is something to unsplit it out of — the on-screen
    /// split for the current branch, or its branch's remembered layout otherwise (the sidebar band
    /// survives branch switches, 014).
    func inSplit(_ sessionID: UUID) -> Bool {
        if isSplit && leaf(of: sessionID) != nil { return true }
        guard let s = session(sessionID), let br = branch(of: s), br.id != currentBranchID,
              let tree = br.layout, !tree.isLeaf else { return false }
        return leafInTree(tree, session: sessionID) != nil
    }

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
            noteView(sid)
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

    // MARK: The view stack (016)

    /// Push a session onto the view stack — most recent last, one entry each.
    func noteView(_ sessionID: UUID) {
        viewStack.removeAll { $0 == sessionID }
        viewStack.append(sessionID)
    }

    /// The last session you were viewing that still exists, dropping dead ids as it goes — so a
    /// session closed from anywhere just falls out of the stack.
    func lastViewed() -> Session? {
        while let id = viewStack.last {
            if let s = session(id) { return s }
            viewStack.removeLast()
        }
        return nil
    }

    /// Called after a close: if it emptied the surface, pop the view stack and open the session you
    /// were on before this one — across a branch or workspace boundary if that's where it lives. A
    /// close inside a split never reaches here; the surviving sibling reflows into the space (001).
    func restoreLastViewed() {
        guard layout == nil, let back = lastViewed() else { return }
        open(back)
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
        layout = removing(target, from: layout)
    }

    /// `removeLeaf` over an arbitrary tree — returns what's left of `tree` without `target`.
    func removing(_ target: PaneNode, from tree: PaneNode?) -> PaneNode? {
        guard let tree else { return nil }
        if tree.isLeaf { return tree === target ? nil : tree }
        let a = removing(target, from: tree.a), b = removing(target, from: tree.b)
        if let a, let b { tree.a = a; tree.b = b; return tree }
        return a ?? b
    }

    /// Unsplit (013): the flat route out of a split, minus killing the session. **Focus carries
    /// across** — unsplitting the pane you're on keeps you on it (it becomes the standalone pane and
    /// the other members drop back to sidebar rows), rather than snapping focus to the survivor.
    /// Unsplitting some *other* session just detaches it and leaves the active pane where it is.
    func unsplitSession(_ sessionID: UUID) {
        if isSplit, let target = leaf(of: sessionID) {
            if activePane === target {
                // Solo the focused session — you keep viewing what you unsplit.
                layout = PaneNode(leafSession: sessionID)
                activePane = layout
            } else {
                removeLeaf(target)
                if let root = layout {
                    var ok = false
                    eachLeaf(root) { if $0 === activePane { ok = true } }
                    if !ok { activePane = firstLeaf(root) }
                } else {
                    activePane = nil
                }
            }
            renderLayout()
            return
        }
        // A member of a background branch's remembered split (its sidebar band survives branch
        // switches, 014): detach the leaf and collapse in place — the band updates without
        // touching the on-screen surface; the autosave persists it.
        guard let s = session(sessionID), let br = branch(of: s), br.id != currentBranchID,
              let tree = br.layout, !tree.isLeaf,
              let target = leafInTree(tree, session: sessionID) else { return }
        br.layout = removing(target, from: tree)
    }

    /// The single choke point every mutation flows through (working.html renderLayout): prune dead
    /// leaves, re-seat the active pane, mirror it into the sidebar. The SwiftUI views observe the
    /// tree, so this needs no manual DOM rebuild — it just settles the model. Persistence (014)
    /// hangs off this later.
    func renderLayout() {
        pruneLayout()
        syncActive()
        syncBranchLayout()   // 014: keep the branch's remembered layout in step (autosave persists it)
    }

    // MARK: Keyboard split layer (007) — chords over the same tree ops the mouse drives

    /// The leaf binding `sessionID` anywhere in `tree` (used to re-find a pane after a zoom stash).
    func leafInTree(_ tree: PaneNode?, session sessionID: UUID) -> PaneNode? {
        var hit: PaneNode?
        eachLeaf(tree) { if $0.sessionID == sessionID { hit = $0 } }
        return hit
    }

    /// ⌘1…⌘9 teleport to the Nth session pane in reading order (the tree flattened a-before-b).
    func focusPane(_ n: Int) {
        let ls = paneLeaves
        guard n >= 1, n <= ls.count else { return }
        setActivePane(ls[n - 1])
    }

    /// ⌘` / ⌘⇧` step to the next / previous pane, wrapping — direction-free "just move me on".
    func cyclePane(_ step: Int) {
        let ls = paneLeaves
        guard ls.count >= 2 else { return }
        let i = ls.firstIndex(where: { $0 === activePane }) ?? 0
        let n = ls.count
        setActivePane(ls[((i + step) % n + n) % n])
    }

    /// ⌘⌥+arrow / hjkl move focus spatially: the nearest pane whose edge lies past the active
    /// pane's edge in that direction, tie-broken by cross-axis centre distance. Reads the real
    /// on-screen geometry (paneFrames), so it follows the split however it's nested.
    func focusDir(_ d: ArrowDir) {
        guard let ap = activePane, let cur = paneFrames[ap.id] else { return }
        let cx = cur.midX, cy = cur.midY
        var best: PaneNode?
        var bestScore = CGFloat.infinity
        eachLeaf(layout) { l in
            guard l !== ap, l.sessionID != nil, let r = paneFrames[l.id] else { return }
            let ok: Bool
            let primary: CGFloat
            switch d {
            case .right: ok = r.minX >= cur.maxX - 1; primary = r.minX - cur.maxX
            case .left:  ok = r.maxX <= cur.minX + 1; primary = cur.minX - r.maxX
            case .down:  ok = r.minY >= cur.maxY - 1; primary = r.minY - cur.maxY
            case .up:    ok = r.maxY <= cur.minY + 1; primary = cur.minY - r.maxY
            }
            guard ok else { return }
            let cross = (d == .left || d == .right) ? abs(r.midY - cy) : abs(r.midX - cx)
            let score = max(0, primary) + cross * 2
            if score < bestScore { bestScore = score; best = l }
        }
        if let best { setActivePane(best) }
    }

    /// Path from the root to `target`, each hop tagged with whether the child taken was `a`.
    func pathToLeaf(_ target: PaneNode) -> [(node: PaneNode, isA: Bool)]? {
        var hit: [(node: PaneNode, isA: Bool)]?
        func walk(_ n: PaneNode?, _ trail: [(node: PaneNode, isA: Bool)]) {
            guard let n else { return }
            if n.isLeaf { if n === target { hit = trail }; return }
            walk(n.a, trail + [(n, true)])
            walk(n.b, trail + [(n, false)])
        }
        walk(layout, [])
        return hit
    }

    /// ⌘⌥⇧+arrow nudges the seam bordering the active pane along that axis — →/↓ grow it, ←/↑
    /// shrink it. Rewrites the nearest ancestor split's fraction in place (like the 011 drag), so
    /// live surfaces survive; the 360×240 floor is a hard stop, an over-subscribed split pins.
    func resizeActive(_ d: ArrowDir) {
        guard activePane != nil, isSplit else { return }
        let axis = d.axis
        guard let ap = activePane, let trail = pathToLeaf(ap) else { return }
        guard let hit = trail.last(where: { $0.node.dir == axis }) else { return }
        let node = hit.node
        guard let box = paneFrames[node.id] else { return }
        let total = Double(axis == .row ? box.width : box.height)
        guard total > 0 else { return }
        var lo = Double(paneMinAlong(node.a!, axis: axis)) / total
        var hi = 1 - Double(paneMinAlong(node.b!, axis: axis)) / total
        if lo > hi { let m = (lo + hi) / 2; lo = m; hi = m }
        let grow = (d == .right || d == .down)
        let sign: Double = hit.isA ? (grow ? 1 : -1) : (grow ? -1 : 1)
        node.split = min(hi, max(lo, node.split + sign * 0.06))
        persistLayout()
    }

    /// ⌘⇧⏎ zoom: a transient, tmux-style full-screen of the active pane over the remembered split
    /// (the same stashedSplit mechanism openSession uses, 014) — the split isn't destroyed and
    /// toggling restores it with the zoomed pane still focused.
    func toggleZoom() {
        guard let root = layout else { return }
        if let stash = stashedSplit {
            let back = activePane?.sessionID
            layout = stash
            stashedSplit = nil
            if let back, let leaf = leafInTree(layout, session: back) { activePane = leaf }
            else if let l = layout { activePane = firstLeaf(l) }
            renderLayout()
        } else if isSplit, let sid = activePane?.sessionID {
            stashedSplit = root
            layout = PaneNode(leafSession: sid)
            activePane = layout
            renderLayout()
        }
    }

    /// Every session across the tree — the split picker's "pull in an existing session" source.
    var allSessions: [Session] { workspaces.flatMap { $0.branches.flatMap(\.sessions) } }

    /// The remembered layout ignoring any transient full-screen — what the sidebar echoes, so the
    /// band stays put behind a zoom (014).
    var durableLayout: PaneNode? { stashedSplit ?? layout }

    /// The member sessions of `branch`'s split, in reading order (the tree flattened a-before-b) —
    /// the sidebar echo's source (012). The current branch reads the on-screen durable tree; any
    /// other branch its remembered Branch.layout, so a band survives switching branches /
    /// workspaces (014). Empty unless the tree binds ≥2 sessions.
    func echoMemberIDs(for branch: Branch) -> [UUID] {
        let tree = branch.id == currentBranchID ? durableLayout : branch.layout
        var ids: [UUID] = []
        eachLeaf(tree) { if let s = $0.sessionID { ids.append(s) } }
        return ids.count >= 2 ? ids : []
    }

    /// The branch a keyboard split lands on when the active pane is a bare setup skeleton (no
    /// session to read a branch off): the open session's branch, else the first available.
    func contextBranchForSplit() -> Branch? {
        if let s = openSession, let b = branch(of: s) { return b }
        return workspaces.first?.branches.first { !$0.isPending }
    }

    /// ⌘⇧+arrow / ⌘| / ⌘— open the pick-a-session frame that fills the new pane (007). No split
    /// from a bare setup skeleton — there's no live pane to subdivide yet.
    func openSplitPicker(dir: SplitDir, before: Bool) {
        guard let ap = activePane, ap.sessionID != nil else { return }
        activeMenu = nil
        if palette == nil { palette = PaletteModel(store: self) }
        guard let pal = palette else { return }
        pal.stack = [pal.rootFrame()]
        pal.push(pal.splitFrame(dir: dir, before: before))
    }

    /// Subdivide the active pane (or `target`) with `session`, moving it if it's already a pane
    /// (010's rule). The keyboard create chord and the sidebar-pair gesture both land here.
    func splitActiveWith(session sessionID: UUID, dir: SplitDir, before: Bool, target: PaneNode? = nil) {
        let t = target ?? activePane
        guard let t, t.isLeaf else { return }
        if let existing = leaf(of: sessionID), existing !== t { removeLeaf(existing) }
        splitPane(t, session: sessionID, dir: dir, before: before)
    }

    // MARK: Per-branch persistence & sticky nav (014)

    /// The branch whose layout is on screen — the sole persistence scope (005). nil for the
    /// transient, branchless setup skeleton.
    var currentBranch: Branch? { currentBranchID.flatMap { branch(id: $0) } }

    /// Keep the current branch's remembered layout in step with the on-screen *durable* tree, so a
    /// transient full-screen doesn't overwrite the split and the arrangement is there to serialize.
    /// The single choke point renderLayout / persistLayout flow through.
    func syncBranchLayout() {
        guard let cur = currentBranch else { return }
        let d = durableLayout
        if let d, d.isLeaf, d.setupBranchID != nil { return }   // a lone setup skeleton is transient
        cur.layout = d
    }

    /// Every layout mutation that rewrites geometry without a full renderLayout (seam drag, keyboard
    /// resize) still keeps the branch's remembered layout current; the 4s autosave persists it.
    func persistLayout() { syncBranchLayout() }

    /// Serialize a branch's durable layout to its on-disk shape, dropping leaves whose session no
    /// longer lives in the branch and collapsing the split above them (the missing-session reflow).
    func serializeLayout(_ node: PaneNode?, valid: Set<UUID>) -> PersistedPaneNode? {
        guard let node else { return nil }
        if node.isLeaf {
            guard let sid = node.sessionID, valid.contains(sid) else { return nil }
            return .leaf(session: sid)
        }
        let a = serializeLayout(node.a, valid: valid)
        let b = serializeLayout(node.b, valid: valid)
        if let a, let b { return .split(dir: (node.dir ?? .row).rawValue, split: node.split, a: a, b: b) }
        return a ?? b
    }

    /// Rebuild a branch's layout from disk, resolving each leaf's session against the branch's
    /// restored sessions (ids are stable across restart, ADR-0010). A leaf that no longer resolves
    /// collapses — e.g. a runtime browser session that didn't come back.
    func deserializeLayout(_ p: PersistedPaneNode?, valid: Set<UUID>) -> PaneNode? {
        guard let p else { return nil }
        switch p {
        case let .leaf(sid):
            return valid.contains(sid) ? PaneNode(leafSession: sid) : nil
        case let .split(dir, split, a, b):
            let la = deserializeLayout(a, valid: valid)
            let lb = deserializeLayout(b, valid: valid)
            if let la, let lb {
                return PaneNode(dir: SplitDir(rawValue: dir) ?? .row, split: split, a: la, b: lb)
            }
            return la ?? lb
        }
    }

    // MARK: Mouse drag-to-split (010) — pointer → drop zone → tree op

    /// A split stays within one branch / worktree (003): every pane in the on-screen layout is a
    /// session from the branch that owns the surface. Persistence already assumes this
    /// (serializeLayout keeps only the branch's own sessions), so a cross-worktree pane can't even
    /// survive a restart — the guard the split routes share to refuse one before it's built. A
    /// branchless setup skeleton (currentBranchID nil) owns no worktree, so nothing may join it.
    func sessionCanJoinLayout(_ sessionID: UUID) -> Bool {
        guard let cur = currentBranchID,
              let s = session(sessionID), let br = branch(of: s) else { return false }
        return br.id == cur
    }

    /// The region a drop will occupy + how it reads. `zone` is nil when refused (floor breach).
    /// Dragging a session into the content only ever *splits* — there is no replace/switch.
    struct DropResolution: Equatable {
        enum Kind { case split, rim, refuse }
        var rect: CGRect
        var kind: Kind
        var zone: DropZone?
    }
    enum DropZone: Equatable {
        case rim(ArrowDir)            // split the whole surface (outer rim)
        case edge(UUID, ArrowDir)     // split the hovered pane on that edge
    }

    private static let dropRimPx: CGFloat = 26      // outer band that reads as a whole-surface split

    /// Resolve a pointer in content coordinates to the zone a dropped session will land in
    /// (working.html computeDrop): rim → splitRoot, pane edge → splitPane, centre → replace. Any
    /// zone that would breach the 360×240 floor comes back `.refuse` (a no-op drop).
    func resolveDrop(at p: CGPoint, contentSize: CGSize, dragging sessionID: UUID) -> DropResolution {
        let full = CGRect(origin: .zero, size: contentSize)
        // A session from another branch / worktree never joins this surface (003) — refuse every
        // zone so the preview reads red rather than silently building a cross-worktree split.
        let sameBranch = sessionCanJoinLayout(sessionID)
        // Rim: within the outer band of the whole surface → split the whole surface toward that edge.
        if let dir = rimDirection(p, full) {
            let axis = dir.axis
            let extent = axis == .row ? contentSize.width : contentSize.height
            let keptMin = layout.map { paneMinAlong($0, axis: axis) } ?? (axis == .row ? Self.paneMinW : Self.paneMinH)
            let incomingMin = axis == .row ? Self.paneMinW : Self.paneMinH
            let rect = halfRect(full, dir)
            let ok = sameBranch && extent / 2 >= incomingMin && extent / 2 >= keptMin
            return DropResolution(rect: rect, kind: ok ? .rim : .refuse, zone: ok ? .rim(dir) : nil)
        }
        // Otherwise the pane under the pointer — always a split, toward the nearest edge (the pane
        // divides into four diagonal regions, so there's no dead centre and no replace).
        guard let leaf = paneUnder(p), let r = paneFrames[leaf.id] else {
            return DropResolution(rect: full, kind: .refuse, zone: nil)
        }
        let fx = (p.x - r.minX) / max(1, r.width)
        let fy = (p.y - r.minY) / max(1, r.height)
        let nearest = min(fx, 1 - fx, fy, 1 - fy)
        let dir: ArrowDir = nearest == fx ? .left : nearest == (1 - fx) ? .right
                          : nearest == fy ? .up : .down
        let axis = dir.axis
        let extent = axis == .row ? r.width : r.height
        // Refuse a cross-branch session, a drop onto the dragged session's own pane, or one that
        // breaches the floor.
        let ok = sameBranch && leaf.sessionID != sessionID && extent / 2 >= (axis == .row ? Self.paneMinW : Self.paneMinH)
        return DropResolution(rect: halfRect(r, dir), kind: ok ? .split : .refuse,
                              zone: ok ? .edge(leaf.id, dir) : nil)
    }

    /// Resolve a *global* pointer (a sidebar drag in flight) to a content drop zone, or nil when the
    /// pointer isn't over the content. Maps global → content-local against the reported frame.
    func dropZone(atGlobal p: CGPoint, dragging sessionID: UUID) -> DropResolution? {
        guard contentGlobalFrame.contains(p) else { return nil }
        let local = CGPoint(x: p.x - contentGlobalFrame.minX, y: p.y - contentGlobalFrame.minY)
        return resolveDrop(at: local, contentSize: contentGlobalFrame.size, dragging: sessionID)
    }

    /// The session row a *global* pointer is squarely over (centre 30–70%, edges stay reorder
    /// territory) — the pair-to-split target (012). Excludes the dragged session's own row, and any
    /// row in another branch / worktree — a pair is a split, which stays within one branch (003).
    func pairTarget(atGlobal p: CGPoint, dragging sessionID: UUID) -> UUID? {
        let dragBranch = session(sessionID).flatMap { branch(of: $0)?.id }
        for (sid, frame) in sessionRowFrames where sid != sessionID {
            guard session(sid).flatMap({ branch(of: $0)?.id }) == dragBranch else { continue }
            guard frame.contains(p) else { continue }
            let ry = (p.y - frame.minY) / max(1, frame.height)
            // The centre 60% of a row reads as "onto" (pair); its top/bottom 20% edges stay reorder
            // territory. Nothing reshuffles live, so a near-miss just pairs — never a jarring hop.
            return (ry < 0.2 || ry > 0.8) ? nil : sid
        }
        return nil
    }

    /// The slot a reorder drag at global `y` points at (working.html updateDropLine): insert before
    /// the first sibling — the dragged unit excluded — whose vertical midpoint sits below the
    /// pointer, else append at the list end. Sessions compare *unowned block heads*: an owning
    /// claude drags its owned browsers along as one block, so "the slot after the source" means
    /// the next unowned head, not the next row. nil = the drop is a no-op (the pointer rests in
    /// the dragged unit's own slot, which the faded source already marks) — the line hides and
    /// the release moves nothing. One computation feeds both the line and the commit, so the
    /// line can never promise a slot the release won't land in.
    struct ReorderDrop {
        var delta: Int      // sibling/block steps moveWithinSiblings takes on release
        var line: CGRect    // the insertion line's global frame (row width, inset 4pt each side)
    }

    func reorderDrop(_ ref: RowRef, atGlobalY y: CGFloat) -> ReorderDrop? {
        let ids: [UUID]
        let frames: [UUID: CGRect]
        switch ref {
        case let .session(s):
            guard s.ownerSessionID == nil, let br = branch(of: s) else { return nil }
            ids = br.sessions.filter { $0.ownerSessionID == nil }.map(\.id)
            frames = sessionRowFrames
        case let .branch(b):
            guard let ws = workspace(of: b) else { return nil }
            ids = ws.branches.map(\.id)
            frames = reorderUnitFrames
        case .workspace:
            ids = workspaces.map(\.id)
            frames = reorderUnitFrames
        }
        // Compute among the on-screen siblings only (the top-level LazyVStack drops frames for
        // rows scrolled out of existence); the rendered range is contiguous, so positions within
        // it translate 1:1 into moveWithinSiblings steps.
        let present = ids.filter { $0 == ref.id || frames[$0] != nil }
        guard let cur = present.firstIndex(of: ref.id) else { return nil }
        let items = present.filter { $0 != ref.id }.compactMap { frames[$0] }
        guard !items.isEmpty else { return nil }
        let hit = items.firstIndex { y < $0.midY }
        let target = hit ?? items.count
        guard target != cur else { return nil }
        let r = items[hit ?? items.count - 1]
        let line = CGRect(x: r.minX + 4, y: (hit != nil ? r.minY : r.maxY) - 1,
                          width: r.width - 8, height: 2)
        return ReorderDrop(delta: target - cur, line: line)
    }

    /// Land the reorder the insertion line promised (the list never moved mid-drag): step the
    /// unit into the drop slot — animated, working.html's flip — and persist once. A nil drop
    /// (no-op slot, hidden line) moves nothing.
    func commitReorderDrop(_ ref: RowRef, atGlobalY y: CGFloat, animated: Bool) {
        guard let drop = reorderDrop(ref, atGlobalY: y) else { return }
        var delta = drop.delta
        while delta > 0, moveWithinSiblings(ref, by: 1, animated: animated) { delta -= 1 }
        while delta < 0, moveWithinSiblings(ref, by: -1, animated: animated) { delta += 1 }
        saveNow()
    }

    /// Drop-reorder (010's reorder branch, committed on release): land `sid` in the slot the
    /// insertion line pointed at.
    func reorderSession(_ sid: UUID, toGlobalY y: CGFloat) {
        guard let s = session(sid) else { return }
        commitReorderDrop(.session(s), atGlobalY: y, animated: true)
    }

    /// Land a pair (012): if the target is already a pane the dragged session splits it in place
    /// (moving out of any pane it held); otherwise the two become a fresh side-by-side layout, the
    /// dragged session active. Focus follows the dragged session, like every other create route.
    func performPair(dragged xid: UUID, onto yid: UUID) {
        guard xid != yid else { return }
        // A pair is a split, so both sessions must share a branch / worktree (003) — pairing across
        // branches would open Y then graft X's foreign pane into it.
        guard let x = session(xid), let y = session(yid),
              let bx = branch(of: x), let by = branch(of: y), bx.id == by.id else { return }
        if let yleaf = leaf(of: yid) {
            splitActiveWith(session: xid, dir: .row, before: false, target: yleaf)
        } else if let y = session(yid) {
            open(y)                                   // Y becomes the single pane in its branch
            if let yleaf = leaf(of: yid) {
                splitActiveWith(session: xid, dir: .row, before: false, target: yleaf)
            }
        }
    }

    private func rimDirection(_ p: CGPoint, _ full: CGRect) -> ArrowDir? {
        let m = Self.dropRimPx
        let dl = p.x - full.minX, dr = full.maxX - p.x, dt = p.y - full.minY, db = full.maxY - p.y
        let nearest = min(dl, dr, dt, db)
        guard nearest <= m else { return nil }
        if nearest == dl { return .left }
        if nearest == dr { return .right }
        if nearest == dt { return .up }
        return .down
    }

    private func halfRect(_ r: CGRect, _ dir: ArrowDir) -> CGRect {
        switch dir {
        case .left:  return CGRect(x: r.minX, y: r.minY, width: r.width / 2, height: r.height)
        case .right: return CGRect(x: r.midX, y: r.minY, width: r.width / 2, height: r.height)
        case .up:    return CGRect(x: r.minX, y: r.minY, width: r.width, height: r.height / 2)
        case .down:  return CGRect(x: r.minX, y: r.midY, width: r.width, height: r.height / 2)
        }
    }

    private func paneUnder(_ p: CGPoint) -> PaneNode? {
        paneLeaves.first { paneFrames[$0.id]?.contains(p) ?? false }
    }

    /// Apply a resolved drop (010): the session lands in the zone. An already-open session *moves*
    /// (its old pane collapses) rather than duplicating; focus follows the drop.
    func performDrop(session sessionID: UUID, zone: DropZone) {
        switch zone {
        case let .rim(dir):
            if let existing = leaf(of: sessionID) { removeLeaf(existing) }
            splitRoot(session: sessionID, dir: dir.axis, before: dir.before)
        case let .edge(leafID, dir):
            guard let target = nodeByID(leafID), target.isLeaf else { return }
            splitActiveWith(session: sessionID, dir: dir.axis, before: dir.before, target: target)
        }
    }

    private func nodeByID(_ id: UUID) -> PaneNode? {
        var hit: PaneNode?
        eachLeaf(layout) { if $0.id == id { hit = $0 } }
        return hit
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
