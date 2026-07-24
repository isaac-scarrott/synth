import AppKit
import SwiftUI

/// The ⌘K palette lives in its own borderless `NSPanel` rather than as a SwiftUI overlay on the
/// main window. Reason is speed, not looks: making the palette's text field first responder
/// triggers AppKit's password-autofill heuristic, which gathers every focusable key-view in the
/// field's window (`NSHostingView._recursiveGatherAllKeyViewCandidates` → `FocusNavigator.allItems`,
/// a per-node protocol-conformance walk). The key-view loop is per-window, so in the main window
/// that walk crosses the whole app tree — sidebar rows + every open pane — and costs ~250ms on a
/// loaded session, stalling the open. Hosted here the walk sees only the palette's own small tree,
/// so it's negligible. The panel tracks the main window's frame and hands key back on close.
@MainActor
final class PaletteHost {
    private var panel: NSPanel?
    private var shownModel: ObjectIdentifier?
    private var resizeObserver: NSObjectProtocol?
    private var moveObserver: NSObjectProtocol?

    /// Present `model`'s palette over `parent`, or update the hosted model if one is already up.
    func show(model: PaletteModel, store: AppStore, over parent: NSWindow) {
        let id = ObjectIdentifier(model)
        if panel != nil {
            // Same open, a re-render — nothing to do. A model swap while open (rare: none of the
            // open paths replace the instance) rebuilds the content.
            if shownModel == id { return }
            hide()
        }
        let p = PalettePanel(
            contentRect: parent.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = parent.level
        p.hidesOnDeactivate = false
        p.isMovableByWindowBackground = false
        p.animationBehavior = .none
        let host = NSHostingView(rootView: PaletteWindowContent(model: model, store: store))
        host.autoresizingMask = [.width, .height]
        p.contentView = host
        p.setFrame(parent.frame, display: false)
        // An NSPanel (unlike a child NSWindow) leaves the parent as the *main* window while it
        // takes key — so the parent's traffic lights stay active-coloured, as before. It just
        // needs to track the parent's frame by hand.
        p.order(.above, relativeTo: parent.windowNumber)
        p.makeKeyAndOrderFront(nil)
        panel = p
        shownModel = id
        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: parent, queue: .main
        ) { [weak self, weak parent] _ in
            guard let parent else { return }
            MainActor.assumeIsolated { self?.panel?.setFrame(parent.frame, display: true) }
        }
        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: parent, queue: .main
        ) { [weak self, weak parent] _ in
            guard let parent else { return }
            MainActor.assumeIsolated { self?.panel?.setFrame(parent.frame, display: true) }
        }
    }

    /// Tear the panel down; AppKit restores key to the previous key window (the main window) when
    /// the panel orders out.
    func hide() {
        guard let p = panel else { return }
        if let o = resizeObserver { NotificationCenter.default.removeObserver(o); resizeObserver = nil }
        if let o = moveObserver { NotificationCenter.default.removeObserver(o); moveObserver = nil }
        p.orderOut(nil)
        panel = nil
        shownModel = nil
    }
}

/// Borderless panels don't take key by default; the palette's search field can't edit without it.
final class PalettePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private struct PaletteWindowContent: View {
    let model: PaletteModel
    let store: AppStore
    var body: some View {
        PaletteOverlay(model: model)
            .environment(store)
            // The panel is a fresh view tree; carry the app's light/dark pin into it.
            .preferredColorScheme(store.colorSchemeOverride)
    }
}

/// A zero-size probe living in the main window's tree: it reads `store.palette`, so SwiftUI
/// re-runs `updateNSView` whenever it flips, and drives the child window from AppKit — keeping
/// the palette out of the main window's key-view loop while its lifecycle stays reactive.
struct PalettePresenter: NSViewRepresentable {
    let palette: PaletteModel?
    let store: AppStore

    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ view: NSView, context: Context) {
        let host = context.coordinator
        let model = palette
        // `view.window` is nil until SwiftUI inserts the probe, and a fresh palette needs the
        // window laid out; defer a turn so both are ready.
        DispatchQueue.main.async {
            if let model, let parent = view.window {
                host.show(model: model, store: store, over: parent)
            } else if model == nil {
                host.hide()
            }
        }
    }

    func makeCoordinator() -> PaletteHost { PaletteHost() }

    static func dismantleNSView(_ view: NSView, coordinator: PaletteHost) {
        coordinator.hide()
    }
}
