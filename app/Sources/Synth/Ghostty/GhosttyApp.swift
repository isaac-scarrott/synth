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

        let config = TerminalTheme.makeConfig(dark: TerminalTheme.isDark(NSApp.effectiveAppearance))

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
        // The child-exit signal comes from GHOSTTY_ACTION_SHOW_CHILD_EXITED; close_surface
        // is the follow-up teardown request. The store acts on .exited — a clean exit
        // closes the whole session, a failure keeps the row showing the error, with the
        // true code arriving via the hook socket (features 2026-07-06) — so this is a
        // no-op: posting here would only double-fire .exited.
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

    /// libghostty → host actions. Most are handled by libghostty itself, but a couple are
    /// the embedded apprt's responsibility and flow onto the bus: the child-exited signal
    /// (a session's shell ended) and OPEN_URL (a clicked link — libghostty has no macOS
    /// fallback for an embedded host, so without this the click is silently dropped).
    private static func handleAction(
        _ appPtr: ghostty_app_t?, _ target: ghostty_target_s, _ action: ghostty_action_s
    ) -> Bool {
        switch action.tag {
        case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
            if target.tag == GHOSTTY_TARGET_SURFACE, let surface = target.target.surface {
                // NB: on macOS this code is always 0 — libghostty wraps the PTY child in
                // `login`, which exits 0 whatever its child's status was. The true code
                // arrives separately over the hook socket (`.exitCodeReported`); this
                // action's job is the exit *fact*, not the code.
                let code = Int32(action.action.child_exited.exit_code)
                GhosttySurfaceContext.from(ghostty_surface_userdata(surface))?.postExited(code)
            }
            return true
        case GHOSTTY_ACTION_OPEN_URL:
            let payload = action.action.open_url
            // HTML kind is a rendered-content payload (e.g. man pages), not a link — skip it.
            guard payload.kind != GHOSTTY_ACTION_OPEN_URL_KIND_HTML,
                  let ptr = payload.url, payload.len > 0 else { return true }
            // `url` is a `char*`+`len`, not guaranteed NUL-terminated — read exactly `len` bytes.
            let raw = String(decoding: UnsafeRawBufferPointer(start: ptr, count: Int(payload.len)),
                             as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            // URL(string:) is strict about spaces/UTF-8; percent-encode as a fallback, then drop.
            guard !raw.isEmpty,
                  let url = URL(string: raw)
                    ?? raw.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
                        .flatMap({ URL(string: $0) })
            else { return true }
            // The clicking surface names the source session (ownership + reuse of its link
            // browser); an app-scoped action falls back to whichever session is on screen.
            var sessionID: UUID?
            var ctxBus: EventBus?
            if target.tag == GHOSTTY_TARGET_SURFACE, let surface = target.target.surface,
               let ctx = GhosttySurfaceContext.from(ghostty_surface_userdata(surface)) {
                sessionID = ctx.sessionID
                ctxBus = ctx.bus
            }
            let sid = sessionID
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    (ctxBus ?? GhosttyApp.shared.bus)?.post(.openURLRequested(sid, url))
                }
            }
            return true
        default:
            return false
        }
    }

}
