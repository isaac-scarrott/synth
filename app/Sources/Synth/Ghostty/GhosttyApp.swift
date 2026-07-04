import AppKit
import GhosttyKit

/// Owns the process-wide `ghostty_app_t`: libghostty's terminal engine + Metal renderer.
/// One app, many surfaces (one per session). libghostty owns the PTY, VT parsing, font
/// shaping, and the renderer thread; Synth just hosts a Metal-backed NSView per surface
/// (GhosttySurfaceView) and pumps input/geometry in.
///
/// Config is loaded from an inline string only — never the user's ~/.config/ghostty — so
/// behaviour is deterministic and parallel Synth instances can't perturb each other.
@MainActor final class GhosttyApp {
    static let shared = GhosttyApp()

    private(set) var app: ghostty_app_t?
    weak var bus: EventBus?

    /// Coalesces the IO thread's wakeup firehose down to one `ghostty_app_tick` per runloop
    /// turn on the main thread (wakeup can fire thousands of times/sec under bulk output).
    /// The gate is touched from the IO thread, so it lives outside main-actor isolation and
    /// is guarded by the lock.
    nonisolated private let tickLock = NSLock()
    nonisolated(unsafe) private var tickScheduled = false

    private init() {}

    func start() {
        guard app == nil else { return }

        guard ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == GHOSTTY_SUCCESS else {
            NSLog("Synth: ghostty_init failed")
            return
        }

        let config = ghostty_config_new()
        Self.inlineConfig.withCString { cstr in
            "/synth-inline.conf".withCString { path in
                ghostty_config_load_string(config, cstr, UInt(Self.inlineConfig.utf8.count), path)
            }
        }
        ghostty_config_finalize(config)

        var runtime = ghostty_runtime_config_s()
        runtime.userdata = Unmanaged.passUnretained(self).toOpaque()
        runtime.supports_selection_clipboard = false
        runtime.wakeup_cb = { userdata in
            guard let userdata else { return }
            let app = Unmanaged<GhosttyApp>.fromOpaque(userdata).takeUnretainedValue()
            app.scheduleTick()
        }
        runtime.action_cb = { appPtr, target, action in
            GhosttyApp.handleAction(appPtr, target, action)
        }
        runtime.read_clipboard_cb = { surfaceUserdata, location, state in
            GhosttyClipboard.read(surfaceUserdata, location, state)
        }
        runtime.confirm_read_clipboard_cb = { surfaceUserdata, str, state, request in
            GhosttyClipboard.confirmRead(surfaceUserdata, str, state, request)
        }
        runtime.write_clipboard_cb = { surfaceUserdata, location, content, count, confirm in
            GhosttyClipboard.write(surfaceUserdata, location, content, count, confirm)
        }
        // The child-exit signal comes from GHOSTTY_ACTION_SHOW_CHILD_EXITED (which carries
        // the real exit code); close_surface is the follow-up teardown request. We leave the
        // dead surface in place (the row shows "exited" until the user closes it, matching the
        // old SwiftTerm behaviour), so this is a no-op — posting here would only double-fire
        // .exited and clobber the code with nil.
        runtime.close_surface_cb = { _, _ in }

        app = ghostty_app_new(&runtime, config)
        ghostty_config_free(config)

        guard let app else { NSLog("Synth: ghostty_app_new failed"); return }
        ghostty_app_set_focus(app, true)

        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { if let app = self?.app { ghostty_app_set_focus(app, true) } }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { if let app = self?.app { ghostty_app_set_focus(app, false) } }
        }
    }

    /// Called from the IO thread; hop to main and drain libghostty's mailbox at most once
    /// per turn.
    nonisolated func scheduleTick() {
        tickLock.lock()
        let already = tickScheduled
        tickScheduled = true
        tickLock.unlock()
        guard !already else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.tickLock.lock(); self.tickScheduled = false; self.tickLock.unlock()
            MainActor.assumeIsolated { if let app = self.app { ghostty_app_tick(app) } }
        }
    }

    /// libghostty → host actions. Most are surface-scoped; we only need the child-exited
    /// signal (a session's shell ended) to flow onto the bus. Everything else is handled
    /// by libghostty itself, so return false.
    private static func handleAction(
        _ appPtr: ghostty_app_t?, _ target: ghostty_target_s, _ action: ghostty_action_s
    ) -> Bool {
        switch action.tag {
        case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
            if target.tag == GHOSTTY_TARGET_SURFACE, let surface = target.target.surface {
                let code = Int32(action.action.child_exited.exit_code)
                GhosttySurfaceContext.from(ghostty_surface_userdata(surface))?.postExited(code)
            }
            return true
        default:
            return false
        }
    }

    /// See CLAUDE.md fidelity notes. `term = xterm-256color` avoids depending on the
    /// ghostty terminfo being installed on the host. Colours + font match working.html's
    /// `.term` card.
    private static let inlineConfig = """
    font-family = SF Mono
    font-size = 12
    background = 1b1b1e
    foreground = d4d4d8
    term = xterm-256color
    cursor-style = block
    mouse-hide-while-typing = true
    window-padding-x = 8
    window-padding-y = 6
    window-padding-color = background
    clipboard-read = allow
    clipboard-write = allow
    confirm-close-surface = false
    shell-integration = none
    """
}
