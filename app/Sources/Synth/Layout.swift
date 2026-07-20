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

    /// The member sessions of an on-screen split, in reading order (the tree flattened a-before-b) —
    /// the sidebar echo's source (012). Empty unless the durable layout binds ≥2 sessions.
    var echoMemberIDs: [UUID] {
        var ids: [UUID] = []
        eachLeaf(durableLayout) { if let s = $0.sessionID { ids.append(s) } }
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

    /// The region a drop will occupy + how it reads. `zone` is nil when refused (floor breach).
    struct DropResolution: Equatable {
        enum Kind { case split, replace, rim, refuse }
        var rect: CGRect
        var kind: Kind
        var zone: DropZone?
    }
    enum DropZone: Equatable {
        case rim(ArrowDir)            // split the whole surface (outer rim)
        case edge(UUID, ArrowDir)     // split the hovered pane on that edge
        case replace(UUID)            // swap the hovered pane's session in place
    }

    private static let dropRimPx: CGFloat = 26      // outer band that reads as a whole-surface split
    private static let dropEdgeFrac: CGFloat = 0.25 // inner band of a pane that reads as an edge split

    /// Resolve a pointer in content coordinates to the zone a dropped session will land in
    /// (working.html computeDrop): rim → splitRoot, pane edge → splitPane, centre → replace. Any
    /// zone that would breach the 360×240 floor comes back `.refuse` (a no-op drop).
    func resolveDrop(at p: CGPoint, contentSize: CGSize, dragging sessionID: UUID) -> DropResolution {
        let full = CGRect(origin: .zero, size: contentSize)
        // Rim: within the outer band of the whole surface → split the whole surface toward that edge.
        if let dir = rimDirection(p, full) {
            let axis = dir.axis
            let extent = axis == .row ? contentSize.width : contentSize.height
            let keptMin = layout.map { paneMinAlong($0, axis: axis) } ?? (axis == .row ? Self.paneMinW : Self.paneMinH)
            let incomingMin = axis == .row ? Self.paneMinW : Self.paneMinH
            let rect = halfRect(full, dir)
            let ok = extent / 2 >= incomingMin && extent / 2 >= keptMin
            return DropResolution(rect: rect, kind: ok ? .rim : .refuse, zone: ok ? .rim(dir) : nil)
        }
        // Otherwise the pane under the pointer.
        guard let leaf = paneUnder(p), let r = paneFrames[leaf.id] else {
            return DropResolution(rect: full, kind: .refuse, zone: nil)
        }
        let fx = (p.x - r.minX) / max(1, r.width)
        let fy = (p.y - r.minY) / max(1, r.height)
        let e = Self.dropEdgeFrac
        // Nearest edge if the pointer is in that pane's outer band, else the centre = replace.
        let dir: ArrowDir?
        if fx < e { dir = .left } else if fx > 1 - e { dir = .right }
        else if fy < e { dir = .up } else if fy > 1 - e { dir = .down }
        else { dir = nil }
        if let dir {
            let axis = dir.axis
            let extent = axis == .row ? r.width : r.height
            let ok = extent / 2 >= (axis == .row ? Self.paneMinW : Self.paneMinH)
            return DropResolution(rect: halfRect(r, dir), kind: ok ? .split : .refuse,
                                  zone: ok ? .edge(leaf.id, dir) : nil)
        }
        // Centre → replace the pane's session in place (the displaced one returns to the sidebar).
        return DropResolution(rect: r, kind: .replace, zone: .replace(leaf.id))
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
        case let .replace(leafID):
            guard let target = nodeByID(leafID), target.isLeaf else { return }
            if let existing = leaf(of: sessionID), existing !== target { removeLeaf(existing) }
            target.sessionID = sessionID   // the displaced session drops back to a sidebar row, still running
            target.setupBranchID = nil
            stashedSplit = nil
            activePane = target
            renderLayout()
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
