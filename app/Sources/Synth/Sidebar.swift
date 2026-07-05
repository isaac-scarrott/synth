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
            if case .active = phase { store.keyboardActive = false }
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
                    .padding(.horizontal, 8)
                    .padding(.bottom, 16)
                }
                .onChange(of: store.navCursor) { _, id in
                    guard let id else { return }
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id, anchor: .center) }
                }
                // A reorder (drag step or ⇧J/⇧K) keeps the cursor on the same row, so navCursor
                // doesn't change — bump a nonce to keep the moving row in view instead.
                .onChange(of: store.reorderScrollNonce) { _, _ in
                    guard let id = store.draggingRowID ?? store.navCursor else { return }
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
    }

    private var topStrip: some View {
        HStack {
            Spacer()
            IconButton(path: Phosphor.sidebar, help: "Collapse sidebar") {
                store.sidebarCollapsed = true
            }
        }
        .padding(.horizontal, 10)
        // Toggle sits high in the strip so its center lines up with the window's
        // traffic lights (top-left control zone).
        .frame(height: 44, alignment: .top)
        .padding(.top, 1)
    }

    private var header: some View {
        HStack {
            Text("WORKSPACE")
                .font(.system(size: 10.5, weight: .semibold)).kerning(0.6)
                .foregroundStyle(Theme.navLabel)
            Spacer()
            IconButton(path: Phosphor.plus, size: 14, help: "Add workspace") {
                store.promptAddWorkspace()
            }
        }
        .padding(.horizontal, 14).padding(.bottom, 8)
    }
}

private struct EmptySidebarHint: View {
    var body: some View {
        VStack(spacing: 6) {
            Text("No workspaces yet")
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
            .padding(.horizontal, 8).padding(.top, 6).padding(.bottom, 10)
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
            .padding(.horizontal, 10).padding(.vertical, 7)
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
                Text("Workspaces")
                    .font(.system(size: 10.5, weight: .semibold)).kerning(0.5).textCase(.uppercase)
                    .foregroundStyle(Theme.navLabel)
                    .padding(.horizontal, 8).padding(.top, 10).padding(.bottom, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ForEach(store.workspaces) { ws in
                    ScopeRow(label: ws.name, workspace: ws,
                             on: store.settingsWorkspace?.id == ws.id, selected: selected(ws.id)) {
                        store.selectScope(.workspace(ws.id))
                    }
                }
            }
            .padding(.horizontal, 8).padding(.top, 8).padding(.bottom, 16)
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
                Text("Workspaces").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.repoName)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).padding(.vertical, 7)
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
        if on { return Color(hex: 0x0A84FF).opacity(hovering ? 0.09 : 0.06) }
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
            .padding(.horizontal, 8).padding(.vertical, 6)
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
                    .padding(.horizontal, 8).padding(.vertical, 6)
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
                        .padding(.horizontal, 8).padding(.vertical, 6)
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

            Reveal(open: isOpen) {
                VStack(alignment: .leading, spacing: 1) {
                    if workspace.branches.isEmpty {
                        EmptyGroupHint(text: "No worktrees yet")
                    } else {
                        ForEach(workspace.branches) { BranchRow(branch: $0, workspace: workspace) }
                    }
                }
                .padding(.leading, 18)
            }
        }
        .reorderLift(.workspace(workspace))
    }

    @ViewBuilder private var trailing: some View {
        if !isOpen {
            HStack(spacing: 6) {
                if let a = workspace.attention { AttentionGlyph(state: a) }
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
    @State private var hovering = false

    private var isOpen: Bool { store.expanded.contains(branch.id) }
    private var selected: Bool { store.keyboardActive && store.navCursor == branch.id }
    private var revealed: Bool { hovering || store.activeMenu?.rowID == branch.id }
    private var renaming: Bool { store.renamingRowID == branch.id }
    private var isActivePill: Bool {
        // The branch containing the open session — but an *expanded* group already
        // highlights the open session inside; the white header pill would
        // double-encode, so it shows only while collapsed (working.html
        // `.repo--open > .branch--active.branch--group`).
        guard let open = store.openSession, store.branch(of: open)?.id == branch.id else { return false }
        return !(branch.isLive && isOpen)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ZStack(alignment: .trailing) {
                if renaming {
                    HStack(spacing: 6) {
                        Chevron(open: isOpen)
                        RenameField(font: .system(size: 12, design: .monospaced))
                        Spacer(minLength: 4)
                    }
                    .padding(.leading, 10).padding(.trailing, 8).padding(.vertical, 5)
                } else {
                    Button {
                        focusSidebar()
                        store.toggleExpanded(branch.id)
                        store.navCursor = branch.id
                    } label: {
                        HStack(spacing: 6) {
                            Chevron(open: isOpen)
                            Text(branch.name)
                                .font(.system(size: 12, design: .monospaced))
                                .fontWeight(isActivePill ? .medium : .regular)
                                .foregroundStyle(isActivePill ? Theme.repoName : Theme.branchName)
                                .lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 4)
                            BranchRollup(branch: branch, collapsed: !isOpen).opacity(revealed ? 0 : 1)
                        }
                        // Right pad 10→8 so the branch indicator shares one vertical axis
                        // with the workspace count and session dots (working.html .branch).
                        .padding(.leading, 10).padding(.trailing, 8).padding(.vertical, 5)
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
            .help("\(branch.name) · \(branch.sessions.count) sessions")
            .id(branch.id)
            .reorderGesture(.branch(branch))

            Reveal(open: isOpen) {
                VStack(alignment: .leading, spacing: 1) {
                    if branch.sessions.isEmpty {
                        EmptyGroupHint(text: "No sessions yet")
                    } else {
                        ForEach(branch.sessions) { SessionRow(session: $0) }
                    }
                }
                .padding(.leading, 15)
                .overlay(alignment: .leading) {
                    Rectangle().fill(Theme.border).frame(width: 1)
                }
            }
        }
        .padding(.leading, 11)
        .overlay(alignment: .leading) {
            Rectangle().fill(Theme.border).frame(width: 1)
        }
        .reorderLift(.branch(branch))
    }

    @ViewBuilder private var activePillBackground: some View {
        if isActivePill {
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
    @State private var hovering = false
    // Ambient "done" wash: a background session settling to idle sweeps a soft highlight once
    // (working.html `session--pulse`). Bumping the store token starts a single 900ms fade.
    @State private var pulse = false

    private var selected: Bool { store.keyboardActive && store.navCursor == session.id }
    private var revealed: Bool { hovering || store.activeMenu?.rowID == session.id }
    private var isOpen: Bool { store.openSessionID == session.id }
    private var renaming: Bool { store.renamingRowID == session.id }

    private var nameColor: Color {
        if isOpen { return Theme.inkOpen }
        return session.unread ? Theme.sessionNameUnread : Theme.sessionName
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            if renaming {
                HStack(spacing: 8) {
                    Phos(path: session.kind.iconPath, size: 14)
                        .foregroundStyle(session.kind.tint).frame(width: 14)
                    RenameField(font: .system(size: 11.5))
                    Spacer(minLength: 4)
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
            } else {
                Button { store.open(session); focusContent(store) } label: {
                    HStack(spacing: 8) {
                        Phos(path: session.kind.iconPath, size: 14)
                            .foregroundStyle(session.kind.tint).frame(width: 14)
                        Text(session.title)
                            .font(.system(size: 11.5))
                            // Only the focused session goes bold; unread surfaces via colour
                            // + the gutter bullet, not weight (working.html .session--open).
                            .fontWeight(isOpen ? .semibold : .regular)
                            .foregroundStyle(nameColor)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        StatusIndicator(status: session.status).opacity(revealed ? 0 : 1)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    // The open session's sticky tint (working.html .session--open).
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(hex: 0x0A84FF).opacity(isOpen ? 0.06 : 0))
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(RowButtonStyle())
                // Unread bullet lives in the gutter (blue), not inline — no layout shift.
                .overlay(alignment: .leading) {
                    Circle().fill(Theme.attention).frame(width: 4, height: 4)
                        .opacity(session.unread ? 1 : 0)
                        .offset(x: -3)
                }

                KebabButton(ref: .session(session))
                    .opacity(revealed ? 1 : 0)
                    .padding(.trailing, 2)
            }
        }
        .rowChrome(hovering: hovering, selected: selected)
        // The pulse wash sits behind the row chrome (a soft one-shot sweep, not a standing tint).
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.attention.opacity(pulse ? 0.11 : 0)))
        .onHover { hovering = $0 }
        .help("\(session.title) · \(session.status.label)")
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
    var body: some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(Theme.inkFaint)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct KebabButton: View {
    @Environment(AppStore.self) private var store
    let ref: RowRef

    private var menuOpen: Bool { store.activeMenu?.rowID == ref.id }

    var body: some View {
        Button {
            // The ⋯ kebab opens the ⌘K palette drilled to this row (working.html openRowActions),
            // not the hover popover. The popover stays for the `d` quick-delete keybinding.
            store.openRowActions(ref)
        } label: {
            // 13px glyph in a 20px box; the open menu fills a rounded 7px hover box
            // (echoing the 8px row radius) and darkens the glyph (working.html .kebab).
            Phos(path: Phosphor.dots, size: 13)
                .foregroundStyle(menuOpen ? Theme.ink2 : Theme.inkFaint)
                .frame(width: 20, height: 20)
                .background(RoundedRectangle(cornerRadius: 7).fill(menuOpen ? Theme.rowSelected : .clear))
                .contentShape(Rectangle())
        }
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

private struct StatusIndicator: View {
    let status: SessionStatus
    var body: some View {
        Group {
            switch status {
            case .running: Dot(color: Theme.run, halo: true)
            // Idle and clean exit carry no liveness — a grey dot there is just noise, so
            // they show nothing. Unread still surfaces via the blue gutter bullet.
            case .idle, .exited: EmptyView()
            case .working: Dot(color: Theme.working, halo: true, haloOpacity: 0.16).sdotPulse()
            case .needsInput: AttentionGlyph(state: .input).attnBreathe()
            case .error:      AttentionGlyph(state: .error)
            }
        }
        .frame(width: 16, height: 16)
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
        Group {
            switch branch.rollup {
            case .input where collapsed: AttentionGlyph(state: .input).attnBreathe()
            case .error where collapsed: AttentionGlyph(state: .error)
            case .work  where collapsed: Dot(color: Theme.working, halo: true, haloOpacity: 0.16).sdotPulse()
            case .run   where collapsed: Dot(color: Theme.run, halo: true)
            // A live state while expanded: the sessions carry their own indicators,
            // so nothing rolls up to the header.
            case .input, .error, .work, .run: EmptyView()
            case .idle, .none:
                if !branch.lastActivity.isEmpty {
                    Text(branch.lastActivity)
                        .font(.system(size: 10.5)).foregroundStyle(Theme.branchMeta).monospacedDigit()
                }
            }
        }
        .frame(minWidth: 16, alignment: .trailing)
    }
}

private struct AttentionGlyph: View {
    let state: RollupState
    var body: some View {
        Phos(path: state == .input ? Phosphor.question : Phosphor.exclamation, size: 15)
            .foregroundStyle(state == .input ? Theme.attention : Theme.danger)
    }
}

private struct Dot: View {
    let color: Color
    var halo: Bool = false
    var haloOpacity: Double = 0.15
    var body: some View {
        Circle().fill(color).frame(width: 6, height: 6)
            .background(
                halo ? Circle().fill(color.opacity(haloOpacity)).frame(width: 11, height: 11) : nil
            )
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
        DragGesture(minimumDistance: 5)
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
                    .fill(Theme.attention)
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
                DragGesture(minimumDistance: 2)
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
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Phos(path: path, size: size)
                .foregroundStyle(hovering ? Theme.inkMuted : Theme.inkFaint)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 7).fill(hovering ? Theme.rowHover : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(IconPressStyle())
        .help(help)
        .onHover { hovering = $0 }
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
/// (185ms) plus the inner opacity fade. Content is always present and measured;
/// only its clipped height + opacity animate.
struct Reveal<Content: View>: View {
    let open: Bool
    @ViewBuilder var content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var natural: CGFloat = 0

    var body: some View {
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
            .animation(reduceMotion ? nil : .easeOut(duration: 0.185), value: open)
    }
}
