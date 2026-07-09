import AppKit
import SwiftUI

// The ⌘K command palette — a navigation stack of frames (working.html's cmdk).
// Simple at rest, progressive search on typing; drill pushes a frame, Backspace on
// an empty query pops. Create / delete / confirm happen inline as text — never a modal.

// MARK: - Fuzzy matcher

/// Subsequence match with word-boundary + contiguity bonuses; nil = no match.
/// Ports working.html's `fuzzy()` exactly.
func fuzzyScore(_ query: String, _ text: String) -> Double? {
    if query.isEmpty { return 0 }
    let q = Array(query.lowercased())
    let t = Array(text.lowercased())
    var ti = 0, first = -1
    var run = 0.0, score = 0.0
    for c in q {
        var idx = -1
        var i = ti
        while i < t.count { if t[i] == c { idx = i; break }; i += 1 }
        if idx == -1 { return nil }
        if first == -1 { first = idx }
        run = idx == ti ? run + 2 : 0
        if idx == 0 || !(t[idx - 1].isLetter || t[idx - 1].isNumber) { score += 3 }
        score += 1 + run
        ti = idx + 1
    }
    return score - Double(first) * 0.5
}

/// Branch names can't contain spaces — inputs that name a new branch turn each
/// space into a dash as you type (working.html's `dashSpaces`: leading whitespace
/// dropped, runs collapsed).
func dashSpaces(_ s: String) -> String {
    String(s.drop(while: \.isWhitespace))
        .replacingOccurrences(of: "\\s+", with: "-", options: .regularExpression)
}

// MARK: - Model

enum PaletteIcon {
    case phosphor(String)                 // path, default grey tint
    case session(SessionKind)             // kind icon + its tint
    case chip(String, Color)              // workspace monogram
}

struct PaletteItem {
    var icon: PaletteIcon
    var label: String
    var sec: String? = nil                // nav / act / list → divider grouping in a frame
    var group: String? = nil              // Actions / Workspaces / … → text headers in search
    var ctx: String? = nil                // location, shown only where not already established
    var meta: String? = nil               // status label
    var metaColor: Color? = nil
    var kbd: [String]? = nil
    var danger = false
    var disabled = false
    var enter: () -> Void
}

struct PaletteFrame {
    enum Mode { case list, input, confirm }
    var crumb: String? = nil
    var placeholder: String
    var mode: Mode = .list
    /// A pre-filled query for input frames (rename seeds the current name, selected).
    var seed: String? = nil
    /// Input frames that name a new branch rewrite spaces to dashes as you type.
    var dashSpaces = false
    var build: (String) -> [PaletteItem]
}

@MainActor @Observable final class PaletteModel {
    unowned let store: AppStore
    var stack: [PaletteFrame] = []
    var query = "" { didSet { activeIndex = 0 } }
    var activeIndex = 0

    /// Branch lists for the New-worktree search, read OFF the main thread so pressing
    /// `a` on a workspace never blocks the UI on git (a large/cold repo's `for-each-ref`
    /// can take a beat). Read once per palette lifetime — the branch set can't change
    /// while the palette is open — and the frame re-renders when results land.
    private var branchCache: [UUID: [GitService.BranchRef]] = [:]
    private var loadingBranches: Set<UUID> = []

    private func loadBranches(for workspace: Workspace) {
        let id = workspace.id
        guard branchCache[id] == nil, !loadingBranches.contains(id) else { return }
        loadingBranches.insert(id)
        let url = workspace.url
        Task { [weak self] in
            let branches = await Task.detached(priority: .userInitiated) {
                GitService.allBranches(at: url)
            }.value
            guard let self else { return }
            branchCache[id] = branches
            loadingBranches.remove(id)
        }
    }

    init(store: AppStore) {
        self.store = store
        stack = [rootFrame()]
    }

    var frame: PaletteFrame { stack[stack.count - 1] }

    /// The frame's items, fuzzy-filtered for `list` frames — section order preserved,
    /// fuzzy-ranked within each section (working.html's renderFrame).
    var items: [PaletteItem] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let built = frame.build(q)
        guard frame.mode == .list, !q.isEmpty else { return built }
        var order: [String] = []
        var byKey: [String: [(PaletteItem, Double)]] = [:]
        for it in built {
            // Fold the context chip into matching (working.html itemScore) so a bare-labelled
            // action ("Rename") is still found by its target's name via `ctx`.
            let base = fuzzyScore(q, it.label)
            let withCtx = it.ctx.flatMap { c in fuzzyScore(q, "\(c) \(it.label)").map { $0 - 2 } }
            guard let s = [base, withCtx].compactMap({ $0 }).max() else { continue }
            let k = it.group ?? it.sec ?? ""
            if byKey[k] == nil { byKey[k] = []; order.append(k) }
            byKey[k]!.append((it, s))
        }
        return order.flatMap { byKey[$0]!.sorted { $0.1 > $1.1 }.map(\.0) }
    }

    func push(_ frame: PaletteFrame) { stack.append(frame); query = frame.seed ?? "" }
    func pop() { if stack.count > 1 { stack.removeLast(); query = "" } }
    func pop(to depth: Int) { stack.removeLast(stack.count - max(1, depth + 1)); query = "" }

    /// Set only by `move` (a real cursor move) so the list scrolls to the active item
    /// on navigation — never on open, a query-driven reset, or hover. The view consumes it.
    @ObservationIgnored var scrollToActive = false

    func consumeScrollToActive() -> Bool {
        defer { scrollToActive = false }
        return scrollToActive
    }

    func move(_ delta: Int) {
        let n = items.count
        guard n > 0 else { return }
        let next = (activeIndex + delta + n) % n
        guard next != activeIndex else { return }
        scrollToActive = true
        activeIndex = next
    }

    func runActive() {
        let its = items
        guard activeIndex < its.count else { return }
        let it = its[activeIndex]
        guard !it.disabled else { return }
        it.enter()
    }

    private func runAndClose(_ fn: @escaping () -> Void) { store.closePalette(); fn() }

    // MARK: Store-derived helpers

    /// The row ⌘K acts on. Mirrors working.html's contextRow: the focused sidebar row
    /// leads when the keyboard owns the sidebar (`keyboardActive` is the `body.kbd` guard —
    /// a live focus ring, not a stale cursor left behind after focus moved to the content
    /// pane), else the open session in the content pane.
    private func contextRow() -> RowRef? {
        if store.keyboardActive, let ref = store.cursorRef { return ref }
        if let s = store.openSession { return .session(s) }
        return nil
    }

    /// ⌘K acts on the single innermost thing you're focused on — the session leaf, else its
    /// branch, else its workspace (the context row: focused sidebar row, else the open session).
    /// It returns just that one scope's own verbs, grouped under "Level · unit" so labels stay
    /// bare. The enclosing branch/workspace come back as `parents` — "Go to" jump rows that drill
    /// into their own frame, where their actions live — so acting on a parent is a deliberate step
    /// up, never a careless-Enter neighbour of a session's verbs (working.html contextActions).
    private func contextActions() -> (items: [PaletteItem], parents: [PaletteItem]) {
        var items: [PaletteItem] = []
        var parents: [PaletteItem] = []
        func upBranch(_ b: Branch) {
            parents.append(PaletteItem(icon: .phosphor(Phosphor.branch), label: b.name,
                                       group: "Go to", ctx: "Branch",
                                       enter: { self.push(self.branchFrame(b)) }))
        }
        func upWorkspace(_ w: Workspace) {
            parents.append(PaletteItem(icon: chipIcon(w), label: w.name,
                                       group: "Go to", ctx: "Workspace",
                                       enter: { self.push(self.workspaceFrame(w)) }))
        }

        switch contextRow() {
        case let .session(open):
            let g = "Session · \(open.title)"
            // A browser session leads with a Page group — the page's own verbs, one keystroke
            // away — then a comment-mode toggle (ADR-0011 stage three), the palette twin of the
            // bar button so the keyboard can drive it without a click.
            if open.kind == .browser {
                items += browserActions(open).map { item -> PaletteItem in
                    var it = item; it.group = "Page · \(open.title)"; it.ctx = open.title; return it
                }
                let on = BrowserManager.shared.existing(open.id)?.commentMode?.active ?? false
                items.append(PaletteItem(icon: .phosphor(Phosphor.commentMode),
                                         label: on ? "Exit comment mode" : "Enter comment mode",
                                         group: g, ctx: open.title,
                                         enter: { self.runAndClose { [store = self.store] in
                                             BrowserManager.shared.controller(for: open)?
                                                 .toggleCommentMode(store: store)
                                         } }))
            }
            items.append(PaletteItem(icon: .phosphor(Phosphor.pencil), label: "Rename",
                                     group: g, ctx: open.title,
                                     enter: { self.push(self.renameFrame(.session(open))) }))
            items += containmentItems(open, group: g)
            items.append(PaletteItem(icon: .phosphor(Phosphor.trash), label: "Delete",
                                     group: g, ctx: open.title, danger: true,
                                     enter: { self.push(self.confirmDeleteSession(open)) }))
            if let br = store.branch(of: open) {
                upBranch(br)
                if let ws = store.workspace(of: br) { upWorkspace(ws) }
            }
        case let .branch(branch):
            let g = "Branch · \(branch.name)"
            items.append(PaletteItem(icon: .phosphor(Phosphor.terminal), label: "New terminal",
                                     group: g, ctx: branch.name,
                                     enter: { self.runAndClose { self.store.newTerminal(in: branch) } }))
            items += AgentRegistry.installed.map { agent in
                PaletteItem(icon: .session(.agent(agent.id)), label: "New \(agent.displayName)",
                            group: g, ctx: branch.name,
                            enter: { self.runAndClose { self.store.newAgent(agent.id, in: branch) } })
            }
            items.append(PaletteItem(icon: .phosphor(Phosphor.globe), label: "New browser",
                                     group: g, ctx: branch.name,
                                     enter: { self.runAndClose { self.store.newBrowser(in: branch) } }))
            items.append(PaletteItem(icon: .phosphor(Phosphor.pencil), label: "Rename",
                                     group: g, ctx: branch.name,
                                     enter: { self.push(self.renameFrame(.branch(branch))) }))
            items.append(PaletteItem(icon: .phosphor(Phosphor.trash), label: "Remove",
                                     group: g, ctx: branch.name, danger: true,
                                     enter: { self.push(self.confirmRemoveBranch(branch)) }))
            if let ws = store.workspace(of: branch) { upWorkspace(ws) }
        case let .workspace(ws):
            let g = "Workspace · \(ws.name)"
            items.append(PaletteItem(icon: .phosphor(Phosphor.branch), label: "New worktree…",
                                     group: g, ctx: ws.name,
                                     enter: { self.push(self.worktreeFrame(in: ws)) }))
            items.append(PaletteItem(icon: .phosphor(Phosphor.gear), label: "Settings…",
                                     group: g, ctx: ws.name,
                                     enter: { self.runAndClose { self.store.enterSettings(.workspace(ws.id)) } }))
            items.append(PaletteItem(icon: .phosphor(Phosphor.pencil), label: "Rename",
                                     group: g, ctx: ws.name,
                                     enter: { self.push(self.renameFrame(.workspace(ws))) }))
            items.append(PaletteItem(icon: .phosphor(Phosphor.trash), label: "Remove",
                                     group: g, ctx: ws.name, danger: true,
                                     enter: { self.push(self.confirmRemoveWorkspace(ws)) }))
        case .none:
            break
        }
        return (items, parents)
    }

    /// The Page verbs for a browser session (working.html browserActions). Each drives
    /// the visible toolbar control a click would — the palette adds no second navigation
    /// path, so disabled states (home page, empty history) come for free. When `s` isn't
    /// the open session there is no live page yet, so everything but "Go to address…"
    /// (which opens the session first) reads disabled.
    private func browserActions(_ s: Session) -> [PaletteItem] {
        let live = store.openSessionID == s.id ? BrowserManager.shared.existing(s.id) : nil
        let home = live?.isHome ?? true
        // close palette → jump to the session if it isn't open → drive the control.
        func drive(_ fn: @escaping (BrowserSessionController) -> Void) -> () -> Void {
            { self.runAndClose { [store = self.store] in
                if store.openSessionID != s.id { store.jump(to: s) }
                if let ctrl = BrowserManager.shared.controller(for: s) { fn(ctrl) }
            } }
        }
        return [
            // On home the omnibox focuses the "Go to" field; on a page it opens the drop.
            PaletteItem(icon: .phosphor(Phosphor.search), label: "Go to address…",
                        kbd: ["⌘", "L"], enter: drive { $0.focusAddress() }),
            PaletteItem(icon: .phosphor(Phosphor.reload), label: "Reload page",
                        kbd: ["⌘", "R"], disabled: home,
                        enter: drive { if !$0.isHome { $0.reload() } }),
            PaletteItem(icon: .phosphor(Phosphor.back), label: "Back",
                        kbd: ["⌘", "["], disabled: !(live?.canGoBack ?? false),
                        enter: drive { if $0.canGoBack { $0.goBack() } }),
            PaletteItem(icon: .phosphor(Phosphor.forward), label: "Forward",
                        kbd: ["⌘", "]"], disabled: !(live?.canGoForward ?? false),
                        enter: drive { if $0.canGoForward { $0.goForward() } }),
            PaletteItem(icon: .phosphor(Phosphor.copy), label: "Copy URL", disabled: home,
                        enter: { self.runAndClose {
                            guard let url = live?.address else { return }
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(url.absoluteString, forType: .string)
                        } }),
            PaletteItem(icon: .phosphor(Phosphor.external), label: "Open in default browser",
                        disabled: home,
                        enter: { self.runAndClose {
                            if let url = live?.address { NSWorkspace.shared.open(url) }
                        } }),
            PaletteItem(icon: .phosphor(Phosphor.devtools),
                        label: live?.devToolsOpen == true ? "Hide DevTools" : "Show DevTools",
                        kbd: ["⌥", "⌘", "I"], disabled: home,
                        enter: drive { if !$0.isHome { $0.toggleDevTools() } }),
        ]
    }

    /// Containment verbs for a browser row (ADR-0011 stage four) — the sole way ownership
    /// changes by hand: owned → Detach; unowned → one Move-under per claude in its branch.
    private func containmentItems(_ s: Session, group: String? = nil, sec: String? = nil) -> [PaletteItem] {
        guard s.kind == .browser else { return [] }
        if let owner = store.owner(of: s) {
            return [PaletteItem(icon: .phosphor(Phosphor.minusCircle),
                                label: "Detach from “\(owner.title)”",
                                sec: sec, group: group, ctx: s.title,
                                enter: { self.runAndClose { self.store.detach(s) } })]
        }
        guard let br = store.branch(of: s) else { return [] }
        return br.sessions.filter { $0.kind.isAgent }.map { agent in
            // The row shows the agent it would move the browser under, not a generic sparkle.
            PaletteItem(icon: .session(agent.kind),
                        label: "Move under “\(agent.title)”",
                        sec: sec, group: group, ctx: s.title,
                        enter: { self.runAndClose { self.store.adopt(s, by: agent) } })
        }
    }

    private func wsOf(_ branch: Branch) -> String { store.workspace(of: branch)?.name ?? "" }
    private func ctxOf(_ session: Session) -> String {
        guard let br = store.branch(of: session) else { return "" }
        return [wsOf(br), br.name].filter { !$0.isEmpty }.joined(separator: " / ")
    }

    private func chipIcon(_ ws: Workspace) -> PaletteIcon {
        .chip(ws.monogram, Theme.chipColors[ws.colorIndex % Theme.chipColors.count])
    }

    private func sessionItem(_ s: Session, ctx: Bool, sec: String? = nil, group: String? = nil) -> PaletteItem {
        PaletteItem(icon: .session(s.kind), label: s.title, sec: sec, group: group,
                    ctx: ctx ? ctxOf(s) : nil,
                    meta: s.status.paletteLabel, metaColor: s.status.paletteColor,
                    enter: { [self] in runAndClose { [store] in store.jump(to: s) } })
    }

    // MARK: Frames

    func rootFrame() -> PaletteFrame {
        PaletteFrame(placeholder: "Search or jump to anything…") { [self] q in
            let here = contextActions()
            if q.isEmpty {
                // Browse: the focused scope's verbs drop the now-redundant context chip (the
                // group header names the unit), but the "Go to" parents keep theirs — there the
                // chip is the level ("Branch" / "Workspace"), not a repeat of the header.
                var items = here.items.map { item -> PaletteItem in
                    var it = item; it.ctx = nil; return it
                }
                items += here.parents
                items += [
                    PaletteItem(icon: .phosphor(Phosphor.folder), label: "Workspaces", sec: "nav",
                                enter: { self.push(self.workspacesFrame()) }),
                    PaletteItem(icon: .phosphor(Phosphor.branch), label: "Branches", sec: "nav",
                                enter: { self.push(self.branchesFrame()) }),
                    PaletteItem(icon: .phosphor(Phosphor.squares), label: "Sessions", sec: "nav",
                                enter: { self.push(self.sessionsFrame()) }),
                    PaletteItem(icon: .phosphor(Phosphor.sidebar), label: "Toggle sidebar", sec: "act",
                                kbd: ["⌘", "B"],
                                enter: { self.runAndClose { self.store.sidebarCollapsed.toggle() } }),
                    PaletteItem(icon: .phosphor(Phosphor.gear), label: "Settings", sec: "act",
                                kbd: ["⌘", ","],
                                enter: { self.runAndClose { self.store.enterSettings() } }),
                    PaletteItem(icon: .phosphor(Phosphor.keys), label: "Keyboard shortcuts", sec: "act",
                                kbd: ["⌘", "?"],
                                enter: { self.runAndClose { self.store.shortcutsOpen = true } }),
                    PaletteItem(icon: .phosphor(Phosphor.commentMode), label: "Send feedback…", sec: "act",
                                kbd: ["⌘", "⇧", "F"],
                                enter: { self.runAndClose { self.store.feedbackOpen = true } }),
                ]
                return items
            }
            // Search folds only the focused scope's verbs under Actions (the parents are browse-only
            // navigation; the Branches / Workspaces groups below already reach them).
            var items = here.items.map { item -> PaletteItem in
                var it = item; it.group = "Actions"; return it
            }
            items += [
                PaletteItem(icon: .phosphor(Phosphor.plus), label: "New workspace…", group: "Actions",
                            enter: { self.push(self.createWorkspaceFrame()) }),
                PaletteItem(icon: .phosphor(Phosphor.sidebar), label: "Toggle sidebar", group: "Actions",
                            kbd: ["⌘", "B"],
                            enter: { self.runAndClose { self.store.sidebarCollapsed.toggle() } }),
                PaletteItem(icon: .phosphor(Phosphor.gear), label: "Settings", group: "Actions",
                            kbd: ["⌘", ","],
                            enter: { self.runAndClose { self.store.enterSettings() } }),
                PaletteItem(icon: .phosphor(Phosphor.keys), label: "Keyboard shortcuts", group: "Actions",
                            kbd: ["⌘", "?"],
                            enter: { self.runAndClose { self.store.shortcutsOpen = true } }),
                PaletteItem(icon: .phosphor(Phosphor.commentMode), label: "Send feedback…", group: "Actions",
                            kbd: ["⌘", "⇧", "F"],
                            enter: { self.runAndClose { self.store.feedbackOpen = true } }),
            ]
            // Search groups run most-local-first: Actions (above), then Sessions, Branches, Workspaces.
            for ws in store.workspaces {
                for br in ws.branches {
                    for s in br.sessions { items.append(sessionItem(s, ctx: true, group: "Sessions")) }
                }
            }
            for ws in store.workspaces {
                for br in ws.branches {
                    items.append(PaletteItem(icon: .phosphor(Phosphor.branch), label: br.name,
                                             group: "Branches", ctx: ws.name,
                                             enter: { self.push(self.branchFrame(br)) }))
                }
            }
            for ws in store.workspaces {
                items.append(PaletteItem(icon: chipIcon(ws), label: ws.name, group: "Workspaces",
                                         enter: { self.push(self.workspaceFrame(ws)) }))
            }
            return items
        }
    }

    func workspacesFrame() -> PaletteFrame {
        PaletteFrame(crumb: "Workspaces", placeholder: "Search workspaces…") { [self] _ in
            var items = [
                PaletteItem(icon: .phosphor(Phosphor.plus), label: "New workspace…", sec: "act",
                            enter: { self.push(self.createWorkspaceFrame()) }),
                PaletteItem(icon: .phosphor(Phosphor.trash), label: "Remove workspace…", sec: "act",
                            danger: true, enter: { self.push(self.removeWorkspacePicker()) }),
            ]
            for ws in store.workspaces {
                items.append(PaletteItem(icon: chipIcon(ws), label: ws.name, sec: "list",
                                         enter: { self.push(self.workspaceFrame(ws)) }))
            }
            return items
        }
    }

    func branchesFrame() -> PaletteFrame {
        PaletteFrame(crumb: "Branches", placeholder: "Search branches…") { [self] _ in
            var items = [
                PaletteItem(icon: .phosphor(Phosphor.trash), label: "Remove branch…", sec: "act",
                            danger: true, enter: { self.push(self.removeBranchPicker()) }),
            ]
            for ws in store.workspaces {
                for br in ws.branches {
                    items.append(PaletteItem(icon: .phosphor(Phosphor.branch), label: br.name,
                                             sec: "list", ctx: ws.name,
                                             enter: { self.push(self.branchFrame(br)) }))
                }
            }
            return items
        }
    }

    func sessionsFrame() -> PaletteFrame {
        PaletteFrame(crumb: "Sessions", placeholder: "Search sessions…") { [self] _ in
            var items = [
                PaletteItem(icon: .phosphor(Phosphor.trash), label: "Delete session…", sec: "act",
                            danger: true, enter: { self.push(self.deleteSessionPicker()) }),
            ]
            for ws in store.workspaces {
                for br in ws.branches {
                    for s in br.sessions { items.append(sessionItem(s, ctx: true, sec: "list")) }
                }
            }
            return items
        }
    }

    func workspaceFrame(_ ws: Workspace) -> PaletteFrame {
        PaletteFrame(crumb: ws.name, placeholder: "Search \(ws.name)…") { [self] _ in
            var items = [
                PaletteItem(icon: .phosphor(Phosphor.branch), label: "New worktree…", sec: "act",
                            enter: { self.push(self.worktreeFrame(in: ws)) }),
            ]
            // Session creates land on the workspace's first branch (contextActions' fallback);
            // the ctx chip names it since the crumb only establishes the workspace.
            if let br = ws.branches.first {
                items += sessionCreates(in: br, ctx: br.name)
            }
            items += [
                PaletteItem(icon: .phosphor(Phosphor.gear), label: "Workspace settings…", sec: "act",
                            enter: { self.runAndClose { self.store.enterSettings(.workspace(ws.id)) } }),
                PaletteItem(icon: .phosphor(Phosphor.pencil), label: "Rename \(ws.name)…", sec: "act",
                            enter: { self.push(self.renameFrame(.workspace(ws))) }),
                PaletteItem(icon: .phosphor(Phosphor.trash), label: "Remove \(ws.name)", sec: "act",
                            danger: true, enter: { self.push(self.confirmRemoveWorkspace(ws)) }),
            ]
            for br in ws.branches {
                items.append(PaletteItem(icon: .phosphor(Phosphor.branch), label: br.name, sec: "list",
                                         enter: { self.push(self.branchFrame(br)) }))
            }
            return items
        }
    }

    /// A leaf session's own frame (working.html sessionFrame) — reached by its ⋯ kebab.
    /// Its own actions (rename / delete) plus sibling creates on its branch (the ctx
    /// chip names the branch, as the crumb is the session). Browser rows carry the
    /// containment verbs between Rename and Delete (stage four).
    func sessionFrame(_ s: Session) -> PaletteFrame {
        PaletteFrame(crumb: s.title, placeholder: "Search \(s.title)…") { [self] _ in
            var items: [PaletteItem] = []
            // A browser row's frame leads with its Page verbs (working.html sessionFrame).
            if s.kind == .browser {
                items += browserActions(s).map { item -> PaletteItem in
                    var it = item; it.sec = "page"; return it
                }
            }
            if let br = store.branch(of: s) {
                items += sessionCreates(in: br, ctx: br.name)
            }
            items.append(PaletteItem(icon: .phosphor(Phosphor.pencil), label: "Rename \(s.title)…", sec: "act",
                                     enter: { self.push(self.renameFrame(.session(s))) }))
            items += containmentItems(s, sec: "act")
            items.append(PaletteItem(icon: .phosphor(Phosphor.trash), label: "Delete \(s.title)", sec: "act",
                                     danger: true, enter: { self.push(self.confirmDeleteSession(s)) }))
            return items
        }
    }

    /// The session creates on a branch — a terminal, one per installed agent, a browser —
    /// shared by the branch frame and the workspace/session frames, which borrow them with a
    /// ctx chip naming the branch.
    private func sessionCreates(in branch: Branch, ctx: String? = nil) -> [PaletteItem] {
        [PaletteItem(icon: .phosphor(Phosphor.terminal), label: "New terminal", sec: "act",
                     ctx: ctx, enter: { self.runAndClose { self.store.newTerminal(in: branch) } })]
        + AgentRegistry.installed.map { agent in
            PaletteItem(icon: .session(.agent(agent.id)), label: "New \(agent.displayName)", sec: "act",
                        ctx: ctx, enter: { self.runAndClose { self.store.newAgent(agent.id, in: branch) } })
        }
        + [PaletteItem(icon: .phosphor(Phosphor.globe), label: "New browser", sec: "act",
                       ctx: ctx, enter: { self.runAndClose { self.store.newBrowser(in: branch) } })]
    }

    /// Drill the palette straight to a row's frame — the row ⋯ kebab opens this instead of
    /// the hover popover (working.html openRowActions). Root stays underneath for Back.
    func drill(to ref: RowRef) {
        switch ref {
        case let .workspace(w): stack = [rootFrame(), workspaceFrame(w)]
        case let .branch(b):    stack = [rootFrame(), branchFrame(b)]
        case let .session(s):   stack = [rootFrame(), sessionFrame(s)]
        }
        query = ""
        activeIndex = 0
    }

    func branchFrame(_ branch: Branch) -> PaletteFrame {
        PaletteFrame(crumb: branch.name, placeholder: "Search \(branch.name)…") { [self] _ in
            var items = sessionCreates(in: branch)
            items += [
                PaletteItem(icon: .phosphor(Phosphor.pencil), label: "Rename \(branch.name)…", sec: "act",
                            enter: { self.push(self.renameFrame(.branch(branch))) }),
                PaletteItem(icon: .phosphor(Phosphor.trash), label: "Remove \(branch.name)", sec: "act",
                            danger: true, enter: { self.push(self.confirmRemoveBranch(branch)) }),
            ]
            for s in branch.sessions { items.append(sessionItem(s, ctx: false, sec: "list")) }
            return items
        }
    }

    // MARK: Remove/delete pickers → inline confirm

    func removeWorkspacePicker() -> PaletteFrame {
        PaletteFrame(crumb: "Remove workspace", placeholder: "Select a workspace to remove…") { [self] _ in
            store.workspaces.map { ws in
                PaletteItem(icon: chipIcon(ws), label: ws.name, danger: true,
                            enter: { self.push(self.confirmRemoveWorkspace(ws)) })
            }
        }
    }

    func removeBranchPicker() -> PaletteFrame {
        PaletteFrame(crumb: "Remove branch", placeholder: "Select a branch to remove…") { [self] _ in
            store.workspaces.flatMap { ws in
                ws.branches.map { br in
                    PaletteItem(icon: .phosphor(Phosphor.branch), label: br.name, ctx: ws.name,
                                danger: true, enter: { self.push(self.confirmRemoveBranch(br)) })
                }
            }
        }
    }

    func deleteSessionPicker() -> PaletteFrame {
        PaletteFrame(crumb: "Delete session", placeholder: "Select a session to delete…") { [self] _ in
            store.workspaces.flatMap(\.branches).flatMap(\.sessions).map { s in
                PaletteItem(icon: .session(s.kind), label: s.title, ctx: ctxOf(s),
                            meta: s.status.paletteLabel, metaColor: s.status.paletteColor,
                            danger: true, enter: { self.push(self.confirmDeleteSession(s)) })
            }
        }
    }

    private func confirmFrame(verb: String, name: String, hint: String,
                              perform: @escaping () -> Void) -> PaletteFrame {
        PaletteFrame(crumb: "\(verb) \(name)?", placeholder: "\(hint)  ↵ confirm · esc cancel",
                     mode: .confirm) { [self] _ in
            [
                PaletteItem(icon: .phosphor(Phosphor.trash), label: "\(verb) \(name)", danger: true,
                            enter: { self.runAndClose(perform) }),
                PaletteItem(icon: .phosphor(Phosphor.close), label: "Cancel", enter: { self.pop() }),
            ]
        }
    }

    func confirmRemoveWorkspace(_ ws: Workspace) -> PaletteFrame {
        confirmFrame(verb: "Remove", name: ws.name,
                     hint: "Remove this workspace? Nothing on disk is deleted.") { [store] in
            store.removeWorkspace(ws)
        }
    }
    // Removing a worktree forks: delete it for real (git worktree remove + rm the folder),
    // or just drop it from the sidebar and leave the checkout on disk to re-add later.
    // The destructive path is danger-styled; the list-only path isn't — the colour is the tell.
    func confirmRemoveBranch(_ br: Branch) -> PaletteFrame {
        PaletteFrame(crumb: "Remove \(br.name)?",
                     placeholder: "Delete the worktree from disk, or just remove it from the sidebar?  ↵ select · esc cancel",
                     mode: .confirm) { [self] _ in
            [
                PaletteItem(icon: .phosphor(Phosphor.trash), label: "Delete worktree",
                            ctx: "git worktree remove + delete its folder on disk", danger: true,
                            enter: { self.runAndClose { self.store.removeBranch(br, deleteWorktree: true) } }),
                PaletteItem(icon: .phosphor(Phosphor.minusCircle), label: "Remove from sidebar",
                            ctx: "stop tracking it here — the worktree stays on disk",
                            enter: { self.runAndClose { self.store.removeBranch(br, deleteWorktree: false) } }),
                PaletteItem(icon: .phosphor(Phosphor.close), label: "Cancel", enter: { self.pop() }),
            ]
        }
    }
    func confirmDeleteSession(_ s: Session) -> PaletteFrame {
        confirmFrame(verb: "Delete", name: s.title,
                     hint: store.deleteSessionHint(s)) { [store] in store.closeSession(s) }
    }

    // MARK: Create frames — the search input becomes the name field

    func createWorkspaceFrame() -> PaletteFrame {
        PaletteFrame(crumb: "New workspace", placeholder: "Repository path…", mode: .input) { [self] q in
            let v = q.trimmingCharacters(in: .whitespaces)
            return [PaletteItem(icon: .phosphor(Phosphor.plus),
                                label: v.isEmpty ? "Type a repository path…" : "Add workspace “\(v)”",
                                disabled: v.isEmpty,
                                enter: { self.runAndClose {
                                    let path = (v as NSString).expandingTildeInPath
                                    // Opens the worktree picker sheet after the palette closes.
                                    self.store.beginAddWorkspace(url: URL(fileURLWithPath: path))
                                } })]
        }
    }

    /// Rename any unit inline — the field seeds with the current name and commits once
    /// it actually changes (working.html renameFrame).
    func renameFrame(_ ref: RowRef) -> PaletteFrame {
        let noun: String = {
            switch ref {
            case .workspace: return "workspace"
            case .branch:    return "branch"
            case .session:   return "session"
            }
        }()
        let cur = store.currentName(of: ref)
        return PaletteFrame(crumb: "Rename \(cur)", placeholder: "New \(noun) name…",
                            mode: .input, seed: cur) { [self] q in
            let v = q.trimmingCharacters(in: .whitespaces)
            let changed = !v.isEmpty && v != cur
            var items = [PaletteItem(icon: .phosphor(Phosphor.pencil),
                                     label: v.isEmpty ? "Type a new name…" : "Rename to “\(v)”",
                                     disabled: !changed,
                                     enter: { if changed { self.runAndClose { self.store.rename(ref, to: v) } } })]
            if case let .session(s) = ref, s.kind.isAgent, s.title != s.kind.tplStart {
                items.append(PaletteItem(icon: .phosphor(Phosphor.reset), label: "Reset to default name",
                                         ctx: s.kind.tplStart,
                                         enter: { self.runAndClose { self.store.resetSessionName(s) } }))
            }
            return items
        }
    }

    /// `a` on a branch/worktree (or a session leaf) jumps straight to the "add a session"
    /// choice — a terminal, any installed agent, or a browser, created in `branch`
    /// (working.html newSessionFrame). Order: create→navigate→modify→destroy, and within
    /// the creates, terminal first then the agents in registry order.
    func newSessionFrame(branch: Branch) -> PaletteFrame {
        PaletteFrame(crumb: "New session", placeholder: "New session in \(branch.name)…") { [self] _ in
            var items = [PaletteItem(icon: .session(.terminal), label: "New terminal", ctx: branch.name,
                                     enter: { self.runAndClose { self.store.newTerminal(in: branch) } })]
            items += AgentRegistry.installed.map { agent in
                PaletteItem(icon: .session(.agent(agent.id)), label: "New \(agent.displayName)", ctx: branch.name,
                            enter: { self.runAndClose { self.store.newAgent(agent.id, in: branch) } })
            }
            items.append(PaletteItem(icon: .session(.browser), label: "New browser", ctx: branch.name,
                                     enter: { self.runAndClose { self.store.newBrowser(in: branch) } }))
            return items
        }
    }

    /// New worktree via ⌘K: empty until you type, then fuzzy-match every local and remote
    /// branch (top 5, already-checked-out hidden, local/remote dedup'd), or cut a new branch
    /// off the typed name. Each pick checks the branch out into its own worktree (ADR-0007).
    /// working.html fakes the remotes; here they come from real git (GitService.allBranches).
    func worktreeFrame(in workspace: Workspace?) -> PaletteFrame {
        // Kick off the off-main git read; `build` reads from the cache as it fills, so the
        // frame opens instantly and populates when branches arrive. Per-keystroke `build`
        // stays allocation-only.
        if let ws = workspace { loadBranches(for: ws) }
        let shown = Set(workspace?.branches.map(\.name) ?? [])
        return PaletteFrame(crumb: "New worktree", placeholder: "Search branches to check out…",
                            mode: .input, dashSpaces: true) { [self] q in
            let v = q.trimmingCharacters(in: .whitespaces)
            guard !v.isEmpty, let ws = workspace else { return [] }
            let all = branchCache[ws.id] ?? []
            var items = all
                .filter { !shown.contains($0.name) }
                .compactMap { b -> (GitService.BranchRef, Double)? in
                    fuzzyScore(v, b.name).map { (b, $0) }
                }
                .sorted { $0.1 > $1.1 }
                .prefix(5)
                .map { b, _ in
                    PaletteItem(icon: .phosphor(Phosphor.branch), label: b.name,
                                ctx: b.isRemote ? (b.remote ?? "origin") : "local",
                                enter: { self.runAndClose {
                                    self.store.createWorktree(in: ws, existingBranch: b.name)
                                } })
                }
            // Fallback: the typed query isn't an existing branch → offer cutting a fresh one.
            if !all.contains(where: { $0.name == v }) {
                items.append(PaletteItem(icon: .phosphor(Phosphor.plus), label: "New branch “\(v)”",
                            enter: { self.runAndClose {
                                self.store.createWorktree(in: ws, newBranch: v, base: nil)
                            } }))
            }
            return items
        }
    }
}

extension SessionStatus {
    // working.html's STATE_LABEL + .cmdk__meta--* colours.
    var paletteLabel: String {
        switch self {
        case .running:       return "running"
        case .working:       return "working"
        case .needsInput:    return "needs input"
        case .error:         return "error"
        case .idle, .exited: return "idle"
        }
    }
    var paletteColor: Color {
        switch self {
        case .running:       return Theme.dyn(0x2EA043, 0x34C759)
        case .working:       return Theme.dyn(0xC8811A, 0xF5A623)
        case .needsInput:    return Theme.input
        case .error:         return Theme.dyn(0xD13C2F, 0xFF453A)
        case .idle, .exited: return Theme.navLabel
        }
    }
}

// MARK: - View

/// One rendered row of the palette list: text headers between search groups,
/// thin dividers between a frame's sections, and the items themselves.
private enum PaletteRow: Identifiable {
    case header(String)
    case divider(Int)
    case item(Int, PaletteItem)

    var id: String {
        switch self {
        case let .header(g): return "h-\(g)"
        case let .divider(i): return "d-\(i)"
        case let .item(i, _): return "i-\(i)"
        }
    }
}

struct PaletteOverlay: View {
    @Environment(AppStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let model: PaletteModel

    @State private var shown = false
    @FocusState private var focused: Bool

    private var rows: [PaletteRow] {
        var rows: [PaletteRow] = []
        var lastGroup: String?
        var lastSec: String?
        for (i, it) in model.items.enumerated() {
            if let g = it.group, g != lastGroup {
                rows.append(.header(g)); lastGroup = g; lastSec = it.sec
            } else if let s = it.sec, s != lastSec {
                if i > 0 { rows.append(.divider(i)) }
                lastSec = s
            }
            rows.append(.item(i, it))
        }
        return rows
    }

    var body: some View {
        @Bindable var model = model
        GeometryReader { geo in
            ZStack(alignment: .top) {
                Color.black.opacity(0.16)
                    .contentShape(Rectangle())
                    .onTapGesture { store.closePalette() }

                panel
                    .frame(width: 560)
                    .scaleEffect(shown ? 1 : 0.98)
                    .offset(y: shown ? 0 : -8)
                    .opacity(shown ? 1 : 0)
                    .padding(.top, geo.size.height * 0.14)
            }
            .ignoresSafeArea()
        }
        .opacity(shown ? 1 : 0)
        .onAppear {
            focused = true
            if reduceMotion { shown = true }
            else { withAnimation(.easeOut(duration: 0.2)) { shown = true } }
        }
    }

    private var panel: some View {
        @Bindable var model = model
        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                Phos(path: Phosphor.search, size: 17).foregroundStyle(Theme.navLabel)
                let crumbs = model.stack.enumerated().filter { $0.element.crumb != nil }
                if !crumbs.isEmpty {
                    HStack(spacing: 5) {
                        ForEach(crumbs, id: \.offset) { depth, frame in
                            CrumbChip(text: frame.crumb ?? "") { model.pop(to: depth) }
                        }
                    }
                }
                TextField(model.frame.placeholder, text: Binding(
                    get: { model.query },
                    set: { model.query = model.frame.dashSpaces ? dashSpaces($0) : $0 }))
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.repoName)
                    .focused($focused)
                    .onChange(of: model.stack.count) {
                        focused = true
                        // A seeded rename frame pre-fills the name — select it so a keystroke
                        // replaces (working.html pushFrame → input.select()).
                        if model.frame.seed != nil {
                            DispatchQueue.main.async {
                                (NSApp.keyWindow?.firstResponder as? NSTextView)?.selectAll(nil)
                            }
                        }
                    }
            }
            .padding(.horizontal, 16).padding(.vertical, 13)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Theme.border).frame(height: 0.5)
            }

            list
        }
        .background(
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                Theme.glass
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.line, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.1), radius: 3, y: 1)
        .shadow(color: .black.opacity(0.28), radius: 60, y: 24)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if model.items.isEmpty {
                        Text("No results")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.navLabel)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                    } else {
                        ForEach(rows) { row in
                            switch row {
                            case let .header(g):
                                Text(g.uppercased())
                                    .font(.system(size: 10, weight: .semibold)).kerning(0.5)
                                    .foregroundStyle(Theme.navLabel)
                                    .padding(.horizontal, 8).padding(.top, 10).padding(.bottom, 4)
                            case .divider:
                                Rectangle().fill(Theme.border).frame(height: 0.5)
                                    .padding(.horizontal, 8).padding(.vertical, 5)
                            case let .item(i, it):
                                PaletteItemRow(item: it, active: i == model.activeIndex) {
                                    model.activeIndex = i
                                    model.runActive()
                                } onHover: {
                                    if model.activeIndex != i { model.activeIndex = i }
                                }
                                .id(i)
                            }
                        }
                    }
                }
                .padding(6)
            }
            .frame(maxHeight: 340)
            .fixedSize(horizontal: false, vertical: true)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: model.items.count)
            .onChange(of: model.activeIndex) { _, i in
                guard model.consumeScrollToActive() else { return }
                proxy.scrollTo(i, anchor: nil)
            }
        }
    }
}

private struct CrumbChip: View {
    let text: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Theme.ink2)
                .lineLimit(1)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(hovering ? Theme.rowSelected : Theme.rowHover)
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border, lineWidth: 0.5))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct PaletteItemRow: View {
    let item: PaletteItem
    let active: Bool
    let action: () -> Void
    let onHover: () -> Void

    private var labelColor: Color {
        if item.danger { return Theme.danger }
        return active ? Theme.paletteActive : Theme.repoName
    }

    var body: some View {
        HStack(spacing: 10) {
            iconView
                .frame(width: 20)
            Text(item.label)
                .font(.system(size: 13.5))
                .foregroundStyle(labelColor)
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
            if let ctx = item.ctx, !ctx.isEmpty {
                Text(ctx)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.inkMeta)
                    .lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: 210, alignment: .trailing)
            }
            if let meta = item.meta {
                Text(meta)
                    .font(.system(size: 11)).kerning(0.1)
                    .foregroundStyle(item.metaColor ?? Theme.inkMeta)
            }
            if let kbd = item.kbd {
                KeyCaps(keys: kbd)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(active ? (item.danger ? Theme.danger.opacity(0.1) : Theme.accent.opacity(0.1)) : .clear)
        )
        .opacity(item.disabled ? 0.45 : 1)
        .contentShape(Rectangle())
        .onTapGesture { if !item.disabled { action() } }
        .onContinuousHover { phase in
            if case .active = phase { onHover() }
        }
    }

    @ViewBuilder private var iconView: some View {
        switch item.icon {
        case let .phosphor(path):
            Phos(path: path, size: 16)
                .foregroundStyle(item.danger ? Theme.danger : Theme.ink4)
        case let .session(kind):
            SessionIcon(kind: kind, size: 16, tint: item.danger ? Theme.danger : nil)
        case let .chip(text, color):
            RoundedRectangle(cornerRadius: 5).fill(color).frame(width: 16, height: 16)
                .overlay(Text(text).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.white))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5))
        }
    }
}
