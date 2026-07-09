import SwiftUI
import AppKit

/// Puts the window's traffic lights on working.html's `.traffic` axis: 12pt circles 20pt from the
/// leading edge, centred in the `Theme.titlebarHeight` band.
///
/// AppKit's own placement is a 28pt titlebar with the lights at x=8, centre y=14 — too high and too
/// close to the rounded corner once the band is 50pt. Two approaches don't work: an empty unified
/// `NSToolbar` gets AppKit to re-centre them for free, but its `NSToolbarView` then swallows every
/// click across the band (the sidebar toggle stops responding); moving the buttons without growing
/// `NSTitlebarView` leaves them outside its bounds, where they still draw but no longer hit-test.
///
/// So grow the titlebar container to the band height and re-place the buttons inside it. AppKit
/// resets both on every relayout, so the container tells us when it has been reset and we redo the
/// work. Fullscreen is left alone: there the titlebar is an auto-hiding overlay AppKit owns.
struct WindowChrome: NSViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = PassthroughView()
        DispatchQueue.main.async { context.coordinator.adopt(view.window) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { context.coordinator.adopt(view.window) }
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.release()
    }

    /// Zero-sized and click-through: it exists only to hand us the NSWindow.
    private final class PassthroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    final class Coordinator {
        private weak var window: NSWindow?
        private var tokens: [NSObjectProtocol] = []

        func adopt(_ window: NSWindow?) {
            guard let window, window !== self.window else { return }
            release()
            self.window = window

            // The container is reset to AppKit's 28pt on relayout; that reset is our cue to redo
            // the placement, which covers live resize, fullscreen exit and appearance changes alike.
            if let container = Self.titlebarContainer(of: window) {
                container.postsFrameChangedNotifications = true
                observe(NSView.frameDidChangeNotification, object: container)
            }
            observe(NSWindow.didResizeNotification, object: window)
            observe(NSWindow.didExitFullScreenNotification, object: window)
            observe(NSWindow.didBecomeKeyNotification, object: window)
            place(in: window)
        }

        func release() {
            tokens.forEach(NotificationCenter.default.removeObserver)
            tokens = []
            window = nil
        }

        private func observe(_ name: Notification.Name, object: Any) {
            tokens.append(NotificationCenter.default.addObserver(
                forName: name, object: object, queue: .main
            ) { [weak self] _ in
                guard let window = self?.window else { return }
                self?.place(in: window)
            })
        }

        private static func titlebarContainer(of window: NSWindow) -> NSView? {
            window.standardWindowButton(.closeButton)?.superview?.superview
        }

        /// Idempotent: every write is guarded, so the frame-change notification our own resize
        /// posts finds nothing left to do and the loop stops after one pass.
        private func place(in window: NSWindow) {
            guard !window.styleMask.contains(.fullScreen),
                  let close = window.standardWindowButton(.closeButton),
                  let titlebar = close.superview,
                  let container = titlebar.superview,
                  let frameView = container.superview
            else { return }

            let band = Theme.titlebarHeight
            let wanted = NSRect(x: 0, y: frameView.bounds.height - band,
                                width: frameView.bounds.width, height: band)
            if container.frame != wanted { container.frame = wanted }
            if titlebar.frame != container.bounds { titlebar.frame = container.bounds }

            let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
            for (i, kind) in buttons.enumerated() {
                guard let button = window.standardWindowButton(kind) else { continue }
                // The 12pt circle is centred in a 14x16 button view, so it starts 1pt in.
                let origin = NSPoint(
                    x: Theme.trafficLightInset - 1 + CGFloat(i) * Theme.trafficLightPitch,
                    y: (band - button.frame.height) / 2
                )
                if button.frame.origin != origin { button.setFrameOrigin(origin) }
            }
        }
    }
}
