import AppKit
import GhosttyKit

/// Per-surface context handed to libghostty as `surface_config.userdata` and recovered in
/// the surface-scoped runtime callbacks (close, clipboard) and in child-exit actions. Ties
/// a libghostty surface back to its Synth session + view.
final class GhosttySurfaceContext {
    let sessionID: UUID
    weak var view: GhosttySurfaceView?
    weak var bus: EventBus?

    init(sessionID: UUID, view: GhosttySurfaceView, bus: EventBus?) {
        self.sessionID = sessionID
        self.view = view
        self.bus = bus
    }

    /// Recover the context from a surface-scoped callback's userdata without consuming the
    /// retain (the surface still owns it until it's freed).
    static func from(_ userdata: UnsafeMutableRawPointer?) -> GhosttySurfaceContext? {
        guard let userdata else { return nil }
        return Unmanaged<GhosttySurfaceContext>.fromOpaque(userdata).takeUnretainedValue()
    }

    /// The session's shell process ended — the one derived fact terminal sessions post
    /// onto the bus (docs/adr/0001), mirroring the old SwiftTerm supervisor.
    func postExited(_ exitCode: Int32?) {
        let id = sessionID
        let bus = self.bus
        DispatchQueue.main.async { bus?.post(.exited(id, exitCode)) }
    }
}

/// Bridges libghostty's clipboard callbacks to NSPasteboard so copy/paste and OSC 52 work.
/// All callbacks fire on the main thread during `ghostty_app_tick`.
enum GhosttyClipboard {
    static func read(
        _ userdata: UnsafeMutableRawPointer?, _ location: ghostty_clipboard_e,
        _ state: UnsafeMutableRawPointer?
    ) -> Bool {
        guard let ctx = GhosttySurfaceContext.from(userdata),
              let surface = ctx.view?.surface else { return false }
        let text = NSPasteboard.general.string(forType: .string) ?? ""
        text.withCString { ghostty_surface_complete_clipboard_request(surface, $0, state, true) }
        return true
    }

    static func confirmRead(
        _ userdata: UnsafeMutableRawPointer?, _ str: UnsafePointer<CChar>?,
        _ state: UnsafeMutableRawPointer?, _ request: ghostty_clipboard_request_e
    ) {
        guard let ctx = GhosttySurfaceContext.from(userdata),
              let surface = ctx.view?.surface else { return }
        // Synth trusts its own sessions; complete OSC 52 reads without a prompt.
        ghostty_surface_complete_clipboard_request(surface, str, state, true)
    }

    static func write(
        _ userdata: UnsafeMutableRawPointer?, _ location: ghostty_clipboard_e,
        _ content: UnsafePointer<ghostty_clipboard_content_s>?, _ count: Int, _ confirm: Bool
    ) {
        guard location == GHOSTTY_CLIPBOARD_STANDARD, let content, count > 0 else { return }
        // Take the first text/plain payload.
        for i in 0..<count {
            let item = content[i]
            let mime = item.mime.map { String(cString: $0) } ?? ""
            guard mime.isEmpty || mime.hasPrefix("text/"), let data = item.data else { continue }
            let str = String(cString: data)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(str, forType: .string)
            return
        }
    }
}
