import SwiftUI

/// The experimental Tabs view mode's content strip (working.html `renderContentTabStrip`).
///
/// ONE strip per branch — never one per pane — the horizontal twin of the sidebar's session
/// rows (`renderSidebarEcho`). It mirrors the current branch's sessions in sidebar order; the
/// sessions in the on-screen split fold into a contiguous **group** placed where their first member
/// sits — a hairline **tray** the members sit inside, with no fill of its own. A member is an ordinary
/// tab, and it carries one added thing: an 8pt map of the split on its icon with that tab's own pane
/// filled. The pane-tree spine (ADR-0014) is unchanged — a leaf still binds one session; the strip is
/// pure presentation over the existing `open` / stash model. Only shown while `store.tabsMode`
/// (ContentPane gates it).
///
/// Tabs are **chips on a rail**: 28pt rounded chips inset off every edge of a 36pt strip. Nothing is
/// full-bleed, so there are no seams between tabs, no bar under the open one, and no fill reaching
/// the sidebar's rounded corner — the open tab lifts off the rail as a card, and that elevation is
/// the whole of "open". An unopened tab is its label and nothing else.
struct TabStrip: View {
    @Environment(AppStore.self) private var store

    private var branch: Branch? { store.currentBranch }

    var body: some View {
        HStack(spacing: 0) {
            // Collapsed sidebar: the strip stands in for the pane head that used to host the
            // expand toggle, so carry it here, cleared past the traffic lights. Its own clearance is
            // measured from the window edge, so the rail's inset goes on the tab row, not out here.
            if store.sidebarCollapsed {
                SidebarToggle()
                    .padding(.leading, Theme.trafficLightsClearance)
                    .padding(.trailing, 6)
            }
            FlexRow(spacing: 3) {
                ForEach(items) { item in
                    switch item {
                    case let .tab(s):
                        TabChip(session: s)
                    case let .cluster(members):
                        TabGroup(members: members, maps: branch.map { store.paneRects(for: $0) } ?? [:])
                    }
                }
                NewTabButton()
            }
            .padding(.leading, store.sidebarCollapsed ? 0 : 8)
            // Past the point where every tab is at its floor the row stops shrinking and simply
            // overruns, exactly as the mock's `overflow: hidden` row does. Masked on the horizontal
            // only — a plain clip would take the open chip's shadow off with it.
            .mask { Rectangle().padding(.vertical, -24) }
            // Served its full ask before the spacer and the PR chip, so the tabs get the room and the
            // slack lands on the right — an even split would starve them the moment a PR chip appears.
            .layoutPriority(1)
            Spacer(minLength: 0)
            // The per-pane header is gone in tabs mode, so the branch's PR relocates here,
            // right-aligned (working.html `.tabstrip__pr`).
            if let pr = branch?.pr {
                PRChip(pr: pr).padding(.leading, 6).padding(.trailing, 12)
            }
        }
        // The 32pt split tray plus 2 — the same 2 the tray gives its own members, so the rail is
        // no deeper than the run it holds (working.html `.tabstrip`).
        .frame(height: Theme.tabStripHeight)
        // No fill and no bottom rule of its own: the shell root's coat is already under it, and the
        // chips are inset far enough off every edge that nothing needs a seam to stop at.
        .background(GeometryReader { g in
            Color.clear
                .onAppear { store.tabStripFrame = g.frame(in: .global) }
                .onChange(of: g.frame(in: .global)) { _, f in store.tabStripFrame = f }
        })
    }

    /// The branch's sessions in sidebar order, with the on-screen split's members folded into one
    /// bonded cluster placed where the first member sits (the twin of Sidebar's `sessionItems`).
    private var items: [StripItem] {
        guard let branch else { return [] }
        let echo = store.echoMemberIDs(for: branch)   // [] unless ≥2 members
        let memberSet = Set(echo)
        guard !echo.isEmpty, branch.sessions.contains(where: { memberSet.contains($0.id) }) else {
            return branch.sessions.map { .tab($0) }
        }
        let members = echo.compactMap { id in branch.sessions.first { $0.id == id } }
        var out: [StripItem] = []
        var placed = false
        for s in branch.sessions {
            if memberSet.contains(s.id) {
                if !placed { out.append(.cluster(members)); placed = true }
            } else {
                out.append(.tab(s))
            }
        }
        return out
    }
}

private enum StripItem: Identifiable {
    case tab(Session)
    case cluster([Session])
    var id: String {
        switch self {
        case let .tab(s): return "tab-\(s.id.uuidString)"
        case let .cluster(m): return "cluster-" + m.map(\.id.uuidString).joined()
        }
    }
}

// MARK: - Lone tab

/// A tab — the session's handle: icon (+ unread dot), name, its live/needs-input signal, and a
/// hover-revealed close, on a 28pt rounded chip. Active (== the open session) is the only thing on
/// the strip carrying a fill, and it lifts: raised behind a hairline, over two soft shadows
/// (working.html `.tab` / `.tab--active`).
private struct TabChip: View {
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var colorScheme
    let session: Session
    /// This tab's pane as a fraction rect of the split it belongs to — the map it wears. Nil on a
    /// lone tab, which has no split to map.
    var paneMap: CGRect?
    @State private var hovering = false

    private var isActive: Bool { store.openSessionID == session.id }
    /// The chip's own fill — the open tab holds its raised fill under the pointer rather than washing
    /// back down to the hover tint.
    private var fill: Color { isActive ? Theme.raised : (hovering ? Theme.rowHover : .clear) }
    // Double-clicking the tab renames it in place, reusing the sidebar row's inline-rename machinery
    // keyed by session id (working.html `startTabRename`) — the field swaps in for the name label.
    private var renaming: Bool { store.renamingRowID == session.id }
    /// The map overhangs the icon, so a member's name starts further along than a lone tab's.
    private var contentSpacing: CGFloat { paneMap == nil ? 6 : 9 }

    var body: some View {
        // A Button carries the tap (so the drag's highPriorityGesture never swallows the click —
        // the sidebar's proven pattern); the close is a ZStack sibling, not nested, so it stays
        // independently clickable. Title is left-aligned and greedy, pushing the status slot + close
        // to the right edge; the tab fills to a 240pt cap and compresses when the strip is crowded.
        ZStack(alignment: .trailing) {
            if renaming {
                HStack(spacing: contentSpacing) {
                    TabIcon(session: session, ring: isActive ? Theme.raised : Theme.panel, paneMap: paneMap)
                    RenameField(font: .sans(12, 500))
                    Spacer(minLength: 4)
                }
                .padding(.leading, 9).padding(.trailing, 5)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(shell)
            } else {
                Button { store.open(session); focusContent(store) } label: {
                    HStack(spacing: contentSpacing) {
                        TabIcon(session: session, ring: isActive ? Theme.raised : Theme.panel, paneMap: paneMap)
                        Text(session.title)
                            .font(.sans(12, 500))
                            .foregroundStyle(isActive ? Theme.ink : Theme.inkMuted)
                            .lineLimit(1).truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        indicator
                        Color.clear.frame(width: 16)   // reserve the close slot (overlaid below)
                    }
                    .padding(.leading, 9).padding(.trailing, 5)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(shell)
                    .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .onDoubleClick { store.beginRename(.session(session)) }
                TabCloseButton(session: session, visible: hovering || isActive).padding(.trailing, 5)
            }
        }
        .frame(minWidth: 34, maxWidth: 200)
        .frame(height: 28)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.11), value: hovering)
        .tabDrag(session)
        // Right-click opens the same ⌘K frame the sidebar row's ⋯ / right-click opens (openRowActions).
        .onSecondaryClick { store.openRowActions(.session(session)) }
        .help(session.title)
    }

    /// The chip itself. Elevation is the only thing that says "open" here — a hairline plus a
    /// contact shadow, and no fill at all when the tab is closed. Dark can't lean on a black drop
    /// shadow the way light does — it reads as nothing against an already-dark rail — so dark trades
    /// the wasted ambient blur for a hairline top highlight instead (light catching the tab's edge,
    /// the standard dark-UI substitute for shadow).
    @ViewBuilder private var shell: some View {
        let shape = RoundedRectangle(cornerRadius: 8)
        shape.fill(fill)
            .overlay {
                if isActive { shape.strokeBorder(Theme.borderStrong, lineWidth: 0.5) }
            }
            .overlay {
                if isActive && colorScheme == .dark {
                    Rectangle().fill(.white.opacity(0.06)).frame(height: 1)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .clipShape(shape)
                }
            }
            .shadow(color: contactShadow, radius: colorScheme == .dark ? 1 : 0.5, y: 1)
            .shadow(color: ambientShadow, radius: 5, y: 4)
            // Copper ring + wash when a dragged tab is about to pair into a split with this one (012).
            .overlay {
                if store.pairTargetID == session.id {
                    shape.fill(Theme.accent.opacity(0.12))
                        .overlay { shape.strokeBorder(Theme.accent.opacity(0.7), lineWidth: 1.5) }
                }
            }
    }
    /// The tight, always-present grounding shadow (working.html `.tab--active`'s first layer).
    private var contactShadow: Color {
        guard isActive else { return .clear }
        return colorScheme == .dark ? .black.opacity(0.3) : .black.opacity(0.05)
    }
    /// The soft ambient lift — light only; in dark it never had enough contrast to show.
    private var ambientShadow: Color {
        guard isActive, colorScheme == .light else { return .clear }
        return .black.opacity(0.08)
    }

    // The same status/owner slot the sidebar row carries; a browser owned by an agent wears the
    // owner's mark instead of a liveness dot (working.html `.tab__ind`, reusing `.ind`).
    @ViewBuilder private var indicator: some View {
        if session.ownerSessionID != nil, let owner = store.owner(of: session) {
            OwnedIndicator(ownerKind: owner.kind)
        } else if session.ownerSessionID != nil {
            OwnedIndicator()
        } else {
            StatusIndicator(status: session.status)
        }
    }
}

/// The session icon carrying up to two corner marks: the quiet blue unread dot at its top-right, and
/// — on a split member — the pane map at its bottom-right. Opposite corners, each on a plate of the
/// tab's own fill, so both fit on one 14pt icon without touching.
private struct TabIcon: View {
    let session: Session
    var size: CGFloat = 14
    var ring: Color = Theme.panel
    var paneMap: CGRect?
    var body: some View {
        SessionIcon(kind: session.kind, size: size)
            .frame(width: size, height: size)
            .overlay(alignment: .topTrailing) {
                if session.unread {
                    // 6pt of blue with the 1.5pt ring OUTSIDE it (working.html's box-shadow spread,
                    // 9pt overall) — an inset strokeBorder would eat half the dot.
                    Circle().fill(Theme.input)
                        .frame(width: 6, height: 6)
                        .background(Circle().fill(ring).frame(width: 9, height: 9))
                        .offset(x: 3, y: -2)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if let paneMap {
                    PaneMap(rect: paneMap, plate: ring).offset(x: 4, y: 3)
                }
            }
    }
}

/// The split at 8pt with this tab's own pane filled — the whole of what marks a member as grouped.
/// Two tabs wearing the same map are the same split, and the fill says *which* pane, so a member
/// reads as a position before you look down at the surface (working.html `.tab__map` / `paneMapHTML`).
///
/// The 5.7pt inner box leaves the fill an even 0.2 margin inside the outline and a 0.4 gutter
/// between panes; the plate is the tab's own fill, extended a point past the map so the mark reads
/// clear of the session icon it sits on.
private struct PaneMap: View {
    /// This pane as a fraction rect of the whole surface.
    let rect: CGRect
    let plate: Color

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 1.6)
                .strokeBorder(Theme.accent.opacity(0.45), lineWidth: 1)
                .frame(width: 6.8, height: 6.8)
                .offset(x: 0.6, y: 0.6)
            RoundedRectangle(cornerRadius: 0.7)
                .fill(Theme.accent)
                .frame(width: rect.width * 5.7 - 0.4, height: rect.height * 5.7 - 0.4)
                .offset(x: 1.35 + rect.minX * 5.7, y: 1.35 + rect.minY * 5.7)
        }
        .frame(width: 8, height: 8)
        .background(RoundedRectangle(cornerRadius: 3).fill(plate).frame(width: 10, height: 10))
        .allowsHitTesting(false)
    }
}

private struct TabCloseButton: View {
    @Environment(AppStore.self) private var store
    let session: Session
    let visible: Bool
    @State private var hovering = false

    var body: some View {
        // × closes through the same confirm/close path as ⌘W (confirms while busy).
        Button { store.requestDelete(.session(session)) } label: {
            Phos(path: Phosphor.close, size: 11)
                .foregroundStyle(hovering ? Theme.ink : Theme.inkFaint)
                .frame(width: 16, height: 16)
                .background(RoundedRectangle(cornerRadius: 4).fill(hovering ? Theme.rowHover : .clear))
                .padding(.leading, 1)   // outside the pill, so the glyph stays centred in its 16pt
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .opacity(visible ? (hovering ? 1 : 0.6) : 0)
        .help("Close")
    }
}

private struct NewTabButton: View {
    @Environment(AppStore.self) private var store
    @State private var hovering = false

    var body: some View {
        // + opens a new session on the branch, straight into the ⌘K create frame.
        Button { if let branch = store.currentBranch { store.addToRow(.branch(branch)) } } label: {
            Phos(path: Phosphor.plus, size: 14)
                .foregroundStyle(hovering ? Theme.ink : Theme.inkMuted)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 7).fill(hovering ? Theme.rowHover : .clear))
                .padding(.leading, 1)
                .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("New session")
    }
}

// MARK: - The on-screen split's group of tabs

/// The split's members, folded into one contiguous run at the first member's slot and enclosed in a
/// **tray**: a hairline container with nothing behind it (working.html `.tab-group`).
///
/// The tray deliberately carries no fill. On this strip a background is what "open" means, so a
/// filled tray would hand every unfocused member the one signal reserved for exactly one tab. Empty,
/// a member sits on the bare rail like any other unopened tab and the active member stays the only
/// card in the strip. Membership is the enclosure; *which* pane is the map each member wears, whose
/// shape comes from the real pane tree.
private struct TabGroup: View {
    let members: [Session]
    /// Each member's pane as a fraction rect of the surface, keyed by session.
    let maps: [UUID: CGRect]

    var body: some View {
        FlexRow(spacing: 2) {
            ForEach(members) { session in
                TabChip(session: session, paneMap: maps[session.id])
            }
        }
        .padding(2)
        .overlay { RoundedRectangle(cornerRadius: 11).strokeBorder(Theme.borderStrong, lineWidth: 0.5) }
    }
}

// MARK: - The strip's row layout

/// A row that lays its children out the way the mock's flex row does: each at its ideal width when
/// they all fit, and — when they don't — every child shrunk **in proportion to that ideal**, floored
/// at its own minimum.
///
/// SwiftUI's own HStack divides the shortfall evenly between children, which is the wrong answer
/// here for the same reason `min-width: auto` was on the web: a split's tray holds N tabs, so an even
/// split squeezes each of its members N times as hard as the lone tab beside it. A member IS a tab,
/// so it has to shrink and truncate on exactly the same terms as one.
private struct FlexRow: Layout {
    var spacing: CGFloat = 0

    struct Cache { var ideal: [CGFloat] = []; var floor: [CGFloat] = [] }

    func makeCache(subviews: Subviews) -> Cache { measure(subviews) }
    func updateCache(_ cache: inout Cache, subviews: Subviews) { cache = measure(subviews) }

    private func measure(_ subviews: Subviews) -> Cache {
        Cache(ideal: subviews.map { $0.sizeThatFits(.unspecified).width },
              floor: subviews.map { $0.sizeThatFits(ProposedViewSize(width: 0, height: nil)).width })
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let ideal = cache.ideal.reduce(0, +) + gaps(subviews.count)
        // Reporting the true floor for a zero proposal is what makes a NESTED row honest: a tray asked
        // for nothing would otherwise answer nothing, and its members — which never shrink past their
        // own 34pt floor — would spill out past the hairline enclosing them.
        let floor = cache.floor.reduce(0, +) + gaps(subviews.count)
        let height = subviews.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
        return CGSize(width: max(floor, min(ideal, proposal.width ?? ideal)),
                      height: proposal.height ?? height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        let widths = resolve(bounds.width, cache: cache, count: subviews.count)
        var x = bounds.minX
        for (i, sub) in subviews.enumerated() {
            sub.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading,
                      proposal: ProposedViewSize(width: widths[i], height: bounds.height))
            x += widths[i] + spacing
        }
    }

    private func gaps(_ count: Int) -> CGFloat { spacing * CGFloat(max(0, count - 1)) }

    /// One pass per child that bottoms out: the overflow is shared in proportion to each remaining
    /// child's current width, and anything a floored child could not absorb goes round again.
    private func resolve(_ available: CGFloat, cache: Cache, count: Int) -> [CGFloat] {
        var w = cache.ideal
        var over = w.reduce(0, +) + gaps(count) - available
        var elastic = (0..<count).filter { w[$0] - cache.floor[$0] > 0.5 }
        while over > 0.5, !elastic.isEmpty {
            // weighted by the IDEAL, not the already-shrunk width — flex re-runs against the base
            // size every pass and only freezes items, it never re-bases on what it has taken
            let basis = elastic.reduce(0.0) { $0 + cache.ideal[$1] }
            guard basis > 0.5 else { break }
            var spent: CGFloat = 0
            for i in elastic {
                let take = Swift.min(over * cache.ideal[i] / basis, w[i] - cache.floor[i])
                w[i] -= take
                spent += take
            }
            guard spent > 0.5 else { break }
            over -= spent
            elastic = elastic.filter { w[$0] - cache.floor[$0] > 0.5 }
        }
        return w
    }
}

// MARK: - Tab drag (reorder · pair · split · unsplit)

/// The tab's unified drag — one pointer drag whose mode is decided live by where the pointer is,
/// mirroring the sidebar's `SessionRowDrag` (010/012/013) on the horizontal strip: over a pane →
/// split it at the pointer; squarely over another tab → pair the two; between tabs / empty strip →
/// reorder the branch's sessions; a split member dragged out to the strip leaves its split. Reuses
/// the exact store ops (`dropZone`/`performDrop`, `pairTarget`/`performPair`, `unsplitSession`) and
/// registers the tab's frame into `sessionRowFrames` so tab-over-tab pairing works for free.
private struct TabDrag: ViewModifier {
    @Environment(AppStore.self) private var store
    let session: Session

    @State private var wasMember = false
    @State private var lastPoint: CGPoint = .zero
    @State private var mode: Mode = .reorder
    private enum Mode { case reorder, content, pair, none }

    private var dragging: Bool { store.dragGhostSessionID == session.id }
    // While this tab is being renamed the drag stands down, so drag-selecting the name in the field
    // never hijacks into a tab drag (working.html guards its pointerdown on `.tab__name[contenteditable]`).
    private var renaming: Bool { store.renamingRowID == session.id }

    func body(content: Content) -> some View {
        content
            .background(GeometryReader { g in
                Color.clear
                    .onAppear { store.sessionRowFrames[session.id] = g.frame(in: .global) }
                    .onChange(of: g.frame(in: .global)) { _, f in store.sessionRowFrames[session.id] = f }
                    .onDisappear { store.sessionRowFrames[session.id] = nil }
            })
            .opacity(dragging ? 0.4 : 1)
            .highPriorityGesture(drag, including: renaming ? .subviews : .all)
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .global)
            .onChanged { v in
                if !dragging {
                    wasMember = store.inSplit(session.id)
                    store.keyboardActive = false
                    store.draggingRowID = session.id
                    store.dragGhostSessionID = session.id
                }
                let p = v.location
                lastPoint = p
                store.dragGhostPoint = p
                // 1) Over the content → split / replace / rim at the pointer.
                if let dz = store.dropZone(atGlobal: p, dragging: session.id) {
                    mode = .content
                    store.dropPreview = dz; store.pairTargetID = nil; store.tabReorderLine = nil
                    return
                }
                store.dropPreview = nil
                // 2) Squarely over another tab → pair the two into a split.
                if let target = store.pairTarget(atGlobal: p, dragging: session.id) {
                    mode = .pair
                    store.pairTargetID = target; store.tabReorderLine = nil
                    return
                }
                // 3) Over the strip (between tabs / the +) → reorder; anywhere else (the sidebar,
                //    the titlebar, off-window) → cancel, so a stray release never snaps the tab.
                if store.tabStripFrame.contains(p) {
                    mode = .reorder
                    store.pairTargetID = nil
                    store.tabReorderLine = store.tabReorderLine(session.id, atGlobalX: p.x)
                } else {
                    mode = .none
                    store.pairTargetID = nil; store.tabReorderLine = nil
                }
            }
            .onEnded { _ in
                switch mode {
                case .content:
                    if let zone = store.dropPreview?.zone { store.performDrop(session: session.id, zone: zone) }
                case .pair:
                    if let target = store.pairTargetID { store.performPair(dragged: session.id, onto: target) }
                case .reorder:
                    // Land the tab in the slot the line pointed at, then — if it was a split member —
                    // drop it out of its split (013): reorder-then-unsplit, exactly as the mock.
                    store.reorderTab(session.id, toGlobalX: lastPoint.x)
                    if wasMember, store.inSplit(session.id) { store.unsplitSession(session.id) }
                case .none:
                    break   // released off the strip — a true cancel
                }
                mode = .reorder
                store.draggingRowID = nil
                store.dragGhostSessionID = nil
                store.dropPreview = nil
                store.pairTargetID = nil
                store.tabReorderLine = nil
            }
    }
}

private extension View {
    func tabDrag(_ session: Session) -> some View { modifier(TabDrag(session: session)) }
}

/// The vertical copper insertion line a tab reorder drag paints at its landing slot — the
/// horizontal twin of the sidebar's `DropLine`. Mounted at the window root over the drag ghost.
struct TabDropLine: View {
    @Environment(AppStore.self) private var store
    var body: some View {
        if let r = store.tabReorderLine {
            RoundedRectangle(cornerRadius: 1)
                .fill(Theme.accent.opacity(0.9))
                .frame(width: r.width, height: r.height)
                .overlay(alignment: .top) {
                    Circle().fill(Theme.accent.opacity(0.9)).frame(width: 6, height: 6).offset(y: -3)
                }
                .offset(x: r.minX, y: r.minY)
                .allowsHitTesting(false)
                .ignoresSafeArea()
        }
    }
}
