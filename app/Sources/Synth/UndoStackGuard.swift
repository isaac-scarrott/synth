import AppKit
import SwiftUI

/// Empties the window's NSUndoManager whenever focus leaves a text view. AppKit text views and
/// SwiftUI's TextEditor register their undo actions on the window's manager with unretained
/// targets, and a sheet or pane torn down mid-history leaves entries pointing at freed objects —
/// the next ⌘Z to reach them is an EXC_BAD_ACCESS in `popAndInvoke` (21 Aug 2026). Focus always
/// moves off a text view before or as it dies, so clearing here drops the entries while their
/// targets are still alive. Undo history is per focus session; nothing else in the window has an
/// undo stack to lose. A zero-size probe, like PalettePresenter.
struct UndoStackGuard: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { context.coordinator.adopt(view.window) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { context.coordinator.adopt(view.window) }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor final class Coordinator {
        private weak var window: NSWindow?
        private var observation: NSKeyValueObservation?

        func adopt(_ window: NSWindow?) {
            guard let window, window !== self.window else { return }
            self.window = window
            observation = window.observe(\.firstResponder) { window, _ in
                let fr = window.firstResponder
                guard !(fr is NSText || fr is NSTextView) else { return }
                window.undoManager?.removeAllActions()
            }
        }
    }
}
