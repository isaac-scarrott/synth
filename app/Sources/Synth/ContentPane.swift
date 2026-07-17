import SwiftUI
import AppKit

/// Hosts a managed terminal NSView. The view is owned by TerminalManager (not created
/// here), so SwiftUI re-parenting it never restarts the shell.
struct TerminalHost: NSViewRepresentable {
    let terminal: GhosttySurfaceView

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        terminal.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(terminal)
        NSLayoutConstraint.activate([
            terminal.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            terminal.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            terminal.topAnchor.constraint(equalTo: container.topAnchor),
            terminal.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        // Focus the shell when a session is opened (this view is rebuilt per
        // session via .id). Not on every update — that would steal focus from
        // the sidebar and dialogs.
        DispatchQueue.main.async { container.window?.makeFirstResponder(terminal) }
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Collects every pane / split node's frame in the content coordinate space, so the keyboard's
/// spatial focus and resize can read real geometry (the native getBoundingClientRect).
struct PaneFramesKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] { [:] }
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

struct ContentPane: View {
    static let contentSpace = "synthContent"
    @Environment(AppStore.self) private var store

    var body: some View {
        Group {
            if store.settingsOpen {
                SettingsPane()
            } else if let root = store.layout {
                // The layout spine (009): render the pane tree. A lone leaf is byte-for-byte
                // today's single session; ≥2 leaves lay out as nested splits.
                PaneTreeView(node: root)
                    .coordinateSpace(name: Self.contentSpace)
                    // Each node reports its frame here; the keyboard's spatial focus + resize
                    // (Layout.swift) read real geometry from the store.
                    .onPreferenceChange(PaneFramesKey.self) { store.paneFrames = $0 }
            } else {
                PaneEmpty()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.panel)
        // In-app notification deck, bottom-left hugging the sidebar — hidden in settings
        // (working.html `.app.settings .notifs { display: none }`).
        .overlay(alignment: .bottomLeading) {
            if !store.settingsOpen { NotificationDeck() }
        }
    }
}

/// The layout spine render (009). Walks the pane tree into nested split containers; leaves render
/// as panes, siblings divided by a static 1px seam (drag-resize is 011). The single-pane case is
/// one leaf → identical to the old single-session output. working.html `renderNode`.
private struct PaneTreeView: View {
    @Environment(AppStore.self) private var store
    let node: PaneNode

    var body: some View {
        if node.isLeaf {
            // The ring is meaningful only inside a split, so a lone pane stays ringless (004 §4).
            LeafPane(node: node, inSplit: store.isSplit)
        } else {
            SplitContainer(node: node)
        }
    }
}

/// working.html `.split--row` / `.split--col`: two children sized by the node's fraction, a static
/// hairline seam between them. `dir` row = side by side, col = stacked. Child sizes are laid from
/// the container's measured length so nested splits divide their own space (min-0 flex in the mock).
private struct SplitContainer: View {
    let node: PaneNode
    private static let seam: CGFloat = 1

    var body: some View {
        GeometryReader { geo in
            let isRow = node.dir == .row
            let total = max(0, (isRow ? geo.size.width : geo.size.height) - Self.seam)
            let aLen = total * node.split
            let bLen = total - aLen
            if isRow {
                HStack(spacing: 0) {
                    PaneTreeView(node: node.a!).frame(width: aLen)
                    PaneSeam(node: node, total: total)
                    PaneTreeView(node: node.b!).frame(width: bLen)
                }
            } else {
                VStack(spacing: 0) {
                    PaneTreeView(node: node.a!).frame(height: aLen)
                    PaneSeam(node: node, total: total)
                    PaneTreeView(node: node.b!).frame(height: bLen)
                }
            }
        }
        // Report this split box's frame so resizeActive can measure the axis it clamps against.
        .background(GeometryReader { g in
            Color.clear.preference(key: PaneFramesKey.self,
                                   value: [node.id: g.frame(in: .named(ContentPane.contentSpace))])
        })
    }
}

/// working.html `.pane-seam` (011): the draggable inter-pane divider — reuses the sidebar
/// resize-handle idiom (1px hairline + a widened invisible grab band + a brighter 1.5px line on
/// hover / while dragging). Drag-only, no double-click reset. The drag rewrites `node.split` in
/// place — SwiftUI just resizes the sibling views, never re-mounting them, so live surfaces
/// survive — and clamps to the 360×240 floor (paneMinAlong); an over-subscribed split pins.
private struct PaneSeam: View {
    @Environment(AppStore.self) private var store
    let node: PaneNode
    let total: CGFloat
    @State private var hovering = false
    @State private var dragging = false
    @State private var startSplit: Double?

    private var isRow: Bool { node.dir == .row }

    var body: some View {
        ZStack {
            Rectangle().fill(Theme.border)
            Rectangle().fill(Theme.input)
                .frame(width: isRow ? 1.5 : nil, height: isRow ? nil : 1.5)
                .opacity(dragging ? 0.7 : (hovering ? 0.5 : 0))
                .animation(.easeInOut(duration: 0.14), value: hovering || dragging)
        }
        .frame(width: isRow ? 1 : nil, height: isRow ? nil : 1)
        // A 9px invisible grab band centred on the 1px line (working.html's ::before).
        .contentShape(Rectangle().inset(by: -4))
        .onHover { h in
            hovering = h
            if h { (isRow ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push() }
            else if !dragging { NSCursor.pop() }
        }
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named(ContentPane.contentSpace))
                .onChanged { v in
                    if startSplit == nil { startSplit = node.split; dragging = true }
                    guard total > 0, let start = startSplit, let a = node.a, let b = node.b,
                          let axis = node.dir else { return }
                    let moved = Double(isRow ? v.translation.width : v.translation.height) / Double(total)
                    let lo = Double(store.paneMinAlong(a, axis: axis)) / Double(total)
                    let hi = 1 - Double(store.paneMinAlong(b, axis: axis)) / Double(total)
                    if lo <= hi { node.split = min(hi, max(lo, start + moved)) }
                }
                .onEnded { _ in
                    startSplit = nil; dragging = false
                    if !hovering { NSCursor.pop() }
                    store.persistLayout()
                }
        )
    }
}

/// working.html `.pane`: one leaf hosting exactly one session (or a setup skeleton). Inside a
/// split it carries the active copper ring — living at zero alpha on every split pane and only
/// the active one lighting it, so a focus change cross-fades the copper (150ms) rather than
/// snapping (`.split .pane--active::after`). Clicking a pane body activates it in place, without
/// tearing down the live surface (working.html:2230 setActivePane).
private struct LeafPane: View {
    @Environment(AppStore.self) private var store
    let node: PaneNode
    let inSplit: Bool

    private var isActive: Bool { store.activePane === node }

    var body: some View {
        leafBody
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .contentShape(Rectangle())
            // Activate on click without consuming the event, so the terminal/browser/composer
            // still receives it (the mock's non-preventDefault content click).
            .simultaneousGesture(inSplit ? TapGesture().onEnded { store.setActivePane(node) } : nil)
            .overlay {
                if inSplit {
                    Rectangle()
                        .strokeBorder(Theme.copper, lineWidth: 2)
                        .opacity(isActive ? 0.85 : 0)
                        .animation(.easeOut(duration: 0.15), value: isActive)
                        .allowsHitTesting(false)
                }
            }
            // Report the pane's frame for the keyboard's spatial focus / resize.
            .background(GeometryReader { g in
                Color.clear.preference(key: PaneFramesKey.self,
                                       value: [node.id: g.frame(in: .named(ContentPane.contentSpace))])
            })
            // Keyboard focus follows the ring: when this pane becomes active, hand it first
            // responder so the next keystroke reaches its surface, not the pane you left.
            .onChange(of: isActive) { _, active in
                if active, let sid = node.sessionID { focusSurface(sid) }
            }
    }

    /// Make the active leaf's live surface (terminal / browser) first responder — the keyboard
    /// half of activation, so ⌘⌥+arrow moves both the ring and the caret.
    private func focusSurface(_ sessionID: UUID) {
        DispatchQueue.main.async {
            if let v = TerminalManager.shared.existingView(sessionID) {
                v.window?.makeFirstResponder(v)
            }
        }
    }

    @ViewBuilder private var leafBody: some View {
        if let sid = node.sessionID, let s = store.session(sid) {
            SessionPane(session: s).id(s.id)
        } else if let bid = node.setupBranchID, let br = store.branch(id: bid) {
            WorktreeSetupPane(branch: br).id(br.id)
        } else {
            PaneEmpty()
        }
    }
}

/// working.html `.pane`: head (title · crumb · spacer) over the session body,
/// entering with the 220ms fade + 4px rise.
private struct SessionPane: View {
    @Environment(AppStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let session: Session
    @State private var shown = false

    var body: some View {
        VStack(spacing: 0) {
            PaneHead(session: session,
                     workspace: store.branch(of: session).flatMap { store.workspace(of: $0) },
                     branch: store.branch(of: session))
            paneBody
        }
        .opacity(shown ? 1 : 0)
        .offset(y: shown ? 0 : 4)
        .onAppear {
            if reduceMotion { shown = true }
            else { withAnimation(.easeOut(duration: 0.22)) { shown = true } }
        }
    }

    // A session — terminal or coding agent — is backed by a PTY running in its worktree; an
    // agent just runs its binary inside it. The kind drives the sidebar/head visual, not what
    // the pane shows. A browser session hosts an engine instead of a PTY.
    @ViewBuilder private var paneBody: some View {
        if session.kind == .browser {
            BrowserPane(session: session)
        } else if let cwd = store.cwd(for: session) {
            let workspace = store.branch(of: session).flatMap { store.workspace(of: $0) }
            let flags = session.spawnedKind.agentID.map { store.agentFlags($0, for: workspace) } ?? ""
            TermSurface(terminal: TerminalManager.shared.view(for: session, cwd: cwd, agentFlags: flags))
        } else {
            Placeholder(title: session.title, subtitle: "No working directory for this session.")
        }
    }
}

/// working.html `.pane__head`: the titlebar band, 18pt side padding, hairline bottom border.
private struct PaneHead: View {
    @Environment(AppStore.self) private var store
    let session: Session
    let workspace: Workspace?
    let branch: Branch?
    @State private var hovering = false

    private var collapsed: Bool { store.sidebarCollapsed }

    var body: some View {
        HStack(spacing: 10) {
            // Collapsed: the expand toggle binds into the header cluster right after the
            // traffic lights, so it's part of the toolbar rather than a floating orphan.
            // The 2pt tops the HStack's 10 up to the mock's 12pt gap before the title.
            if collapsed {
                SidebarToggle().padding(.trailing, 2)
            }
            SessionIcon(kind: session.kind, size: 15)
                .frame(width: 15, height: 15)
            Text(session.title)
                .font(.system(size: 13, weight: .semibold))
                .kerning(-0.13)
                .foregroundStyle(Theme.ink)
            // Crumb: `<b>workspace</b> / branch` — mono 11, faint, workspace muted.
            if let ws = workspace, let br = branch {
                (Text(ws.name).foregroundColor(Theme.inkMuted).fontWeight(.medium)
                    + Text(" / \(br.name)").foregroundColor(Theme.inkFaint))
                    .font(.system(size: 11, design: .monospaced))
                    .kerning(-0.11)
                    .lineLimit(1)
                    .truncationMode(.tail)
                // Copy the branch name — hover-revealed on the header, like the sidebar kebab.
                CrumbCopyButton(text: br.name, revealed: hovering)
            }
            Spacer(minLength: 0)
            // The open branch's PR, clickable through to GitHub in the default browser.
            if let pr = branch?.pr {
                PRChip(pr: pr)
            }
        }
        // Collapsed, the header starts past the traffic lights; either way it is the same band
        // as the sidebar strip, so the title sits on the traffic-light centre line.
        .padding(.leading, collapsed ? Theme.trafficLightsClearance : 18)
        .padding(.trailing, 18)
        .frame(height: Theme.titlebarHeight)
        .onHover { hovering = $0 }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.border).frame(height: 0.5)
        }
    }
}

/// working.html `.crumb-copy`: copies the branch name to the clipboard, flashing a green
/// check. Hover-revealed on the header (the sidebar-kebab idiom), so it stays out of the way.
private struct CrumbCopyButton: View {
    let text: String
    let revealed: Bool
    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        Button(action: copy) {
            Phos(path: copied ? Phosphor.check : Phosphor.copy, size: 12)
                .frame(width: 19, height: 19)
                .foregroundStyle(copied ? Theme.run : (hovering ? Theme.ink2 : Theme.inkMeta))
                .background(hovering && !copied ? Theme.rowSelected : .clear,
                            in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .opacity(copied || revealed ? 1 : 0)
        .help("Copy branch name")
    }

    private func copy() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { copied = false }
    }
}

/// working.html `.prchip`: the open branch's pull request as a raised button (like every
/// other control) so it reads as clickable — the state colour lives only in the git glyph
/// + number, not a full fill, so it's a control, not a status lamp. Opens the PR in the
/// user's default browser. Dev builds float a DEV badge in this same corner, so the button
/// clears it (`.app.is-dev`).
private struct PRChip: View {
    let pr: PRInfo
    @State private var hovering = false

    var body: some View {
        Button {
            if let url = URL(string: pr.url) { NSWorkspace.shared.open(url) }
        } label: {
            HStack(spacing: 5) {
                Phos(path: pr.state.glyph, size: 13)   // the state glyph carries the colour
                // verbatim: a plain Text("#\(Int)") is a LocalizedStringKey and would
                // group the digits (#13,874) — a PR number is an identifier, not a quantity.
                Text(verbatim: "#\(pr.number)")
                    .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                    .kerning(-0.11)
                    .monospacedDigit()
            }
            .foregroundStyle(pr.state.tint)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Theme.raised, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.line, lineWidth: 0.5))
            .shadow(color: .black.opacity(hovering ? 0.07 : 0.04),
                    radius: hovering ? 1.5 : 0.5, y: hovering ? 1 : 0.5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(Text(verbatim: "PR #\(pr.number) · \(pr.state.rawValue.lowercased()) — open in browser"))
        // Dev builds float a 54pt DEV badge whose left edge sits 72pt from the header's
        // right; clear it with a comfortable gap (button right edge → ~82pt from the edge).
        .padding(.trailing, isDevChannel ? 64 : 0)
    }
}

/// working.html `.term`: the dark rounded card the shell lives in — 14 margin,
/// 13/15 inner padding, #1b1b1e, inset hairline + soft drop shadow.
private struct TermSurface: View {
    let terminal: GhosttySurfaceView

    var body: some View {
        TerminalHost(terminal: terminal)
            .padding(.vertical, 13).padding(.horizontal, 15)
            .background(Theme.tuiBg)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Theme.tuiHair, lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.05), radius: 1, y: 1)
            .shadow(color: .black.opacity(0.05), radius: 6, y: 2)
            .padding(14)
    }
}

/// working.html `.pane-empty`: centered terminal mark + "No session open".
private struct PaneEmpty: View {
    var body: some View {
        VStack(spacing: 12) {
            Phos(path: Phosphor.terminal, size: 26)
                .foregroundStyle(Theme.inkFaint)
                .opacity(0.5)
            Text("No session open")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.inkFaint)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The optimistic "setting up worktree…" skeleton: shown the instant a create is
/// requested (so the switch rides the keystroke), resolving in place into the first
/// session once the checkout lands — but only while the user is still parked here
/// (Store.applySessionTemplate). Same head shape as a real session pane so the resolve
/// is a quiet cross-fade, not a jump.
private struct WorktreeSetupPane: View {
    @Environment(AppStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let branch: Branch
    @State private var shown = false

    private var collapsed: Bool { store.sidebarCollapsed }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if collapsed {
                    SidebarToggle().padding(.trailing, 2)
                }
                Phos(path: Phosphor.branch, size: 15)
                    .foregroundStyle(Theme.inkFaint)
                    .frame(width: 15, height: 15)
                Text(branch.name)
                    .font(.system(size: 13, weight: .semibold))
                    .kerning(-0.13)
                    .foregroundStyle(Theme.ink)
                if let ws = store.workspace(of: branch) {
                    (Text(ws.name).foregroundColor(Theme.inkMuted).fontWeight(.medium)
                        + Text(" / \(branch.name)").foregroundColor(Theme.inkFaint))
                        .font(.system(size: 11, design: .monospaced))
                        .kerning(-0.11)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, collapsed ? Theme.trafficLightsClearance : 18)
            .padding(.trailing, 18)
            .frame(height: Theme.titlebarHeight)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Theme.border).frame(height: 0.5)
            }

            VStack(spacing: 12) {
                SetupSpinner()
                Text("Setting up worktree…")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.inkFaint)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .opacity(shown ? 1 : 0)
        .offset(y: shown ? 0 : 4)
        .onAppear {
            if reduceMotion { shown = true }
            else { withAnimation(.easeOut(duration: 0.22)) { shown = true } }
        }
    }
}

/// The setup pane's centred arc spinner — the pending-row spinner (Sidebar) scaled up
/// to carry the empty pane.
private struct SetupSpinner: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spinning = false
    var body: some View {
        Circle()
            .trim(from: 0.12, to: 1)
            .stroke(Theme.inkFaint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .frame(width: 22, height: 22)
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .animation(reduceMotion ? nil : .linear(duration: 0.9).repeatForever(autoreverses: false),
                       value: spinning)
            .onAppear { spinning = true }
    }
}

private struct Placeholder: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkle")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Theme.copper)
            Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.ink)
            Text(subtitle).font(.system(size: 11)).foregroundStyle(Theme.inkFaint)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
