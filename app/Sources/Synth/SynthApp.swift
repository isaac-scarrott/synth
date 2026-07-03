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
                        .background(Theme.sidebar)
                        .clipShape(.rect(topLeadingRadius: 0, bottomLeadingRadius: 0,
                                         bottomTrailingRadius: Theme.radiusPanel,
                                         topTrailingRadius: Theme.radiusPanel))
                        .shadow(color: .black.opacity(0.03), radius: 14, x: 4)
                        .shadow(color: .black.opacity(0.02), radius: 1, x: 1)
                        .zIndex(1)
                        .transition(.move(edge: .leading))
                }
                ContentPane()
            }
            .background(Theme.panel)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusApp))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radiusApp)
                    .strokeBorder(Theme.borderStrong, lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.06), radius: 24, y: 8)
            .shadow(color: .black.opacity(0.04), radius: 2, y: 1)
            .padding(Theme.cardInset)
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
        .preferredColorScheme(.light)   // working.html is a light design; keep native chrome light
        .overlay {
            if let ws = store.creatingBranchIn {
                ModalBackdrop(onDismiss: { store.creatingBranchIn = nil }) {
                    CreateBranchSheet(workspace: ws, onClose: { store.creatingBranchIn = nil })
                        .environment(store)
                }
            } else if store.addingWorkspace {
                ModalBackdrop(onDismiss: { store.addingWorkspace = false }) {
                    AddWorkspaceSheet(onClose: { store.addingWorkspace = false })
                        .environment(store)
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
            if store.creatingBranchIn != nil || store.addingWorkspace {
                if event.keyCode == 53 {   // Esc closes the modal
                    store.creatingBranchIn = nil
                    store.addingWorkspace = false
                    return nil
                }
                return event
            }
            if let fr = event.window?.firstResponder {
                if fr is TerminalView || fr is NSText || fr is NSTextView { return event }
            }

            switch event.keyCode {
            case 125: store.moveCursor(1); return nil        // ↓
            case 126: store.moveCursor(-1); return nil       // ↑
            case 124: store.expandOrIn(); return nil         // →
            case 123: store.collapseOrOut(); return nil      // ←
            case 36, 49:                                     // return / space
                guard store.navCursor != nil else { return event }
                store.activateCursor(); return nil
            default:
                switch event.charactersIgnoringModifiers {
                case "j": store.moveCursor(1); return nil
                case "k": store.moveCursor(-1); return nil
                default:  return event
                }
            }
        }
    }
}
