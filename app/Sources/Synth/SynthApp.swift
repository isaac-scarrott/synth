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
                Button { store.sidebarCollapsed = false } label: {
                    Image(systemName: "sidebar.left")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.inkMuted)
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.panel))
                }
                .buttonStyle(.plain)
                .padding(.top, Theme.titlebarInset - 6)
                .padding(.leading, 88)
                .transition(.opacity)
            }
        }
        .ignoresSafeArea()
        .sheet(item: $store.creatingBranchIn) { ws in
            CreateBranchSheet(workspace: ws).environment(store)
        }
        .sheet(isPresented: $store.addingWorkspace) {
            AddWorkspaceSheet().environment(store)
        }
        .onAppear(perform: installKeyMonitor)
        .onDisappear { if let m = keyMonitor { NSEvent.removeMonitor(m) } }
    }

    /// Global keyboard nav — mirrors working.html's document keydown, but defers to
    /// the terminal, text fields, and open sheets so they keep their own keys.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if let fr = event.window?.firstResponder {
                if fr is TerminalView || fr is NSText || fr is NSTextView { return event }
            }
            if store.creatingBranchIn != nil || store.addingWorkspace { return event }

            switch event.keyCode {
            case 125: store.moveCursor(1); return nil        // ↓
            case 126: store.moveCursor(-1); return nil       // ↑
            case 124: store.expandOrIn(); return nil         // →
            case 123: store.collapseOrOut(); return nil      // ←
            case 36, 49:                                     // return / space
                guard store.keyboardActive else { return event }
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
