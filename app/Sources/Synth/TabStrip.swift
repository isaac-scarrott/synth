import SwiftUI

/// The experimental Tabs view mode's content strip (working.html `renderContentTabStrip`).
///
/// ONE strip per branch — never one per pane — the horizontal twin of the sidebar's session
/// rows (`renderSidebarEcho`). It mirrors the current branch's sessions in sidebar order; the
/// sessions in the on-screen split fold into a contiguous **group** placed where their first member
/// sits. A member is an ordinary tab — same height, padding, indicator, ×, active bar, hover wash —
/// and what marks the group is one added thing: an 8pt map of the split on each member's icon with
/// that tab's own pane filled. The pane-tree spine (ADR-0014) is unchanged — a leaf still binds one
/// session; the strip is pure presentation over the existing `open` / stash model. Only shown while
/// `store.tabsMode` (ContentPane gates it).
struct TabStrip: View {
    @Environment(AppStore.self) private var store

    private var branch: Branch? { store.currentBranch }

    var body: some View {
        HStack(spacing: 0) {
            // Collapsed sidebar: the strip stands in for the pane head that used to host the
            // expand toggle, so carry it here, cleared past the traffic lights.
            if store.sidebarCollapsed {
                SidebarToggle()
                    .padding(.leading, Theme.trafficLightsClearance)
                    .padding(.trailing, 6)
            }
            ForEach(items) { item in
                // Whatever leads the strip meets the sidebar seam — a lone tab, or a group's first
                // member, since a member is a full-bleed tab now. A collapsed sidebar puts the
                // toggle there first, so nothing bleeds.
                let leads = !store.sidebarCollapsed && item.id == items.first?.id
                switch item {
                case let .tab(s):
                    TabChip(session: s, bleedsUnderSidebar: leads)
                case let .cluster(members):
                    TabGroup(members: members,
                             maps: branch.map { store.paneRects(for: $0) } ?? [:],
                             bleedsUnderSidebar: leads)
                }
            }
            NewTabButton()
            Spacer(minLength: 8)
            // The per-pane header is gone in tabs mode, so the branch's PR relocates here,
            // right-aligned (working.html `.tabstrip__pr`).
            if let pr = branch?.pr {
                PRChip(pr: pr).padding(.leading, 6).padding(.trailing, 8)
            }
        }
        .frame(height: 30)
        // No fill of its own: the shell root's coat is already under it, and a second coat would
        // read as a near-opaque band across the top of every pane.
        .background(GeometryReader { g in
            Color.clear
                .onAppear { store.tabStripFrame = g.frame(in: .global) }
                .onChange(of: g.frame(in: .global)) { _, f in store.tabStripFrame = f }
        })
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 0.5) }
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

/// A lone tab — the session's handle: icon (+ unread dot), name, its live/needs-input signal, and
/// a hover-revealed close. Active (== the open session) lifts on a raised fill with the mark bar
/// (working.html `.tab` / `.tab--active`).
private struct TabChip: View {
    @Environment(AppStore.self) private var store
    let session: Session
    /// Set on the tab that meets the sidebar seam: its fill runs on into the wedge the sidebar's
    /// rounded corner leaves uncovered, so the fill follows that curve rather than stopping in a hard
    /// square short of it (working.html `.tab-bleed`). Only the wedge — see `SidebarCornerWedge`.
    var bleedsUnderSidebar = false
    /// This tab's pane as a fraction rect of the split it belongs to — the map it wears. Nil on a
    /// lone tab, which has no split to map.
    var paneMap: CGRect?
    /// Where this tab sits in its group, if it's in one. Drives the seams: members are one unit, so
    /// what divides them is an inset hairline, and only the last one carries the strip's full seam.
    var groupPosition: GroupPosition?
    @State private var hovering = false

    enum GroupPosition { case first, middle, last }

    private var isActive: Bool { store.openSessionID == session.id }
    /// The tab's own fill — the open tab holds its raised fill under the pointer rather than washing
    /// back down to the hover tint. The run-on under the sidebar reads this, so it can never disagree.
    private var fill: Color { isActive ? Theme.raised : (hovering ? Theme.rowHover : .clear) }
    // Double-clicking the tab renames it in place, reusing the sidebar row's inline-rename machinery
    // keyed by session id (working.html `startTabRename`) — the field swaps in for the name label.
    private var renaming: Bool { store.renamingRowID == session.id }
    /// The map overhangs the icon, so a member's name starts further along than a lone tab's.
    private var contentSpacing: CGFloat { groupPosition == nil ? 6 : 11 }
    /// A member hands its full-height seam to the last of the group; the rest are divided by the
    /// inset hairline below. A lone tab always carries its own.
    private var carriesSeam: Bool { groupPosition == nil || groupPosition == .last }

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
                .padding(.leading, 11).padding(.trailing, 6)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(fill)
                .overlay(alignment: .trailing) {
                    Rectangle().fill(Theme.border).frame(width: 0.5).opacity(carriesSeam ? 1 : 0)
                }
            } else {
                Button { store.open(session); focusContent(store) } label: {
                    HStack(spacing: contentSpacing) {
                        TabIcon(session: session, ring: isActive ? Theme.raised : Theme.panel, paneMap: paneMap)
                        Text(session.title)
                            .font(.sans(12, 500))
                            .foregroundStyle(isActive ? Theme.inkOpen : Theme.inkMuted)
                            .lineLimit(1).truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        indicator
                        Color.clear.frame(width: 16)   // reserve the close slot (overlaid below)
                    }
                    .padding(.leading, 11).padding(.trailing, 6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(fill)
                    .overlay(alignment: .trailing) {
                        Rectangle().fill(Theme.border).frame(width: 0.5).opacity(carriesSeam ? 1 : 0)
                    }
                    // Inside a group the members are one unit, so what divides them is an inset
                    // hairline rather than the full-height seam that ends the group.
                    .overlay(alignment: .leading) {
                        if groupPosition == .middle || groupPosition == .last {
                            Rectangle().fill(Theme.border).frame(width: 1).padding(.vertical, 8)
                        }
                    }
                    // The active-tab bar.
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(Theme.focus).frame(height: 2).opacity(isActive ? 1 : 0)
                    }
                    // Copper ring when a dragged tab is about to pair into a split with this one (012).
                    .overlay {
                        if store.pairTargetID == session.id {
                            Rectangle().strokeBorder(Theme.accent.opacity(0.7), lineWidth: 1.5)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onDoubleClick { store.beginRename(.session(session)) }
                TabCloseButton(session: session, visible: hovering || isActive).padding(.trailing, 6)
            }
        }
        .frame(maxWidth: 240, maxHeight: .infinity)
        .background(alignment: .topLeading) {
            if bleedsUnderSidebar {
                SidebarCornerWedge().fill(fill, style: FillStyle(eoFill: true))
                    .frame(width: Theme.radiusPanel, height: Theme.radiusPanel)
                    .offset(x: -Theme.radiusPanel)
                    .allowsHitTesting(false)
            }
        }
        .onHover { hovering = $0 }
        .tabDrag(session)
        // Right-click opens the same ⌘K frame the sidebar row's ⋯ / right-click opens (openRowActions).
        .onSecondaryClick { store.openRowActions(.session(session)) }
        .help(session.title)
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
                    Circle().fill(Theme.input)
                        .frame(width: 6, height: 6)
                        .overlay(Circle().strokeBorder(ring, lineWidth: 1.5))
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
                .foregroundStyle(hovering ? Theme.ink2 : Theme.inkFaint)
                .frame(width: 16, height: 16)
                .background(RoundedRectangle(cornerRadius: 4).fill(hovering ? Theme.rowHover : .clear))
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
                .frame(width: 30)
                .frame(maxHeight: .infinity)
                .background(hovering ? Theme.rowHover : Color.clear)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("New session")
    }
}

// MARK: - The on-screen split's group of tabs

/// The split's members, folded into one contiguous run at the first member's slot. There is no
/// container and no chrome of its own — a member is an ordinary tab, and what says "these are one
/// split" is the pane map each one wears plus the inset hairlines dividing them (working.html
/// `.tab-group`). The map's shape comes from the real pane tree, so a member also says *which* pane.
private struct TabGroup: View {
    let members: [Session]
    /// Each member's pane as a fraction rect of the surface, keyed by session.
    let maps: [UUID: CGRect]
    /// True when the group leads the strip: its first member is what meets the sidebar seam, so the
    /// bleed passes down to that tab rather than dying on a wrapper.
    let bleedsUnderSidebar: Bool

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(members.enumerated()), id: \.element.id) { i, session in
                TabChip(session: session,
                        bleedsUnderSidebar: bleedsUnderSidebar && i == 0,
                        paneMap: maps[session.id],
                        groupPosition: i == 0 ? .first : (i == members.count - 1 ? .last : .middle))
            }
        }
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

/// The sliver of tab strip that shows through the sidebar's rounded top-right corner: a
/// `radiusPanel` square with the corner's own arc subtracted, filled even-odd.
///
/// The first tab used to bleed a plain rectangle under the sidebar and let an opaque sidebar hide
/// all but this wedge. The sidebar is a translucent tint now (`Theme.sidebarStep`), so it hides
/// nothing — unmasked, that rectangle read as a bright block in the sidebar's corner. The square is
/// only as tall as the radius for the same reason: below the arc the sidebar's edge runs straight,
/// so there is no gap left to fill.
struct SidebarCornerWedge: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        // The corner's arc, centred on the square's bottom-leading corner with the square's radius.
        path.addPath(Path(ellipseIn: CGRect(x: rect.minX - rect.width, y: rect.minY,
                                            width: rect.width * 2, height: rect.height * 2)))
        return path
    }
}
