import AppKit

/// The switch the self-verify harness launches under (`app/harness/agents/lib.py` sets it on every
/// launch), and everything a driven build owes the person whose Mac it is running on.
///
/// A gate run is not a session. It happens on a real desktop, for minutes at a time, while its
/// owner is working in another window — so a driven Synth takes no Dock icon, no ⌘Tab slot, no
/// keyboard, no cursor, no screen, and posts no banners. Everything a gate needs to see already
/// comes back over the control socket (`automation.*`), which is why none of that costs coverage:
/// the run is answered in JSON, not in pixels the user has to look at.
enum Automation {
    static let isDriven = ProcessInfo.processInfo.environment["SYNTH_AUTOMATION"] == "1"

    /// Make a driven window drivable but unseeable (the app's own, and the ⌘K panel — every window
    /// the app puts up goes through here). Transparency is what does the work: the
    /// window stays ordered in, laid out and rendering at its natural size — `automation.screenshot`
    /// renders this window's content view, so a window ordered out or shrunk would take the visual
    /// evidence path with it — while the desktop it is running on shows nothing. (Moving it away
    /// instead doesn't hold: AppKit constrains a titled window's frame back onto a screen, which on
    /// a second display leaves a full window sitting in the open.)
    ///
    /// The rest is the belt: behind every real window, out of Mission Control and ⌘`, and deaf to
    /// the pointer, so a click that lands where it isn't goes to whatever is actually there.
    static func park(_ window: NSWindow) {
        guard isDriven else { return }
        // SwiftUI saves and restores the frame in the bundle's own defaults — the same domain the
        // developer's dev build reads on its next launch. A gate run has no business writing it.
        if !window.frameAutosaveName.isEmpty { window.setFrameAutosaveName("") }
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        window.collectionBehavior.formUnion([.transient, .ignoresCycle])
    }
}
