import SwiftUI
import AppKit

struct Sidebar: View {
    @Environment(AppStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            topStrip
            // Settings mode swaps the tree + foot for a scope list; the shell is otherwise
            // untouched (working.html `.app.settings`).
            if store.settingsOpen {
                SettingsNav()
            } else {
                header
                tree.frame(maxHeight: .infinity, alignment: .top)
                SidebarFoot()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        .onContinuousHover { phase in
            if case .active = phase, !store.pointerStale { store.keyboardActive = false }
        }
    }

    @ViewBuilder private var tree: some View {
        if store.workspaces.isEmpty {
            EmptySidebarHint()
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(store.workspaces) { WorkspaceRow(workspace: $0) }
                    }
                    // 10pt side gutter floats the row pills off the edge; rows are full-width so
                    // the hover band spans the sidebar, with depth as per-row leading padding.
                    .padding(.horizontal, 10)
                    .padding(.top, 6)
                    .padding(.bottom, 14)
                }
                // nil anchor = working.html's scrollIntoView({block:'nearest'}): no scroll at
                // all while the cursor moves within view — also what keeps arrow-key nav cheap
                // in a tree of hundreds of rows (centering scrolls the LazyVStack every press).
                .onChange(of: store.navCursor) { _, id in
                    guard let id else { return }
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) }
                }
                // A reorder (drag step or ⇧J/⇧K) keeps the cursor on the same row, so navCursor
                // doesn't change — bump a nonce to keep the moving row in view instead.
                .onChange(of: store.reorderScrollNonce) { _, _ in
                    guard let id = store.draggingRowID ?? store.navCursor else { return }
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) }
                }
            }
        }
    }

    private var topStrip: some View {
        HStack {
            Spacer()
            SidebarToggle()
        }
        // 10pt trailing pad lands the 28pt toggle on the sidebar's control axis, 24pt in from
        // the trailing edge — where the header's `+` and every row's status indicator sit too.
        .padding(.horizontal, 10)
        .frame(height: Theme.titlebarHeight)
    }

    private var header: some View {
        HStack {
            Text("PROJECT")
                .font(.system(size: 10.5, weight: .semibold)).kerning(0.6)
                .foregroundStyle(Theme.navLabel)
            Spacer()
            IconButton(path: Phosphor.plus, size: 14, help: "Add project") {
                store.promptAddWorkspace()
            }
        }
        // 11pt trailing pad puts the 26pt `+` on that same 24pt axis; 16pt leading aligns the
        // label with the workspace row content column (10pt gutter + 6pt row pad).
        .padding(.leading, 16).padding(.trailing, 11).padding(.bottom, 6)
    }
}

private struct EmptySidebarHint: View {
    var body: some View {
        VStack(spacing: 6) {
            Text("No projects yet")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.inkMuted)
            Text("Click + to add a git repository")
                .font(.system(size: 11))
                .foregroundStyle(Theme.inkFaint)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20).padding(.top, 40)
        Spacer()
    }
}

// MARK: - Sidebar foot (Settings entry) + settings-mode scope list

/// working.html `.sidebar__foot` — pinned to the bottom of the left panel.
private struct SidebarFoot: View {
    @Environment(AppStore.self) private var store
    // The foot button is the last row of the main-view navigable list, so it shows the
    // same keyboard selection ring as a tree row when the cursor rests on it (F5).
    private var selected: Bool { store.keyboardActive && store.navCursor == NavID.settingsFoot }
    var body: some View {
        FootButton(icon: Phosphor.gear, title: "Settings", selected: selected) { store.enterSettings() }
            .padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 10)
            .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 0.5) }
    }
}

private struct FootButton: View {
    let icon: String
    let title: String
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Phos(path: icon, size: 16)
                    .foregroundStyle(hovering ? Theme.inkMuted : Theme.navLabel).frame(width: 16)
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(hovering ? Theme.repoName : Theme.branchName)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6).padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle())
        .rowChrome(hovering: hovering, selected: selected)
        .onHover { hovering = $0 }
    }
}

/// working.html `.settings-nav` — the left panel in settings mode: a Back button back
/// to the tree, then Global + one scope row per workspace.
private struct SettingsNav: View {
    @Environment(AppStore.self) private var store
    // Whether the keyboard cursor sits on a given settings-nav target — the same ring the
    // tree rows use, now shared across the scope list (F5).
    private func selected(_ id: UUID) -> Bool { store.keyboardActive && store.navCursor == id }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                BackButton(selected: selected(NavID.back)) { store.exitSettings() }
                    .padding(.bottom, 6)
                ScopeRow(label: "Global", on: store.settingsIsGlobal, selected: selected(NavID.scopeGlobal)) {
                    store.selectScope(.global)
                }
                Text("Projects")
                    .font(.system(size: 10.5, weight: .semibold)).kerning(0.5).textCase(.uppercase)
                    .foregroundStyle(Theme.navLabel)
                    .padding(.horizontal, 6).padding(.top, 10).padding(.bottom, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ForEach(store.workspaces) { ws in
                    ScopeRow(label: ws.name, workspace: ws,
                             on: store.settingsWorkspace?.id == ws.id, selected: selected(ws.id)) {
                        store.selectScope(.workspace(ws.id))
                    }
                }
            }
            .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 14)
        }
        .frame(maxHeight: .infinity)
    }
}

private struct BackButton: View {
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Phos(path: Phosphor.back, size: 17).foregroundStyle(Theme.inkMuted).frame(width: 17)
                Text("Projects").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.repoName)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6).padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle())
        .rowChrome(hovering: hovering, selected: selected)
        .onHover { hovering = $0 }
    }
}

/// One row in the scope list — Global (globe) or a workspace (chip). The selected scope
/// gets the blue "you are here" tint (working.html `.scope--on`).
private struct ScopeRow: View {
    let label: String
    var workspace: Workspace? = nil
    let on: Bool
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    // The keyboard ring wins over the blue "you are here" tint (working.html: `.scope.sel`
    // outweighs `.scope--on`), so a selected scope reads as the cursor first.
    private var background: Color {
        if selected { return Theme.rowSelected }
        if on { return Theme.input.opacity(hovering ? 0.14 : 0.10) }
        return hovering ? Theme.rowHover : .clear
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Group {
                    if let workspace { WsChip(workspace: workspace, size: 19) }
                    else { Phos(path: Phosphor.globe, size: 16).foregroundStyle(Theme.inkMuted) }
                }
                .frame(width: 20, height: 20)
                Text(label)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(on ? Theme.repoName : Theme.ink3)
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(background))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Theme.selRing, lineWidth: 1.5)
                    .opacity(selected ? 1 : 0)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle())
        .onHover { hovering = $0 }
    }
}

// MARK: - Workspace (tier 1)

private struct WorkspaceRow: View {
    @Environment(AppStore.self) private var store
    let workspace: Workspace
    @State private var hovering = false

    private var isOpen: Bool { store.expanded.contains(workspace.id) }
    private var selected: Bool { store.keyboardActive && store.navCursor == workspace.id }
    private var menuOpen: Bool { store.activeMenu?.rowID == workspace.id }
    private var revealed: Bool { hovering || menuOpen }
    private var renaming: Bool { store.renamingRowID == workspace.id }
    /// Focus peek: while collapsed, the branch holding the open session still shows —
    /// just that branch, nothing else (working.html `.collapse:has(.session--open)`).
    private var peekBranchID: UUID? {
        guard !isOpen, let open = store.openSession, let br = store.branch(of: open),
              store.workspace(of: br)?.id == workspace.id else { return nil }
        return br.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ZStack(alignment: .trailing) {
                if renaming {
                    HStack(spacing: 8) {
                        Chevron(open: isOpen)
                        Monogram(text: workspace.monogram,
                                 color: Theme.chipColors[workspace.colorIndex % Theme.chipColors.count])
                        RenameField(font: .system(size: 13, weight: .semibold))
                        Spacer(minLength: 4)
                    }
                    .padding(.horizontal, 6).padding(.vertical, 6)
                } else {
                    Button {
                        focusSidebar()
                        store.toggleExpanded(workspace.id)
                        store.navCursor = workspace.id
                    } label: {
                        HStack(spacing: 8) {
                            Chevron(open: isOpen)
                            Monogram(text: workspace.monogram,
                                     color: Theme.chipColors[workspace.colorIndex % Theme.chipColors.count])
                            Text(workspace.name)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Theme.repoName)
                            Spacer(minLength: 4)
                            trailing.opacity(revealed ? 0 : 1)
                        }
                        .padding(.horizontal, 6).padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(RowButtonStyle())

                    KebabButton(ref: .workspace(workspace))
                        .opacity(revealed ? 1 : 0)
                        .padding(.trailing, 2)
                }
            }
            .rowChrome(hovering: hovering, selected: selected)
            .onHover { hovering = $0 }
            .help("\(workspace.name) · \(workspace.branches.count) branches")
            .id(workspace.id)
            .reorderGesture(.workspace(workspace))

            Reveal(open: isOpen || peekBranchID != nil) {
                VStack(alignment: .leading, spacing: 1) {
                    if workspace.branches.isEmpty {
                        EmptyGroupHint(text: "No worktrees yet", leading: 37)
                    } else {
                        // Peeking a collapsed workspace shows only the branch that holds the
                        // open session; expanded, every branch shows.
                        // `selected` computed here, passed as a plain value: a cursor move
                        // then re-evaluates only the two rows whose value flipped, not every
                        // row body in the tree (hundreds, at scale).
                        ForEach(peekBranchID.map { id in workspace.branches.filter { $0.id == id } }
                                ?? workspace.branches) {
                            BranchRow(branch: $0, workspace: workspace,
                                      selected: store.keyboardActive && store.navCursor == $0.id)
                        }
                    }
                }
            }
        }
        .reorderLift(.workspace(workspace))
    }

    @ViewBuilder private var trailing: some View {
        if !isOpen {
            HStack(spacing: 8) {
                // .id(a) — a single branch hosts both states here, so force a fresh
                // slot identity on input↔error swaps to replay the entry pop.
                if let a = workspace.attention { Ind { AttentionGlyph(state: a) }.id(a) }
                Text("\(workspace.branches.count)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.repoCount).monospacedDigit()
            }
        }
    }
}

// MARK: - Branch (tier 2)

private struct BranchRow: View {
    @Environment(AppStore.self) private var store
    let branch: Branch
    let workspace: Workspace
    /// Computed by the parent (see WorkspaceRow) so cursor moves don't touch this body.
    let selected: Bool
    @State private var hovering = false

    private var isOpen: Bool { store.expanded.contains(branch.id) }
    private var revealed: Bool { hovering || store.activeMenu?.rowID == branch.id }
    private var renaming: Bool { store.renamingRowID == branch.id }
    /// Focus peek: while collapsed, the open session it holds still shows — just that one
    /// session, nothing else (working.html `.collapse:has(.session--open)`).
    private var peeking: Bool {
        !isOpen && store.openSession.map { store.branch(of: $0)?.id == branch.id } == true
    }
    private var isActivePill: Bool {
        // Its own setup skeleton is what the content pane is showing — highlight the row
        // so the still-grayed pending pill still reads as "this is the one you're on".
        if store.openSetupBranchID == branch.id { return true }
        // The branch containing the open session carries the active-name colour whenever
        // it's collapsed; the white header pill on top of that is gated separately (see
        // activePillBackground) so a peeked session doesn't double-encode.
        guard let open = store.openSession, store.branch(of: open)?.id == branch.id else { return false }
        return !(branch.isLive && isOpen)
    }
    /// The active-group label goes bold only when it is the *sole* focus cue. Once its open
    /// session shows below — expanded (all sessions) or peeking while collapsed (that one) —
    /// the bold session carries the focus, so bolding the label too would double-encode. Only a
    /// group with nothing to peek (a pending setup) keeps the bold (working.html
    /// `.repo:not(.repo--open):has(> .collapse .session--open) > .branch--active`).
    private var boldName: Bool { isActivePill && !peeking }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ZStack(alignment: .trailing) {
                if renaming {
                    HStack(spacing: 6) {
                        Chevron(open: isOpen)
                        RenameField(font: .system(size: 12, design: .monospaced))
                        Spacer(minLength: 4)
                    }
                    .padding(.leading, 37).padding(.trailing, 6).padding(.vertical, 7)
                } else {
                    Button {
                        guard !branch.isPending else { return }   // nothing to expand or open yet
                        focusSidebar()
                        store.toggleExpanded(branch.id)
                        store.navCursor = branch.id
                    } label: {
                        HStack(spacing: 6) {
                            Chevron(open: isOpen)
                            Text(branch.name)
                                .font(.system(size: 12, design: .monospaced))
                                .fontWeight(boldName ? .semibold : .medium)
                                .foregroundStyle(isActivePill ? Theme.repoName : Theme.branchName)
                                .lineLimit(1).truncationMode(.middle)
                            // The branch's PR rides beside the name — identity, not status, so it
                            // stays clear of the roll-up's reserved right axis. Colour is the state.
                            if let pr = branch.pr {
                                Phos(path: pr.state.glyph, size: 11)
                                    .foregroundStyle(pr.state.tint)
                                    .help(Text(verbatim: "PR #\(pr.number) · \(pr.state.rawValue.lowercased())"))
                            }
                            Spacer(minLength: 4)
                            if branch.isPending {
                                Ind { PendingSpinner() }
                            } else {
                                BranchRollup(branch: branch, collapsed: !isOpen).opacity(revealed ? 0 : 1)
                            }
                        }
                        // Full-width row: 37pt leading holds the branch content at its indent
                        // while the hover band spans the sidebar; 6pt trailing keeps the branch
                        // indicator on the shared 24pt axis (working.html .nav .branch).
                        .padding(.leading, 37).padding(.trailing, 6).padding(.vertical, 7)
                        // The worktree is still materialising — the row is present but not
                        // yet actionable, and reads that way (grayed + spinner).
                        .opacity(branch.isPending ? 0.5 : 1)
                        .background(activePillBackground)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(RowButtonStyle())

                    KebabButton(ref: .branch(branch))
                        .opacity(revealed ? 1 : 0)
                        .padding(.trailing, 2)
                }
            }
            .rowChrome(hovering: hovering, selected: selected)
            .onHover { hovering = $0 }
            .help(branch.isPending ? "\(branch.name) · creating worktree…"
                                   : "\(branch.name) · \(branch.sessions.count) sessions")
            .id(branch.id)
            .reorderGesture(.branch(branch))

            Reveal(open: isOpen || peeking) {
                VStack(alignment: .leading, spacing: 1) {
                    if branch.sessions.isEmpty {
                        EmptyGroupHint(text: "No sessions yet", leading: 61)
                    } else {
                        // Peeking a collapsed group shows only the open session; expanded,
                        // every session shows.
                        ForEach(peeking ? branch.sessions.filter { $0.id == store.openSessionID }
                                        : branch.sessions) {
                            SessionRow(session: $0,
                                       selected: store.keyboardActive && store.navCursor == $0.id)
                        }
                    }
                }
            }
        }
        .reorderLift(.branch(branch))
    }

    // The pill shows only when the active group's open session isn't visible below it: an
    // expanded group (isActivePill already false) and a collapsed group peeking that one
    // session both let the session carry the focus, so the pill would double-encode and read
    // as a stuck hover. Only a group with nothing to peek (a pending setup) keeps it. Mirrors
    // working.html dropping the pill for `.repo--open` and `.repo:not(.repo--open):has(.session--open)`.
    @ViewBuilder private var activePillBackground: some View {
        if isActivePill && !peeking {
            RoundedRectangle(cornerRadius: 8).fill(Theme.raised)
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border, lineWidth: 0.5))
                .shadow(color: .black.opacity(0.05), radius: 1, y: 1)
        }
    }
}

// MARK: - Session (tier 3)

private struct SessionRow: View {
    @Environment(AppStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let session: Session
    /// Computed by the parent (see BranchRow) so cursor moves don't touch this body.
    let selected: Bool
    @State private var hovering = false
    // Ambient "done" wash: a background session settling to idle sweeps a soft highlight once
    // (working.html `session--pulse`). Bumping the store token starts a single 900ms fade.
    @State private var pulse = false
    private var revealed: Bool { hovering || store.activeMenu?.rowID == session.id }
    private var isOpen: Bool { store.openSessionID == session.id }
    private var renaming: Bool { store.renamingRowID == session.id }

    private var nameColor: Color {
        if isOpen { return Theme.inkOpen }
        return session.unread ? Theme.sessionNameUnread : Theme.sessionName
    }

    // Owned browsers surface their tie in the tooltip too (working.html `.ind--owned` title).
    private var ownershipHelp: String {
        if let owner = session.ownerSessionID, let name = store.session(owner)?.title {
            return "\(session.title) · belongs to \(name)"
        }
        return "\(session.title) · \(session.status.label)"
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            if renaming {
                HStack(spacing: 8) {
                    SessionIcon(kind: session.kind, size: 14).frame(width: 14)
                    RenameField(font: .system(size: 11.5))
                    Spacer(minLength: 4)
                }
                .padding(.leading, 61).padding(.trailing, 6).padding(.vertical, 6)
            } else {
                Button { store.open(session); focusContent(store) } label: {
                    HStack(spacing: 8) {
                        SessionIcon(kind: session.kind, size: 14).frame(width: 14)
                        // The box always reserves the semibold width (hidden ghost), so the
                        // focus weight flip renders in place without nudging the row — the
                        // native mirror of working.html's flex:1 name box (.session--open).
                        Text(session.title)
                            .font(.system(size: 11.5, weight: .semibold))
                            .lineLimit(1)
                            .hidden()
                            .overlay(alignment: .leading) {
                                Text(session.title)
                                    .font(.system(size: 11.5))
                                    // Only the focused session goes bold; unread surfaces via
                                    // colour + the gutter bullet, not weight.
                                    .fontWeight(isOpen ? .semibold : .medium)
                                    .foregroundStyle(nameColor)
                                    .lineLimit(1)
                            }
                        Spacer(minLength: 4)
                        Group {
                            // The mark mirrors the OWNER's icon, so the tie names which agent.
                            if session.ownerSessionID != nil,
                               let owner = store.owner(of: session) {
                                OwnedIndicator(ownerKind: owner.kind)
                            } else if session.ownerSessionID != nil {
                                OwnedIndicator()
                            } else {
                                StatusIndicator(status: session.status)
                            }
                        }
                        .opacity(revealed ? 0 : 1)
                    }
                    .padding(.leading, 61).padding(.trailing, 6).padding(.vertical, 6)
                    // The open session's sticky tint (working.html .session--open), deepening
                    // on hover like every other accent wash.
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Theme.accent.opacity(isOpen ? (hovering ? 0.14 : 0.10) : 0))
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(RowButtonStyle())
                // Unread bullet lives in the gutter (blue), not inline — no layout shift.
                .overlay(alignment: .leading) {
                    Circle().fill(Theme.input).frame(width: 4, height: 4)
                        .opacity(session.unread ? 1 : 0)
                        // Row is full-width; sit the bullet in the icon gutter (just left of the
                        // 61pt-indented session icon), not at the row's leading edge.
                        .offset(x: 54.5)
                }

                KebabButton(ref: .session(session))
                    .opacity(revealed ? 1 : 0)
                    .padding(.trailing, 2)
            }
        }
        .rowChrome(hovering: hovering, selected: selected)
        // The pulse wash sits behind the row chrome (a soft one-shot sweep, not a standing tint).
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.run.opacity(pulse ? 0.11 : 0)))
        // Containment (ADR-0011 stage four, revised): an owned browser is NOT nested — it
        // stays a plain sibling on the shared indent; the accent sparkle in its indicator
        // slot carries the tie instead (working.html `.ind--owned`, no `.session--owned` indent).
        .onHover { hovering = $0 }
        .help(ownershipHelp)
        .id(session.id)
        .onChange(of: store.pulseTokens[session.id]) { _, _ in
            guard !reduceMotion else { return }
            pulse = true
            DispatchQueue.main.async { withAnimation(.easeOut(duration: 0.9)) { pulse = false } }
        }
        .reorderGesture(.session(session))
        .reorderLift(.session(session))
    }
}

// MARK: - Shared bits

/// An expanded group with no children reads as a quiet hint instead of a bare indent
/// (working.html `.sessions:empty::after` / `.branches:empty::after`). Sits at the same
/// left indent as a child row would, since it's rendered inside the group's Reveal.
private struct EmptyGroupHint: View {
    let text: String
    /// Leading indent so the hint aligns with the child rows it stands in for
    /// (37pt under a branch header, 61pt under a session group).
    var leading: CGFloat = 8
    var body: some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(Theme.inkFaint)
            .padding(.leading, leading).padding(.trailing, 6).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct KebabButton: View {
    @Environment(AppStore.self) private var store
    let ref: RowRef

    private var menuOpen: Bool { store.activeMenu?.rowID == ref.id }
    @State private var hovering = false

    var body: some View {
        let active = menuOpen || hovering
        Button {
            // The ⋯ kebab opens the ⌘K palette drilled to this row (working.html openRowActions),
            // not the hover popover. The popover stays for the `d` quick-delete keybinding.
            store.openRowActions(ref)
        } label: {
            // 13px glyph in a 20px box; hover / open menu fills a rounded 7px hover box
            // (echoing the 8px row radius) and darkens the glyph (working.html .kebab).
            Phos(path: Phosphor.dots, size: 13)
                .foregroundStyle(active ? Theme.ink2 : Theme.inkMeta)
                .frame(width: 20, height: 20)
                .background(RoundedRectangle(cornerRadius: 7).fill(active ? Theme.rowSelected : .clear))
                .contentShape(Rectangle())
        }
        .onHover { hovering = $0 }
        .buttonStyle(KebabPressStyle())
        .help("Actions")
        .anchorPreference(key: MenuAnchorKey.self, value: .bounds) { [id = ref.id] anchor in [id: anchor] }
    }
}

/// The name field shown in place of a row's label while it is being renamed —
/// working.html's contentEditable `.renaming`: the label becomes an editable field in
/// place with its text preselected and no ring of its own (the row's selection ring is
/// the only ring).
/// ↵/Esc are handled by the global key monitor; losing focus (blur) commits.
private struct RenameField: View {
    @Environment(AppStore.self) private var store
    let font: Font
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var store = store
        TextField("", text: $store.renameText)
            .textFieldStyle(.plain)
            .font(font)
            .foregroundStyle(Theme.repoName)
            .focused($focused)
            .onAppear {
                focused = true
                DispatchQueue.main.async {
                    (NSApp.keyWindow?.firstResponder as? NSTextView)?.selectAll(nil)
                }
            }
            .onChange(of: focused) { _, isFocused in if !isFocused { store.commitRename() } }
    }
}

/// working.html `.kebab:active` — a firm 0.88 press dip.
private struct KebabPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .animation(.easeOut(duration: 0.11), value: configuration.isPressed)
    }
}

private struct Chevron: View {
    let open: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Phos(path: Phosphor.caret, size: 12)
            .foregroundStyle(Theme.chevron)
            .rotationEffect(.degrees(open ? 90 : 0))
            .frame(width: 12)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: open)
    }
}

private struct Monogram: View {
    let text: String
    let color: Color
    var body: some View {
        RoundedRectangle(cornerRadius: 6).fill(color).frame(width: 19, height: 19)
            .overlay(Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.12), radius: 0.75, y: 1)
    }
}

/// working.html `.ind` — every right-side indicator lives in one fixed 16×16 slot,
/// contents centered, so every indicator shares one vertical axis down the whole
/// sidebar regardless of glyph size (6px dot, 15px `?`/`!`).
/// The slot pops in with a soft overshoot (ind-in, 240ms back-out) whenever it
/// appears or swaps state — a state swap lands as a new view identity (a different
/// switch branch, or `.id`) so the pop retriggers, like the HTML replacing the node.
private struct Ind<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false
    @ViewBuilder var content: Content

    var body: some View {
        content
            .scaleEffect(reduceMotion || shown ? 1 : 0.4)
            .opacity(reduceMotion || shown ? 1 : 0)
            // cubic-bezier(0.34,1.56,0.64,1) ≈ a lightly under-damped 240ms spring.
            .animation(reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.6), value: shown)
            .onAppear { shown = true }
            .frame(width: 16, height: 16)
    }
}

private struct StatusIndicator: View {
    let status: SessionStatus
    var body: some View {
        switch status {
        case .running: Ind { Dot(color: Theme.working) }
        // Idle and clean exit carry no liveness — a grey dot there is just noise, so
        // the slot stays empty (it still reserves its 16px so row height and the hover
        // swap hold steady). Unread still surfaces via the blue gutter bullet.
        case .idle, .exited: Ind { Color.clear }
        case .working: Ind { Dot(color: Theme.working) }
        case .needsInput: Ind { AttentionGlyph(state: .input) }
        case .error:      Ind { AttentionGlyph(state: .error) }
        }
    }
}

/// A browser owned by an agent session carries its OWNER'S mark in its indicator slot instead of
/// a liveness dot — the sidebar-visible tie that replaced the old containment indent
/// (working.html `.ind--owned`). It mirrors the owner's icon, so a browser owned by Claude Code
/// shows Clawd and one owned by OpenCode shows OpenCode's mark. Browsers are status-less, so this
/// only ever stands where a StatusIndicator's empty idle slot would be.
private struct OwnedIndicator: View {
    /// The owning row's kind; nil owner falls back to the generic agent glyph.
    var ownerKind: SessionKind = .agent(.claudeCode)

    var body: some View {
        Ind {
            SessionIcon(kind: ownerKind, size: 12)
                .opacity(0.9)
        }
    }
}

private struct BranchRollup: View {
    let branch: Branch
    // Expanded, every session shows its own indicator inside, so the state roll-up
    // glyph beside the header is redundant and can read as out of sync — drop it
    // while expanded (working.html `.repo--open > .branch--group .branch__roll .ind`).
    // The activity meta isn't an indicator and stays.
    var collapsed: Bool
    var body: some View {
        switch branch.rollup {
        case .input where collapsed: Ind { AttentionGlyph(state: .input) }
        case .error where collapsed: Ind { AttentionGlyph(state: .error) }
        case .work  where collapsed: Ind { Dot(color: Theme.working) }
        case .run   where collapsed: Ind { Dot(color: Theme.working) }
        // A live state while expanded: the sessions carry their own indicators,
        // so nothing rolls up to the header.
        case .input, .error, .work, .run: EmptyView()
        case .idle, .none:
            // Settled, but holding unread output: the collapsed roll-up is the only
            // cue there's something to read in here (working.html rollUpGroups unread
            // fallback). Expanded, each session's own gutter bullet carries it instead.
            if collapsed && branch.hasUnread {
                Ind { UnreadDot() }
            } else if !branch.lastActivity.isEmpty {
                Text(branch.lastActivity)
                    .font(.system(size: 10.5, weight: .medium)).foregroundStyle(Theme.branchMeta).monospacedDigit()
            }
        }
    }
}

private struct AttentionGlyph: View {
    let state: RollupState
    var body: some View {
        // Breathe lives on the glyph, not the slot, so it composes under the slot's
        // entry pop (working.html: attn-breathe on the svg inside .ind--input).
        let glyph = Phos(path: state == .input ? Phosphor.question : Phosphor.exclamation, size: 15)
            .foregroundStyle(state == .input ? Theme.input : Theme.danger)
        if state == .input { glyph.attnBreathe() } else { glyph }
    }
}

/// The pending row's indicator: a quiet 11px arc spinning in the shared 16px slot —
/// a worktree create in flight (features 2026-07-06).
private struct PendingSpinner: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spinning = false
    var body: some View {
        Circle()
            .trim(from: 0.12, to: 1)
            .stroke(Theme.inkFaint, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            .frame(width: 11, height: 11)
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .animation(reduceMotion ? nil : .linear(duration: 0.9).repeatForever(autoreverses: false),
                       value: spinning)
            .onAppear { spinning = true }
    }
}

/// working.html `.sdot` — 6px liveness dot with a colour-matched soft round glow;
/// the two blurred box-shadow layers map to two stacked SwiftUI shadows.
private struct Dot: View {
    let color: Color
    var body: some View {
        Circle().fill(color).frame(width: 6, height: 6)
            .shadow(color: color.opacity(0.55), radius: 1.5)
            .shadow(color: color.opacity(0.3), radius: 4)
    }
}

/// working.html `.udot` — a flat 6px blue dot, no glow (unlike the live `Dot`): the
/// collapsed roll-up cue for a settled branch holding unread output. Same blue as the
/// row's gutter bullet, so it reads as ambient "something to read", not liveness.
private struct UnreadDot: View {
    var body: some View {
        Circle().fill(Theme.input).frame(width: 6, height: 6)
    }
}

// Ambient pulse, reserved for genuine attention (needs-input / working).
private struct PulseModifier: ViewModifier {
    let halfDuration: Double
    let minOpacity: Double
    let minScale: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var on = false
    func body(content: Content) -> some View {
        content
            .opacity(reduceMotion ? 1 : (on ? 1 : minOpacity))
            .scaleEffect(reduceMotion ? 1 : (on ? 1 : minScale))
            .animation(reduceMotion ? nil : .easeInOut(duration: halfDuration).repeatForever(autoreverses: true), value: on)
            .onAppear { on = true }
    }
}

extension View {
    // sdot--work: 1.5s cycle, opacity 1↔0.4, no scale.
    func sdotPulse() -> some View { modifier(PulseModifier(halfDuration: 0.75, minOpacity: 0.4, minScale: 1)) }
    // attn-breathe: 2s cycle, opacity 1↔0.55 + scale 1↔0.9.
    func attnBreathe() -> some View { modifier(PulseModifier(halfDuration: 1.0, minOpacity: 0.55, minScale: 0.9)) }

    /// Row hover + keyboard-selection chrome (working.html: hover 3.5%, sel 5% + ring).
    func rowChrome(hovering: Bool, selected: Bool) -> some View {
        background(
            RoundedRectangle(cornerRadius: 8)
                .fill(selected ? Theme.rowSelected : (hovering ? Theme.rowHover : .clear))
        )
        // Inset (strokeBorder) so the ring paints inside the row's bounds — a nested row
        // sits inside Reveal's .clipped() accordion, which would shave an outset ring.
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Theme.selRing, lineWidth: 1.5)
                .opacity(selected ? 1 : 0)
        )
    }
}

// MARK: - Drag-to-reorder (F2)

extension View {
    /// Hosts the reorder drag on a row's *header* (never its child rows), and measures the
    /// header height that sizes each reorder step. A ~5px threshold keeps a plain click
    /// opening/toggling the row (working.html's press-vs-drag threshold).
    func reorderGesture(_ ref: RowRef) -> some View { modifier(ReorderGesture(ref: ref)) }
    /// Lifts the whole row while it's the drag source: it tracks the pointer, elevates with
    /// a shadow, and rises above its siblings, which shift underneath it.
    func reorderLift(_ ref: RowRef) -> some View { modifier(ReorderLift(ref: ref)) }
}

private struct ReorderGesture: ViewModifier {
    @Environment(AppStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let ref: RowRef
    @State private var dragging = false
    @State private var consumed: CGFloat = 0   // translation already turned into steps
    @State private var pitch: CGFloat = 30      // header height + inter-row gap

    func body(content: Content) -> some View {
        content
            .background(
                GeometryReader { g in
                    Color.clear
                        .onAppear { pitch = g.size.height + 1 }
                        .onChange(of: g.size.height) { _, h in if !dragging { pitch = h + 1 } }
                }
            )
            .highPriorityGesture(drag)
    }

    private var drag: some Gesture {
        // .global: the gesture view moves with the drag (ReorderLift's offset + slot hops),
        // so local-space translation would lag the pointer and double-count each hop.
        DragGesture(minimumDistance: 5, coordinateSpace: .global)
            .onChanged { v in
                if !dragging {
                    dragging = true
                    consumed = 0
                    store.keyboardActive = false
                    store.navCursor = ref.id
                    store.draggingRowID = ref.id
                }
                let p = max(pitch, 1)
                var net = v.translation.height - consumed
                // Cross a sibling's midpoint → hop one slot; loop so a fast flick catches up,
                // and stops on its own when moveWithinSiblings hits a list edge.
                while net > p / 2, store.moveWithinSiblings(ref, by: 1, animated: !reduceMotion) {
                    consumed += p; net -= p
                }
                while net < -p / 2, store.moveWithinSiblings(ref, by: -1, animated: !reduceMotion) {
                    consumed -= p; net += p
                }
                store.dragOffset = v.translation.height - consumed
            }
            .onEnded { _ in
                dragging = false
                consumed = 0
                store.dragOffset = 0
                store.draggingRowID = nil
                store.saveNow()   // persist the dropped order
            }
    }
}

private struct ReorderLift: ViewModifier {
    @Environment(AppStore.self) private var store
    let ref: RowRef
    private var dragged: Bool { store.draggingRowID == ref.id }

    func body(content: Content) -> some View {
        content
            .offset(y: dragged ? store.dragOffset : 0)
            .scaleEffect(dragged ? 1.015 : 1)
            .shadow(color: .black.opacity(dragged ? 0.22 : 0),
                    radius: dragged ? 12 : 0, y: dragged ? 8 : 0)
            .zIndex(dragged ? 1 : 0)
            // The lifted row tracks the pointer 1:1 — its own reorder-driven position change
            // must not animate, while its siblings still shift under the withAnimation reorder.
            .transaction { t in if dragged { t.animation = nil } }
    }
}

/// Draggable seam on the sidebar's trailing edge (working.html's `.resize-handle`):
/// drag resizes within [min,max]; double-click resets to the default width. The width
/// tracks instantly (no animation) so the drag feels direct.
struct SidebarResizeHandle: View {
    @Environment(AppStore.self) private var store
    @State private var startWidth: CGFloat?
    @State private var hovering = false

    private var active: Bool { startWidth != nil }

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: 10)
            .contentShape(Rectangle())
            .overlay {
                Rectangle()
                    .fill(Theme.input)
                    .frame(width: 1.5)
                    .opacity(active ? 0.7 : (hovering ? 0.5 : 0))
                    .animation(.easeOut(duration: 0.12), value: hovering)
            }
            .offset(x: 5)   // straddle the sidebar/content seam
            .onHover { h in
                hovering = h
                if h { NSCursor.resizeLeftRight.set() } else { NSCursor.arrow.set() }
            }
            .highPriorityGesture(
                // .global: the handle rides the sidebar edge it resizes, so local-space
                // translation would feed back and track the cursor at half speed.
                DragGesture(minimumDistance: 2, coordinateSpace: .global)
                    .onChanged { v in
                        let base = startWidth ?? store.sidebarWidth
                        if startWidth == nil { startWidth = base }
                        store.sidebarWidth = min(Theme.sidebarMaxWidth,
                                                 max(Theme.sidebarMinWidth, base + v.translation.width))
                    }
                    .onEnded { _ in startWidth = nil }
            )
            .onTapGesture(count: 2) { store.sidebarWidth = Theme.sidebarWidth }
    }
}

/// Release the terminal's first-responder status so the global key monitor drives
/// sidebar navigation instead of the shell.
@MainActor func focusSidebar() {
    NSApp.keyWindow?.makeFirstResponder(nil)
}

/// Move focus into the content pane: make the open session's terminal first responder
/// so the shell takes keys (working.html's focusContent). An AI session has no terminal
/// yet, so this is a no-op there for now — the composer is a forward-looking fallback.
/// A browser session focuses its engine view (the page takes keys).
@MainActor func focusContent(_ store: AppStore) {
    store.keyboardActive = false
    guard let id = store.openSessionID else { return }
    if let view = TerminalManager.shared.existingView(id) {
        NSApp.keyWindow?.makeFirstResponder(view)
    } else if let ctrl = BrowserManager.shared.existing(id) {
        NSApp.keyWindow?.makeFirstResponder(ctrl.engine.view)
    }
}

/// The mock's `.icon-btn`: 26×26, radius 7, hover 5% bg, press scale 0.94.
struct IconButton: View {
    let path: String
    var size: CGFloat = 15
    var box: CGFloat = 26
    var corner: CGFloat = 7
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Phos(path: path, size: size)
                .foregroundStyle(hovering ? Theme.inkMuted : Theme.inkFaint)
                .frame(width: box, height: box)
                .background(RoundedRectangle(cornerRadius: corner).fill(hovering ? Theme.rowHover : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(IconPressStyle())
        .help(help)
        .onHover { hovering = $0 }
    }
}

/// The sidebar collapse/expand toggle (working.html `.icon-btn`) — the one control that lives in
/// the titlebar band, so it is the roomier 28pt box rather than the 26pt one the `+` in the
/// workspace header uses. Every header hosts the same button, hence one view for all of them.
struct SidebarToggle: View {
    /// Callers centring the toggle in the band need its box size.
    static let box: CGFloat = 28

    @Environment(AppStore.self) private var store

    var body: some View {
        IconButton(path: Phosphor.sidebar, size: 17, box: Self.box, corner: 8,
                   help: store.sidebarCollapsed ? "Expand sidebar" : "Collapse sidebar") {
            store.sidebarCollapsed.toggle()
        }
    }
}

struct IconPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.11), value: configuration.isPressed)
    }
}

struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Theme.rowHover : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Height-accordion reveal — matches working.html's 0fr→1fr grid-rows transition
/// (185ms) plus the inner opacity fade. Content only exists while the group is open
/// (or still collapsing): a tree of collapsed workspaces costs nothing per row, which
/// is what keeps a sidebar of hundreds of branches instant. Opening mounts the content
/// at height 0 and animates to its measured height; closing animates shut, then
/// unmounts once the accordion has finished.
struct Reveal<Content: View>: View {
    let open: Bool
    @ViewBuilder var content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var natural: CGFloat = 0
    @State private var present: Bool
    /// Generation stamp for the deferred unmount: any open-state flip after the close
    /// invalidates the pending unmount (a quick reopen must not tear content down).
    @State private var generation = 0

    init(open: Bool, @ViewBuilder content: () -> Content) {
        self.open = open
        self.content = content()
        _present = State(initialValue: open)
    }

    var body: some View {
        ZStack {   // stable container so onChange fires even while content is unmounted
            // `open` mounts in the same render pass as the expand (a palette jump expands
            // and scrolls to a row in one tick); `present` keeps it through the collapse.
            if open || present {
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        GeometryReader { geo in
                            Color.clear
                                .onAppear { natural = geo.size.height }
                                .onChange(of: geo.size.height) { _, h in natural = h }
                        }
                    )
                    .frame(height: open ? natural : 0, alignment: .top)
                    .opacity(open ? 1 : 0)
                    .clipped()
                    // `natural` lands one pass after mount, so the expand animates via its
                    // own value; `open` drives the collapse as before.
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.185), value: open)
                    .animation(reduceMotion || !open ? nil : .easeOut(duration: 0.185), value: natural)
            }
        }
        .onChange(of: open) { _, isOpen in
            generation += 1
            if isOpen {
                present = true
            } else if reduceMotion {
                present = false
                natural = 0
            } else {
                let gen = generation
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(220))
                    if generation == gen { present = false; natural = 0 }
                }
            }
        }
    }
}
