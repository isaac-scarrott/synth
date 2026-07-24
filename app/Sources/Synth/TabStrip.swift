import SwiftUI

/// The experimental Tabs view mode's content strip (working.html `renderContentTabStrip`).
///
/// ONE strip per branch — never one per pane — the horizontal twin of the sidebar's session
/// rows (`renderSidebarEcho`). It mirrors the current branch's sessions in sidebar order; the
/// sessions in the on-screen split bond into a contiguous **cluster** placed where their first
/// member sits, exactly as the sidebar draws a split as a bonded band. The pane-tree spine
/// (ADR-0014) is unchanged — a leaf still binds one session; the strip is pure presentation over
/// the existing `open` / stash model. Only shown while `store.tabsMode` (ContentPane gates it).
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
                switch item {
                case let .tab(s): TabChip(session: s)
                case let .cluster(members): TabCluster(members: members)
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
        .background(Theme.panel)
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
/// a hover-revealed close. Active (== the open session) lifts on a raised fill with the focus bar,
/// echoing the active-pane bar (working.html `.tab` / `.tab--active`).
private struct TabChip: View {
    @Environment(AppStore.self) private var store
    let session: Session
    @State private var hovering = false

    private var isActive: Bool { store.openSessionID == session.id }

    var body: some View {
        HStack(spacing: 6) {
            TabIcon(session: session, ring: isActive ? Theme.raised : Theme.panel)
            Text(session.title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isActive ? Theme.inkOpen : Theme.inkMuted)
                .lineLimit(1).truncationMode(.tail)
            indicator
            TabCloseButton(session: session, visible: hovering || isActive)
        }
        .padding(.leading, 11).padding(.trailing, 6)
        .frame(minWidth: 40, maxWidth: 190)
        .frame(maxHeight: .infinity)
        .background(isActive ? Theme.raised : (hovering ? Theme.rowHover : Color.clear))
        .overlay(alignment: .trailing) { Rectangle().fill(Theme.border).frame(width: 0.5) }
        // The active-tab bar, echoing the active-pane focus bar.
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
        .onHover { hovering = $0 }
        .onTapGesture { store.open(session); focusContent(store) }
        .tabDrag(session)
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

/// The session icon with a quiet blue unread dot at its top-right — coexists with an owned browser's
/// owner-mark in the indicator slot, and survives inside a cluster (working.html only suppresses the
/// cluster's status slot, not the unread dot: `.tab--unread .tab__icon::after` vs `.tab-group .tab__ind`).
private struct TabIcon: View {
    let session: Session
    var size: CGFloat = 14
    var ring: Color = Theme.panel
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
    }
}

private struct TabCloseButton: View {
    @Environment(AppStore.self) private var store
    let session: Session
    let visible: Bool
    @State private var hovering = false

    var body: some View {
        // × closes through the same confirm/close path as ⌘D (confirms while busy).
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

// MARK: - Bonded cluster (an on-screen split)

/// The on-screen split's member tabs bonded into one unit — the horizontal echo of the sidebar's
/// split band (ADR-0005/012): rounded chips on a raised fill with a hairline ring, a small gap
/// between, the active member accent-ringed (working.html `.tab-group`).
private struct TabCluster: View {
    let members: [Session]
    var body: some View {
        HStack(spacing: 3) {
            ForEach(members) { ClusterChip(session: $0) }
        }
        .padding(.horizontal, 5)
    }
}

private struct ClusterChip: View {
    @Environment(AppStore.self) private var store
    let session: Session
    @State private var hovering = false

    private var isActive: Bool { store.openSessionID == session.id }

    var body: some View {
        HStack(spacing: 5) {
            // Cluster keeps the unread dot (only the status slot is dropped), and the active member
            // is marked by the accent ring alone — no bold, matching the sidebar's split band.
            TabIcon(session: session, size: 13, ring: Theme.raised)
            Text(session.title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isActive ? Theme.inkOpen : Theme.inkMuted)
                .lineLimit(1).truncationMode(.tail)
            TabCloseButton(session: session, visible: hovering || isActive)
        }
        .padding(.leading, 9).padding(.trailing, 4)
        .frame(height: 22)
        .background(RoundedRectangle(cornerRadius: 7)
            .fill(isActive ? Theme.accent.opacity(0.12) : Theme.raised))
        // Copper pair-to ring while a dragged tab hovers this member's centre (012); else the
        // active member is accent-ringed, the rest hairline.
        .overlay(RoundedRectangle(cornerRadius: 7)
            .strokeBorder(store.pairTargetID == session.id ? Theme.accent.opacity(0.7)
                          : (isActive ? Theme.accent.opacity(0.34) : Theme.line),
                          lineWidth: store.pairTargetID == session.id ? 1.5 : 1))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { store.open(session); focusContent(store) }
        .tabDrag(session)
        .help(session.title)
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

    func body(content: Content) -> some View {
        content
            .background(GeometryReader { g in
                Color.clear
                    .onAppear { store.sessionRowFrames[session.id] = g.frame(in: .global) }
                    .onChange(of: g.frame(in: .global)) { _, f in store.sessionRowFrames[session.id] = f }
                    .onDisappear { store.sessionRowFrames[session.id] = nil }
            })
            .opacity(dragging ? 0.4 : 1)
            .highPriorityGesture(drag)
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
