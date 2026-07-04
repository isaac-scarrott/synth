import SwiftUI
import AppKit
import SwiftTerm

@main
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
            CommandGroup(after: .newItem) {
                Button("New Terminal") { store.newTerminal() }
                    .keyboardShortcut("t", modifiers: .command)
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
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
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

            if store.sidebarCollapsed {
                IconButton(path: Phosphor.sidebar, help: "Expand sidebar") {
                    store.sidebarCollapsed = false
                }
                .padding(.top, Theme.titlebarInset - 8)
                .padding(.leading, 84)
                .transition(.opacity)
            }
        }
        .ignoresSafeArea()
        // Appearance: nil follows the OS (System), else pins light/dark. Working.html parity.
        .preferredColorScheme(store.colorSchemeOverride)
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
        .onAppear(perform: installKeyMonitor)
        .onDisappear { if let m = keyMonitor { NSEvent.removeMonitor(m) } }
    }

    /// Global keyboard nav — mirrors working.html's document keydown, but defers to
    /// the terminal, text fields, and open sheets so they keep their own keys.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        // Any mouse movement dismisses the keyboard selection ring (working.html).
        NSApp.windows.forEach { $0.acceptsMouseMovedEvents = true }
        NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { event in
            if store.keyboardActive { store.keyboardActive = false }
            return event
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Modal Esc must win even while its text field is first responder.
            if store.creatingWorktreeIn != nil || store.pendingWorkspace != nil {
                if event.keyCode == 53 {   // Esc closes the modal
                    store.creatingWorktreeIn = nil
                    store.pendingWorkspace = nil
                    return nil
                }
                return event
            }
            let key = event.charactersIgnoringModifiers?.lowercased()

            // ⌘/ (⌘?) toggles the shortcuts sheet from anywhere; while open it owns
            // the keyboard — Esc closes, everything else is swallowed (working.html).
            if (key == "/" || key == "?"), event.modifierFlags.contains(.command) {
                if store.shortcutsOpen { store.shortcutsOpen = false }
                else {
                    if store.palette != nil { store.closePalette() }
                    store.activeMenu = nil
                    store.shortcutsOpen = true
                }
                return nil
            }
            if store.shortcutsOpen {
                if event.keyCode == 53 { store.shortcutsOpen = false }
                return nil
            }

            // ⌘K toggles the palette from anywhere — even over the terminal.
            if key == "k", event.modifierFlags.contains(.command) {
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

            // ⌘, toggles Settings (the Mac Preferences convention); Esc leaves it.
            // Handled before the text/terminal passthrough so it wins over a focused editor.
            if key == ",", event.modifierFlags.contains(.command) {
                store.toggleSettings(); return nil
            }
            if event.keyCode == 53, store.settingsOpen {   // Esc leaves settings
                store.exitSettings(); return nil
            }

            // ⌘0 focuses the sidebar, ⌘1 the open session's content — even over the
            // terminal, so focus can bounce between panes without the mouse.
            if event.modifierFlags.contains(.command), key == "0" {
                store.sidebarCollapsed = false
                focusSidebar()
                store.keyboardActive = true
                // Ring lands on a *visible* row: current selection, else the open
                // session, else the first row (working.html focusSidebar).
                let visible = store.visibleRows.map(\.id)
                store.navCursor = [store.navCursor, store.openSessionID]
                    .compactMap { $0 }.first { visible.contains($0) } ?? store.visibleRows.first?.id
                return nil
            }
            if event.modifierFlags.contains(.command), key == "1" {
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
            if let fr = event.window?.firstResponder {
                if fr is TerminalView || fr is NSText || fr is NSTextView { return event }
            }
            // Ctrl+K also opens the palette when closed (only outside text/terminal focus,
            // so the shell keeps its own Ctrl+K).
            if key == "k", event.modifierFlags.contains(.control) {
                store.openPalette(); return nil
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
                case "j": store.moveCursor(1); return nil
                case "k": store.moveCursor(-1); return nil
                case "l" where bare: store.expandOrIn(); return nil     // vim expand-or-in
                case "h" where bare: store.collapseOrOut(); return nil  // vim collapse-or-out
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
