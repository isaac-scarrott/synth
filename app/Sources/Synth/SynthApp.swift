import SwiftUI
import AppKit

// Entry point lives in SynthMain.swift (adds the --browser-check mode around this App).
struct SynthApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = AppStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .frame(minWidth: 760, minHeight: 480)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesButton()
                Button("Settings…") { store.toggleSettings() }
                    .keyboardShortcut(",", modifiers: .command)
                Button("Changelog") { store.openChangelog() }
            }
            // Replaces the stock "New Window" so ⌘N means "new session" app-wide: the
            // picker working.html's `a` offers on a sidebar row, resolved from context.
            CommandGroup(replacing: .newItem) {
                Button("New Session…") { store.newSessionPicker() }
                    .keyboardShortcut("n", modifiers: .command)
                Button("New Terminal") { store.newTerminal() }
                    .keyboardShortcut("t", modifiers: .command)
                Divider()
                // ⌘D closes the current context — the focused sidebar row when the keyboard
                // owns the sidebar, else the open session — through the same flow as `d`.
                Button("Close Session") { store.closeContext() }
                    .keyboardShortcut("d", modifiers: .command)
            }
            CommandGroup(after: .sidebar) {
                Button("Toggle Sidebar") { store.sidebarCollapsed.toggle() }
                    .keyboardShortcut("b", modifiers: .command)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // Anonymous usage analytics — off on the dev channel and honouring the saved opt-out
        // (read straight from defaults so it doesn't wait on the store). No-ops until a key is set.
        Analytics.bootstrap(optedOut: !AppStore.loadBoolPref(AppStore.analyticsKey, default: true))
        // Crash capture: install the handlers, then report any marker the previous run left behind
        // (after bootstrap, so an `app_crashed` event has somewhere to go).
        CrashReporter.install()
        CrashReporter.reportPending()
        // Finish any fast delete a crash interrupted (folders renamed aside but never rm'd).
        Task.detached(priority: .background) { GitService.sweepDetachedWorktrees() }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// A genuine user quit confirms — ⌘Q and the Quit menu route here. One dialog, the same
    /// shape every time: "Quit Synth?" with **Quit Synth** (default, Return) and **Cancel**
    /// (Esc). Only the informative line changes, to name any busy sessions the quit would end.
    ///
    /// Non-interactive quits skip the dialog entirely and fall straight through to willTerminate
    /// save+cleanup: a signal-driven quit (SIGTERM / harness relaunch) sets `AppTermination.forceQuit`
    /// before terminating (CEFEngine.swift), and an OS logout/restart/shutdown is detected here.
    /// Presenting a modal on those paths would stack over a force-kill and lose the save.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if AppTermination.forceQuit || isSystemDrivenQuit() { return .terminateNow }
        // A confirm is already on screen (e.g. a stray second terminate arriving through the
        // modal's nested run loop): don't stack another dialog — let the in-flight one decide.
        if AppTermination.confirming { return .terminateCancel }
        AppTermination.confirming = true
        defer { AppTermination.confirming = false }

        let busy = AppStore.shared?.busySessions.count ?? 0

        let alert = NSAlert()
        alert.messageText = "Quit Synth?"
        alert.informativeText = switch busy {
        case 0:  "This closes every session."
        case 1:  "A session is still busy — quitting ends it and its work in progress is lost."
        default: "\(busy) sessions are still busy — quitting ends them and their work in progress is lost."
        }
        alert.addButton(withTitle: "Quit Synth")   // default: Return quits
        alert.addButton(withTitle: "Cancel")        // Esc cancels
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    /// True when the quit came from an OS logout/restart/shutdown rather than a user ⌘Q: the
    /// Apple event carries a `kAEQuitReason` ('why?') attribute only on those system paths.
    private func isSystemDrivenQuit() -> Bool {
        NSAppleEventManager.shared().currentAppleEvent?
            .attributeDescriptor(forKeyword: AEKeyword(0x7768793F)) != nil
    }
}

/// Termination state shared with the CEF signal handler (CEFEngine.swift). Signal- and
/// logout-driven quits must reach willTerminate's save+cleanup without an interactive modal;
/// `forceQuit` tells `applicationShouldTerminate` to bypass the confirm, and `confirming`
/// guards against a second dialog stacking while one is already presented.
@MainActor
enum AppTermination {
    static var forceQuit = false
    static var confirming = false
}

/// Reverse-DNS identity behind both channels' bundle ids (dist.sh, dev.sh, bundle-cef.sh) and
/// every os_log subsystem. The `.dev` suffix is what separates the channels; this is the stem.
let bundleIdentifier = "io.github.isaac-scarrott.synth"

/// True on the development channel (bundle id ends `.dev`, set by dev.sh). Gates the DEV tag.
let isDevChannel = Bundle.main.bundleIdentifier?.hasSuffix(".dev") ?? false

/// Development-build tag — the native mirror of working.html's `.dev-tag`. Sits at the
/// window's top-right on the traffic-light axis, amber to match the Synth Dev icon; never
/// shown on the stable "Synth" build.
private struct DevTagBadge: View {
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(Theme.working).frame(width: 5, height: 5)
            Text("DEV")
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .tracking(1.4)
                .foregroundStyle(Theme.working)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 3)
        .background(Theme.working.opacity(0.13), in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.working.opacity(0.5), lineWidth: 1))
        // Shares the pane header's 18pt trailing gutter; the caller centres it in the band.
        .padding(.trailing, 18)
        .allowsHitTesting(false)
    }
}

struct RootView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var keyMonitor: Any?

    var body: some View {
        @Bindable var store = store
        ZStack(alignment: .topLeading) {
            Theme.canvas.ignoresSafeArea()

            HStack(spacing: 0) {
                if !store.sidebarCollapsed {
                    Sidebar()
                        .frame(width: store.sidebarWidth)
                        .background(Theme.sidebar)
                        .clipShape(.rect(topLeadingRadius: 0, bottomLeadingRadius: 0,
                                         bottomTrailingRadius: Theme.radiusPanel,
                                         topTrailingRadius: Theme.radiusPanel))
                        .shadow(color: .black.opacity(0.03), radius: 14, x: 4)
                        .shadow(color: .black.opacity(0.02), radius: 1, x: 1)
                        .zIndex(1)
                        .overlay(alignment: .trailing) { SidebarResizeHandle() }
                        .transition(.move(edge: .leading))
                }
                ContentPane()
            }
            .background(Theme.panel)
            // Fill the native window edge-to-edge — the real window supplies the frame +
            // rounded corners, so the mock's floating-card inset/border/shadow (which read
            // as a grey margin) are dropped here.
            .animation(reduceMotion ? nil : .easeOut(duration: 0.24), value: store.sidebarCollapsed)

            // When collapsed with no header to host the toggle (the empty "No session" state),
            // float it at the top-left on the traffic-light axis. The session/settings
            // headers carry their own inline toggle.
            if store.sidebarCollapsed, store.openSession == nil, !store.settingsOpen {
                SidebarToggle()
                    .padding(.top, (Theme.titlebarHeight - SidebarToggle.box) / 2)
                    .padding(.leading, Theme.trafficLightsClearance)
                    .transition(.opacity)
            }
        }
        .ignoresSafeArea()
        // The free-floating session drag ghost, at the window root so it floats over both panes.
        .overlay(alignment: .topLeading) { DragGhost() }
        .background(WindowChrome().frame(width: 0, height: 0))
        // Appearance: nil follows the OS (System), else pins light/dark. Working.html parity.
        .preferredColorScheme(store.colorSchemeOverride)
        // Band-height row rather than a top inset: the tag centres on the traffic-light axis
        // whatever its intrinsic height turns out to be.
        .overlay(alignment: .top) {
            if isDevChannel {
                HStack(spacing: 0) { Spacer(minLength: 0); DevTagBadge() }
                    .frame(height: Theme.titlebarHeight)
            }
        }
        .overlay {
            if let ws = store.creatingWorktreeIn {
                ModalBackdrop(onDismiss: { store.creatingWorktreeIn = nil }) {
                    CreateWorktreeSheet(workspace: ws, onClose: { store.creatingWorktreeIn = nil })
                        .environment(store)
                }
            }
        }
        .overlay {
            if let pending = store.pendingWorkspace {
                ModalBackdrop(onDismiss: { store.pendingWorkspace = nil }) {
                    AddWorktreesSheet(pending: pending, onClose: { store.pendingWorkspace = nil })
                        .environment(store)
                }
            }
        }
        .overlayPreferenceValue(MenuAnchorKey.self) { anchors in
            GeometryReader { proxy in
                if let m = store.activeMenu, let anchor = anchors[m.rowID] {
                    MenuOverlay(menu: m, kebabRect: proxy[anchor], container: proxy.size) {
                        store.activeMenu = nil
                    }
                    .environment(store)
                }
            }
        }
        .overlay {
            if let pal = store.palette {
                PaletteOverlay(model: pal)
                    .environment(store)
            }
        }
        .overlay {
            if store.shortcutsOpen {
                ModalBackdrop(onDismiss: { store.shortcutsOpen = false }) {
                    ShortcutsSheet()
                }
            }
        }
        .overlay {
            if store.changelogOpen {
                ModalBackdrop(onDismiss: { store.closeChangelog() }) {
                    ChangelogSheet()
                }
            }
        }
        .overlay {
            if store.feedbackOpen {
                ModalBackdrop(onDismiss: { store.feedbackOpen = false }) {
                    FeedbackSheet().environment(store)
                }
            }
        }
        .onAppear(perform: installKeyMonitor)
        .onAppear { NotificationService.shared.bootstrap(store: store) }
        // Refetch PR state whenever Synth comes forward — a branch merged or a PR opened
        // while the user was away shows up on their return (PRService reads are idempotent).
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            store.refreshPullRequests()
        }
        .onDisappear { if let m = keyMonitor { NSEvent.removeMonitor(m) } }
    }

    /// ⌘2…⌘9 digit key codes → pane number (US layout number row); nil otherwise.
    static func splitDigit(_ keyCode: UInt16) -> Int? {
        switch keyCode {
        case 18: return 1; case 19: return 2; case 20: return 3; case 21: return 4
        case 23: return 5; case 22: return 6; case 26: return 7; case 28: return 8; case 25: return 9
        default: return nil
        }
    }

    /// ⌘⌥ h/j/k/l spatial-focus aliases → arrow direction (left/down/up/right).
    static func splitHJKL(_ key: String?) -> ArrowDir? {
        switch key {
        case "h": return .left; case "j": return .down; case "k": return .up; case "l": return .right
        default:  return nil
        }
    }

    /// Global keyboard nav — mirrors working.html's document keydown, but defers to
    /// the terminal, text fields, and open sheets so they keep their own keys.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        // Any mouse movement dismisses the keyboard selection ring (working.html).
        NSApp.windows.forEach { $0.acceptsMouseMovedEvents = true }
        NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { event in
            if store.keyboardActive { store.keyboardActive = false }
            store.pointerStale = false
            return event
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Typing hides the pointer until the mouse next moves — AppKit auto-reveals it on the
            // next movement, so the cursor stays out of the way while Synth is driven by keyboard
            // (terminal keystrokes route through this local monitor too). Bare modifiers fire
            // flagsChanged, not keyDown, so a lone ⌘/⇧ never hides it.
            NSCursor.setHiddenUntilMouseMoves(true)
            store.pointerStale = true

            // Modal Esc must win even while its text field is first responder.
            if store.creatingWorktreeIn != nil || store.pendingWorkspace != nil || store.feedbackOpen {
                if event.keyCode == 53 {   // Esc closes the modal
                    store.creatingWorktreeIn = nil
                    store.pendingWorkspace = nil
                    store.feedbackOpen = false
                    return nil
                }
                return event   // ⌘↵ Send + typing pass through to the sheet
            }
            let key = event.charactersIgnoringModifiers?.lowercased()

            // ⌘↩ jumps to the most-urgent in-app notification — bound only while the deck is
            // non-empty, so the chord is never stolen otherwise (working.html notifTop).
            if event.modifierFlags.contains(.command), event.keyCode == 36 || event.keyCode == 76,
               store.topNotif != nil {
                store.jumpToTopNotif(); return nil
            }

            // ⌘⇧F opens the feedback sheet from anywhere — even over the terminal (like ⌘K).
            if key == "f", event.modifierFlags.contains(.command), event.modifierFlags.contains(.shift) {
                if store.palette != nil { store.closePalette() }
                store.activeMenu = nil
                store.feedbackOpen = true
                return nil
            }

            #if DEBUG
            // Notification harness (working.html's ⌥N demo): ⌥N grows the deck, ⌥D fires an
            // ambient "done", ⌥C clears. Add ⇧ to force the Notification Center path instead of
            // the in-app deck, so both surfaces are drivable when the instance isn't frontmost.
            if event.modifierFlags.contains(.option), let code = Optional(event.keyCode),
               code == 45 || code == 2 || code == 8 || code == 3 {
                let route: NotifRoute = event.modifierFlags.contains(.shift) ? .notificationCenter : .inApp
                switch code {
                case 45: store.debugRaiseNext(force: route)   // ⌥N
                case 2:  store.debugFireDone(force: route)     // ⌥D
                case 3:  store.debugDeckSpread.toggle()        // ⌥F  fan the deck
                default: store.debugClearNotifs()              // ⌥C
                }
                return nil
            }
            #endif

            // ⌘/ (⌘?) toggles the shortcuts sheet from anywhere; while open it owns
            // the keyboard — Esc closes, everything else is swallowed (working.html).
            if (key == "/" || key == "?"), event.modifierFlags.contains(.command) {
                if store.shortcutsOpen { store.shortcutsOpen = false }
                else {
                    if store.palette != nil { store.closePalette() }
                    store.activeMenu = nil
                    store.shortcutsCategory = 0
                    store.shortcutsOpen = true
                }
                return nil
            }
            if store.shortcutsOpen {
                // The sheet owns the keyboard: ↑/↓ (and j/k) walk the category sidebar, Esc closes.
                switch event.keyCode {
                case 53: store.shortcutsOpen = false
                case 125: store.moveShortcutsCategory(1)    // ↓
                case 126: store.moveShortcutsCategory(-1)   // ↑
                default:
                    switch key {
                    case "j": store.moveShortcutsCategory(1)
                    case "k": store.moveShortcutsCategory(-1)
                    default: break
                    }
                }
                return nil
            }
            // The changelog owns the keyboard while open, same as the shortcuts sheet — Esc
            // closes, everything else is swallowed.
            if store.changelogOpen {
                if event.keyCode == 53 { store.closeChangelog() }
                return nil
            }

            // ⌘K toggles the palette from anywhere — even over the terminal. Bare ⌘K only (no
            // Shift, no Option): ⌘⌥K is the split layer's focus-up (⌘⌥ h/j/k/l), and ⌘⇧K isn't a
            // binding — both must fall through to the split block below rather than open the palette.
            if key == "k", event.modifierFlags.contains(.command),
               !event.modifierFlags.contains(.shift), !event.modifierFlags.contains(.option) {
                if store.palette == nil { store.openPalette() } else { store.closePalette() }
                return nil
            }
            // The palette owns the keyboard while open (working.html): ↑/↓ + Ctrl+J/K
            // (+ Ctrl+N/P) move, Enter runs, Backspace on an empty query pops, Esc
            // closes. Ctrl+K means "up" here — only ⌘K closes.
            if let pal = store.palette {
                switch event.keyCode {
                case 53:  store.closePalette(); return nil   // Esc
                case 36, 76: pal.runActive(); return nil     // Return / keypad Enter
                case 125: pal.move(1); return nil            // ↓
                case 126: pal.move(-1); return nil           // ↑
                case 51:                                     // Backspace on empty → pop
                    if pal.query.isEmpty { pal.pop(); return nil }
                    return event
                default:
                    if event.modifierFlags.contains(.control) {
                        switch key {
                        case "j", "n": pal.move(1); return nil
                        case "k", "p": pal.move(-1); return nil
                        default: break
                        }
                    }
                    return event
                }
            }

            // ⌘, (Settings) is the menu item's keyboard shortcut now (Synth → Settings…),
            // so AppKit fires it — Esc still leaves Settings from anywhere, incl. a focused editor.
            if event.keyCode == 53, store.settingsOpen {   // Esc leaves settings
                store.exitSettings(); return nil
            }

            // ⌘0 focuses the sidebar, ⌘1 the open session's content — even over the
            // terminal, so focus can bounce between panes without the mouse.
            if event.modifierFlags.contains(.command), key == "0" {
                store.sidebarCollapsed = false
                focusSidebar()
                store.keyboardActive = true
                // Ring lands on a navigable row: keep the current cursor, else the open
                // session / active scope, else the first row (working.html focusSidebar).
                store.focusSidebarCursor()
                return nil
            }
            if event.modifierFlags.contains(.command), key == "1" {
                store.focusPane(1)   // pane 1 in reading order (a lone pane = the open session)
                focusContent(store)
                return nil
            }

            // Inline rename owns the keyboard: ↵ commits, Esc reverts, everything else
            // edits the focused field (working.html startRename).
            if store.renamingRowID != nil {
                switch event.keyCode {
                case 53:     store.cancelRename(); return nil     // Esc
                case 36, 76: store.commitRename(); return nil     // Return / keypad Enter
                default:     return event
                }
            }

            if let menu = store.activeMenu {
                if event.keyCode == 53 { store.activeMenu = nil; return nil }   // Esc closes menu
                // ↵ commits the removal while the menu is showing its delete confirm.
                if (event.keyCode == 36 || event.keyCode == 76), store.menuConfirming {
                    menu.onDelete(); store.activeMenu = nil; return nil
                }
                return event
            }
            // Esc exits browser comment mode (ADR-0011 stage three) — checked before the
            // page passthrough so it works while the page owns keys; the overlay's own
            // exitMode binding call flips the same state, so the button follows either path.
            if event.keyCode == 53, let open = store.openSession, open.kind == .browser,
               let cm = BrowserManager.shared.existing(open.id)?.commentMode, cm.engaged {
                Task { await cm.exit() }
                return nil
            }
            // ===== Split layout layer (007) — three arrow-families read as one grammar:
            // ⌘⌥ move · ⌘⌥⇧ resize · ⌘⇧ create; plus ⌘⇧⏎ zoom, ⌘⇧U unsplit, ⌘` cycle, ⌘2…9
            // focus-pane. Placed before the browser page-verbs so ⌘⌥L (focus-right alias) wins
            // while a bare ⌘L still reaches the omnibox. Arrow chords are scoped off a focused
            // text field so native ⌘⇧←/→ caret selection survives (use ⌘| / ⌘— / ⌘K there).
            if event.modifierFlags.contains(.command) {
                let shift = event.modifierFlags.contains(.shift)
                let opt = event.modifierFlags.contains(.option)
                let inField: Bool = {
                    guard let fr = event.window?.firstResponder else { return false }
                    return fr is NSText || fr is NSTextView
                }()
                let arrow: ArrowDir? = {
                    switch event.keyCode {
                    case 123: return .left;  case 124: return .right
                    case 125: return .down;  case 126: return .up
                    default:  return nil
                    }
                }()
                // Zoom ⌘⇧⏎ (⌘⏎ notification-jump stays unmoved, handled far above).
                if shift, !opt, event.keyCode == 36 || event.keyCode == 76 { store.toggleZoom(); return nil }
                // Unsplit ⌘⇧U — only when the active session is a member of a split.
                if shift, !opt, key == "u", let sid = store.activePane?.sessionID, store.inSplit(sid) {
                    store.unsplitSession(sid); return nil
                }
                // Cycle ⌘` next / ⌘⇧` previous (wraps).
                if !opt, event.keyCode == 50 { store.cyclePane(shift ? -1 : 1); return nil }
                // Focus pane N ⌘2…⌘9 by reading order (⌘0/⌘1 handled above).
                if !opt, !shift, let n = Self.splitDigit(event.keyCode), n >= 2 {
                    store.focusPane(n); focusContent(store); return nil
                }
                // Create aliases: ⌘| (⌘⇧\) side-by-side right · ⌘— (⌘⇧-) stacked below.
                if shift, !opt, event.keyCode == 42 { store.openSplitPicker(dir: .row, before: false); return nil }
                if shift, !opt, event.keyCode == 27 { store.openSplitPicker(dir: .col, before: false); return nil }
                if let a = arrow, !inField {
                    if opt, shift { store.resizeActive(a); return nil }                        // ⌘⌥⇧ resize
                    if opt        { store.focusDir(a); return nil }                            // ⌘⌥ focus
                    if shift      { store.openSplitPicker(dir: a.axis, before: a.before); return nil } // ⌘⇧ create
                }
                // ⌘⌥ h/j/k/l spatial focus (vim aliases; skip in a text field).
                if opt, !shift, !inField, let a = Self.splitHJKL(key) { store.focusDir(a); return nil }
            }

            // An open browser session claims the standard page verbs window-wide: ⌘L
            // address, ⌘R reload, ⌘[ / ⌘] history, ⌥⌘I DevTools — each presses the
            // visible toolbar control, so disabled states (home page, empty history)
            // are respected for free. Before the passthrough guard: a focused page
            // must not eat the chords (⌘-modified keys never edit text anyway).
            if event.modifierFlags.contains(.command),
               let open = store.openSession, open.kind == .browser,
               let ctrl = BrowserManager.shared.controller(for: open) {
                switch key {
                case "l":
                    ctrl.focusAddress(); return nil
                case "r" where !event.modifierFlags.contains(.shift):
                    if !ctrl.isHome { ctrl.reload() }; return nil
                case "[":
                    if ctrl.canGoBack { ctrl.goBack() }; return nil
                case "]":
                    if ctrl.canGoForward { ctrl.goForward() }; return nil
                case "i" where event.modifierFlags.contains(.option):
                    if !ctrl.isHome { ctrl.toggleDevTools() }; return nil
                case "m" where event.modifierFlags.contains(.shift):
                    if !ctrl.isHome { ctrl.toggleDeviceMode() }; return nil
                case "=", "+":
                    if !ctrl.isHome { ctrl.zoomIn() }; return nil
                case "-", "_":
                    if !ctrl.isHome { ctrl.zoomOut() }; return nil
                default: break
                }
            }
            if let fr = event.window?.firstResponder {
                if fr is GhosttySurfaceView || fr is NSText || fr is NSTextView { return event }
                // A focused browser page keeps its keys too (Space/Enter act in the page).
                if BrowserManager.shared.ownsFirstResponder(fr) { return event }
            }

            switch event.keyCode {
            case 53:                                         // Esc: hand focus to the main window
                focusContent(store); return nil
            case 48:                                         // Tab: toggle the group open/closed
                let bare = event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
                guard bare, store.cursorIsGroup else { return event }
                store.toggleGroup(); return nil
            case 125: store.moveCursor(1); return nil        // ↓
            case 126: store.moveCursor(-1); return nil       // ↑
            case 124: store.expandOrIn(); return nil         // →
            case 123: store.collapseOrOut(); return nil      // ←
            case 36, 49:                                     // return / space
                guard store.navCursor != nil else { return event }
                store.activateCursor(); return nil
            default:
                // r renames the selected row in place; d deletes it (through a confirm).
                // Both are bare letters — modified variants stay with the shell / earlier
                // handlers (working.html: !metaKey && !ctrlKey && !altKey).
                let bare = event.modifierFlags.intersection([.command, .control, .option]).isEmpty
                switch key {
                // ⇧J / ⇧K reorder the selected row within its sibling list (keyboard twin of
                // drag). Directions track the nav keys: ⇧J moves down (like j), ⇧K moves up
                // (like k). Only on a real tree row — cursorRef is nil in Settings and on the
                // Settings foot, guarding it there.
                case "j" where bare && event.modifierFlags.contains(.shift):
                    guard let ref = store.cursorRef else { return event }
                    store.reorder(ref, by: 1, animated: !reduceMotion); return nil
                case "k" where bare && event.modifierFlags.contains(.shift):
                    guard let ref = store.cursorRef else { return event }
                    store.reorder(ref, by: -1, animated: !reduceMotion); return nil
                case "j": store.moveCursor(1); return nil
                case "k": store.moveCursor(-1); return nil
                case "l" where bare: store.expandOrIn(); return nil     // vim expand-or-in
                case "h" where bare: store.collapseOrOut(); return nil  // vim collapse-or-out
                // a adds the cursor row's natural child, dropping into its ⌘K frame — a worktree
                // search under a workspace, a New-session choice under a worktree / session leaf.
                // No-ops off a real tree row (cursorRef is nil in Settings / on the foot button).
                case "a" where bare:
                    guard let ref = store.cursorRef else { return event }
                    store.addToRow(ref); return nil
                case "r" where bare:
                    guard let ref = store.cursorRef else { return event }
                    store.beginRename(ref); return nil
                case "d" where bare:
                    guard let ref = store.cursorRef else { return event }
                    store.requestDelete(ref); return nil
                default:  return event
                }
            }
        }
    }
}
