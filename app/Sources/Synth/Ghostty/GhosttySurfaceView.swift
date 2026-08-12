import AppKit
import GhosttyKit

/// The NSView that hosts one libghostty surface. libghostty owns the renderer — at surface
/// creation it swaps this view's layer for its own IOSurface-backed CALayer and draws into
/// that from its renderer thread, driven by a CVDisplayLink keyed to the display id — and
/// the PTY/shell. This view's job is narrow: create the surface, keep it sized to the view
/// in pixels and its layer's contentsScale current, and forward keyboard/mouse/IME input.
final class GhosttySurfaceView: NSView, NSTextInputClient {
    private(set) var surface: ghostty_surface_t?
    private let sessionID: UUID
    private let cwd: URL
    private let kind: SessionKind
    /// Set when restoring a Claude row (ADR-0010): its terminal resumes the conversation
    /// with `claude --resume <id>` instead of a fresh `claude`. nil for a new session.
    private let resumeAgentID: String?
    /// The document a markdown row shows (ADR-0016). nil for every other kind, and for a
    /// markdown row spawned from a template — the TUI then opens its own empty state.
    private let markdownPath: String?
    private let env: [String: String]
    private let command: String
    /// Default flags typed after `claude` on launch (Settings → Claude Code flags). The
    /// effective string for this session's workspace; empty runs a bare `claude`.
    private let agentFlags: String
    private weak var bus: EventBus?

    /// Retained C-side via `surface_config.userdata`; released in `close()`.
    private var contextPtr: UnsafeMutableRawPointer?

    /// Observers registered while the view sits in a window (screen change, occlusion,
    /// display wake), removed when it leaves — paired with their center so workspace
    /// notifications unregister from the right one.
    private var windowObservers: [(NotificationCenter, NSObjectProtocol)] = []

    /// Accumulates text produced by `interpretKeyEvents` during a keyDown so it can be
    /// attached to the ghostty key event (empty for control/navigation keys, which
    /// libghostty encodes itself from keycode+mods).
    private var keyText: [String] = []
    private var markedText = NSMutableAttributedString()

    init(session: Session, cwd: URL, env: [String: String], command: String, agentFlags: String = "", bus: EventBus?) {
        self.sessionID = session.id
        self.cwd = cwd
        self.kind = session.kind
        self.resumeAgentID = session.agentSessionID
        self.markdownPath = session.markdownPath
        self.env = env
        self.command = command
        self.agentFlags = agentFlags
        self.bus = bus
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 480))
        wantsLayer = true
        registerForDraggedTypes([.fileURL, .string])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// Single-quote a value for safe use as a shell command argument (mirrors synth-hook's
    /// shellQuote) — the resume id is typed into the login shell as `claude --resume <id>`.
    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    override func makeBackingLayer() -> CALayer {
        let l = CAMetalLayer()
        l.pixelFormat = .bgra8Unorm
        // Non-opaque so the cells' own alpha (TerminalTheme's `background-opacity`) reaches the
        // compositor instead of being flattened here. This layer is usually short-lived —
        // libghostty swaps in its own at surface creation — so `createSurface` clears opacity on
        // the replacement too; setting it in both places is what makes it hold either way.
        l.isOpaque = false
        l.framebufferOnly = false
        return l
    }

    // MARK: Surface lifecycle

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeWindowObservers()
        guard let window else { return }
        if surface == nil { createSurface() }
        updateDisplayID()
        // Re-stamp scale + size on every window join, not just creation: the observers
        // below are unregistered while the view sits detached (pane switches re-parent
        // cached views), so a monitor change during that window is otherwise caught only
        // by AppKit's insertion-time viewDidChangeBackingProperties. Idempotent when
        // nothing changed.
        updateSurfaceSize()
        updateOcclusion()

        // libghostty paces its renderer with a display link keyed to the display id, and
        // the window server purges Metal drawables while a window is occluded or its
        // display sleeps. Neither is observable from inside libghostty — the host must
        // re-key the link when the display topology shifts and force a repaint when the
        // window becomes visible again, or every surface stays blank after a display
        // reconfiguration while the PTYs underneath keep running.
        let nc = NotificationCenter.default
        windowObservers.append((nc, nc.addObserver(
            forName: NSWindow.didChangeScreenNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.displayReconfigured() }
        }))
        windowObservers.append((nc, nc.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateOcclusion() }
        }))
        windowObservers.append((nc, nc.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.displayReconfigured() }
        }))
        let wnc = NSWorkspace.shared.notificationCenter
        windowObservers.append((wnc, wnc.addObserver(
            forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.displayReconfigured() }
        }))

        // Key-window changes are a focus edge the responder chain never reports: this view
        // stays first responder while its window resigns key (⌘K's palette taking over,
        // Synth dropping out of frontmost). See syncFocus.
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            windowObservers.append((nc, nc.addObserver(
                forName: name, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.syncFocus() }
            }))
        }
        syncFocus()
    }

    /// Tell libghostty whether this surface is taking keys. It draws the cursor as a hollow,
    /// unblinking box whenever it isn't — the terminal's own "this pane is asleep" signal —
    /// but only ever from what the host reports here.
    ///
    /// Focus is first responder *and* key window, not first responder alone: a background
    /// pane resigns, but the pane you were typing in stays first responder when the window
    /// loses key, which is exactly when the caret should stop blinking. `resignFirstResponder`
    /// runs before the new responder is installed, so it passes `responder` explicitly rather
    /// than reading a window that still points at this view.
    private func syncFocus(responder: Bool? = nil) {
        guard let surface else { return }
        let isResponder = responder ?? (window?.firstResponder === self)
        ghostty_surface_set_focus(surface, isResponder && window?.isKeyWindow == true)
    }

    private func removeWindowObservers() {
        for (center, token) in windowObservers { center.removeObserver(token) }
        windowObservers = []
    }

    /// Display topology changed under the window (wake from display sleep, monitor
    /// plug/unplug, the window landing on another screen): re-key the renderer's display
    /// link and repaint — the old link may reference a display id that no longer exists,
    /// which stops frame callbacks without any error surfacing.
    private func displayReconfigured() {
        guard let surface else { return }
        updateDisplayID()
        updateSurfaceSize()
        ghostty_surface_refresh(surface)
        // While this notification is in flight the window can still report the old
        // display's backingScaleFactor, and AppKit doesn't reliably follow up with
        // viewDidChangeBackingProperties (ghostty-org/ghostty#2731) — settle once more
        // after the runloop turn so the grid re-typesets at the real scale.
        DispatchQueue.main.async { [weak self] in self?.updateSurfaceSize() }
    }

    /// Mirror the window's occlusion into the renderer, forcing a full repaint on the
    /// occluded→visible edge: the window server may have purged the layer's drawables
    /// while hidden, and an idle shell produces no damage to trigger a redraw.
    private func updateOcclusion() {
        guard let surface, let window else { return }
        let visible = window.occlusionState.contains(.visible)
        ghostty_surface_set_occlusion(surface, visible)
        if visible { ghostty_surface_refresh(surface) }
    }

    private func createSurface() {
        guard let app = GhosttyApp.shared.app, let window else { return }

        let ctx = GhosttySurfaceContext(sessionID: sessionID, view: self, bus: bus)
        let ctxPtr = Unmanaged.passRetained(ctx).toOpaque()
        contextPtr = ctxPtr

        var cfg = ghostty_surface_config_new()
        cfg.platform_tag = GHOSTTY_PLATFORM_MACOS
        cfg.platform.macos.nsview = Unmanaged.passUnretained(self).toOpaque()
        cfg.userdata = ctxPtr
        cfg.scale_factor = window.backingScaleFactor
        cfg.font_size = 0  // 0 → use the config default

        // An agent session is a native login shell that immediately `exec`s the agent's binary,
        // run after the user's rc files so the shim PATH intercepts it. exec, not run: the session
        // exists to run the agent, so the agent's end is the PTY child exiting — the same
        // child-exited signal a terminal's `exit` raises (clean → the row closes itself,
        // features 2026-07-06). The exit *code* can't ride that signal (macOS `login`
        // zeroes it); the shim reports it over the hook socket instead. A plain terminal is
        // just the login shell; a browser session never hosts a PTY (BrowserPane owns it).
        // A restored agent row (resumeAgentID set) resumes its saved conversation instead —
        // the id reaches a shell as a word of a command line, so the supervisor shell-quotes it
        // rather than trusting its format. The workspace's default flags are appended raw:
        // they're the user's own shell tokens (Settings → agent flags).
        var env = env
        if let launch = kind.agentID
            .flatMap({ AgentRegistry.supervisor($0) })
            .map({ $0.launchCommand(resume: resumeAgentID, flags: agentFlags) }) {
            env["SYNTH_LAUNCH_COMMAND"] = launch
        }
        // Every session carries the synth-md palette and control socket, not just markdown
        // rows: `synth notes.md` typed in an ordinary terminal runs the same TUI, and it has
        // to arrive themed and able to hand links back like any other (ADR-0016).
        if MarkdownSession.isAvailable {
            let theme = MarkdownSession.environment(dark: TerminalTheme.isDark(effectiveAppearance),
                                                    socketPath: InstanceRegistry.controlSocketPath)
            for (key, value) in theme { env[key] = value }
        }
        // A markdown row is the same shape as an agent row — a login shell that execs one
        // fixed program — so it rides the same launch mechanism.
        if kind == .markdown, let launch = MarkdownSession.launchCommand(path: markdownPath) {
            env["SYNTH_LAUNCH_COMMAND"] = launch
        }

        // env_vars must outlive ghostty_surface_new; strdup then free after the call.
        var envVars: [ghostty_env_var_s] = []
        envVars.reserveCapacity(env.count)
        for (k, v) in env {
            guard let kp = strdup(k), let vp = strdup(v) else { continue }
            envVars.append(ghostty_env_var_s(key: kp, value: vp))
        }
        defer { for e in envVars { free(UnsafeMutablePointer(mutating: e.key)); free(UnsafeMutablePointer(mutating: e.value)) } }

        command.withCString { cCmd in
            cfg.command = cCmd
            cwd.path.withCString { cCwd in
                cfg.working_directory = cCwd
                envVars.withUnsafeMutableBufferPointer { buf in
                    cfg.env_vars = buf.baseAddress
                    cfg.env_var_count = buf.count
                    self.surface = ghostty_surface_new(app, &cfg)
                }
            }
        }

        guard surface != nil else { NSLog("Synth: ghostty_surface_new failed"); return }
        // The layer we handed AppKit in `makeBackingLayer` is gone: libghostty has replaced it with
        // its own IOSurface-backed one, which arrives opaque. Clear it here, on the layer that
        // actually reaches the screen, or the translucent cells composite against black.
        layer?.isOpaque = false
        updateDisplayID()
        updateSurfaceSize()
        applyTheme()
        syncFocus()
    }

    /// Re-theme the surface to the view's current appearance (working.html's `--tui-*`,
    /// light "paper" vs dark card). Called on creation and whenever the appearance flips.
    private func applyTheme() {
        guard let surface else { return }
        let dark = TerminalTheme.isDark(effectiveAppearance)
        AgentTheme.sync(dark: dark)
        let config = TerminalTheme.makeConfig(dark: dark)
        ghostty_surface_update_config(surface, config)
        ghostty_config_free(config)
        ghostty_surface_refresh(surface)
    }

    /// Free the surface + release its retained context. Called by TerminalManager.terminate.
    func close() {
        removeWindowObservers()
        if let surface {
            // Capture the shell's process group BEFORE freeing the surface, then hard-kill
            // the whole tree. ghostty_surface_free closes the PTY master, which only HUPs the
            // foreground process group — a descendant that survives HUP or sits in its own
            // handle-holding event loop (a killed claude's MCP node servers, an spawned
            // daemon) outlives that and orphans to launchd. The login leader setsid'd this
            // PTY into its own private session, so the whole tree (login → shell → agent →
            // MCP servers) shares one process group that is ours to reap and contains nothing
            // else. See reapProcessTree for the safety guards.
            let leafPID = pid_t(truncatingIfNeeded: ghostty_surface_foreground_pid(surface))
            ghostty_surface_free(surface)
            self.surface = nil
            Self.reapProcessTree(leafPID: leafPID, sessionID: sessionID)
        }
        if let contextPtr { Unmanaged<GhosttySurfaceContext>.fromOpaque(contextPtr).release(); self.contextPtr = nil }
    }

    /// SIGTERM then (after a grace period) SIGKILL the PTY session's whole process group,
    /// identified from any live process in it (`leafPID`, the surface's foreground pid).
    /// Guarded so it can only ever hit that private, setsid'd group: never pid ≤ 1, never
    /// our own group, never the process-group-less case. A no-op if the shell already exited
    /// cleanly (killpg → ESRCH). Static so it survives this view's own deinit during quit.
    ///
    /// The group is the unit for everything the shell ran in the foreground, and misses anything
    /// that `setsid`'d away from it — an agent's detached dev server is the case that matters,
    /// and also the one holding the most memory. `SessionProcesses` sweeps those up afterwards by
    /// their environment stamp, on its own queue: the group signal is instant and covers the
    /// common case, so the slower, wider pass is never in the way of closing a row.
    static func reapProcessTree(leafPID: pid_t, sessionID: UUID) {
        SessionProcesses.reapEscaped(session: sessionID)
        guard leafPID > 1 else { return }
        let pgid = getpgid(leafPID)
        guard pgid > 1, pgid != getpgrp() else { return }
        killpg(pgid, SIGTERM)
        // Escalate to SIGKILL for anything that ignored TERM (a wedged node event loop).
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { killpg(pgid, SIGKILL) }
    }

    // MARK: Geometry

    override func layout() { super.layout(); updateSurfaceSize() }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); updateDisplayID(); updateSurfaceSize() }
    override func viewDidEndLiveResize() { super.viewDidEndLiveResize(); updateSurfaceSize() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); applyTheme() }

    private func updateSurfaceSize() {
        guard let surface, let window else { return }
        // Backing scale from the window only — never convertToBacking — so any ancestor
        // magnification can't re-typeset the grid at the wrong pixel size.
        let scale = window.backingScaleFactor
        let pxW = max(1, Int((bounds.width * scale).rounded(.down)))
        let pxH = max(1, Int((bounds.height * scale).rounded(.down)))

        // libghostty replaced this view's layer with its own IOSurface-backed layer at
        // surface creation, stamping its contentsScale once from the creation-time scale —
        // the renderer never updates it afterwards. Keeping it current is the host's job
        // (Ghostty.app's SurfaceView does the same): left stale, the compositor rescales
        // the terminal contents when the window crosses to a display with a different
        // backingScaleFactor — wrong-sized, blurry text until the next re-typeset.
        if let layer, layer.contentsScale != scale {
            CATransaction.begin()
            CATransaction.setDisableActions(true)  // no implicit scale animation
            layer.contentsScale = scale
            CATransaction.commit()
        }

        ghostty_surface_set_content_scale(surface, scale, scale)
        ghostty_surface_set_size(surface, UInt32(pxW), UInt32(pxH))
        ghostty_surface_refresh(surface)
    }

    private func updateDisplayID() {
        guard let surface,
              let screen = window?.screen,
              let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { return }
        ghostty_surface_set_display_id(surface, num.uint32Value)
    }

    // MARK: Focus

    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool {
        syncFocus(responder: true)
        return super.becomeFirstResponder()
    }
    override func resignFirstResponder() -> Bool {
        syncFocus(responder: false)
        return super.resignFirstResponder()
    }

    // MARK: Programmatic input (browser comment delivery, ADR-0011 stage three)

    /// Write text to the PTY through the paste path — bracketed paste when the running
    /// app enabled mode 2004 (Claude Code does), so embedded newlines stay literal
    /// input instead of submitting line by line.
    func sendPaste(_ text: String) {
        guard let surface else { return }
        text.withCString { ghostty_surface_text(surface, $0, UInt(text.utf8.count)) }
    }

    /// Write text as committed *typed* input (never bracketed) — a "\r" here is a real
    /// Enter to the app, which the paste path would swallow into the bracket.
    func sendTypedText(_ text: String) {
        guard let surface else { return }
        text.withCString { ghostty_surface_text_input(surface, $0, UInt(text.utf8.count)) }
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        guard let surface else { return }
        keyText = []
        interpretKeyEvents([event])
        sendKey(surface, event: event,
                action: event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS,
                text: keyText.joined())
        keyText = []
    }

    override func keyUp(with event: NSEvent) {
        guard let surface else { return }
        sendKey(surface, event: event, action: GHOSTTY_ACTION_RELEASE, text: "")
    }

    override func flagsChanged(with event: NSEvent) {
        guard let surface else { return }
        // Whether the changed modifier is now down: does the current flag set still
        // contain the bit for this physical key.
        let down: Bool
        switch event.keyCode {
        case 56, 60: down = event.modifierFlags.contains(.shift)
        case 59, 62: down = event.modifierFlags.contains(.control)
        case 58, 61: down = event.modifierFlags.contains(.option)
        case 55, 54: down = event.modifierFlags.contains(.command)
        default: down = false
        }
        sendKey(surface, event: event, action: down ? GHOSTTY_ACTION_PRESS : GHOSTTY_ACTION_RELEASE, text: "")
    }

    private func sendKey(_ surface: ghostty_surface_t, event: NSEvent,
                         action: ghostty_input_action_e, text: String) {
        var key = ghostty_input_key_s()
        key.action = action
        key.mods = Self.mods(event.modifierFlags)
        key.consumed_mods = GHOSTTY_MODS_NONE
        key.keycode = UInt32(event.keyCode)
        // charactersIgnoringModifiers raises on anything but a key event, so flagsChanged
        // must not touch it — a bare modifier has no codepoint anyway.
        let isKeyEvent = event.type == .keyDown || event.type == .keyUp
        key.unshifted_codepoint = isKeyEvent
            ? event.charactersIgnoringModifiers?.unicodeScalars.first?.value ?? 0
            : 0
        key.composing = hasMarkedText()
        if text.isEmpty {
            key.text = nil
            _ = ghostty_surface_key(surface, key)
        } else {
            text.withCString { key.text = $0; _ = ghostty_surface_key(surface, key) }
        }
    }

    static func mods(_ f: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var m: UInt32 = GHOSTTY_MODS_NONE.rawValue
        if f.contains(.shift) { m |= GHOSTTY_MODS_SHIFT.rawValue }
        if f.contains(.control) { m |= GHOSTTY_MODS_CTRL.rawValue }
        if f.contains(.option) { m |= GHOSTTY_MODS_ALT.rawValue }
        if f.contains(.command) { m |= GHOSTTY_MODS_SUPER.rawValue }
        if f.contains(.capsLock) { m |= GHOSTTY_MODS_CAPS.rawValue }
        return ghostty_input_mods_e(m)
    }

    // MARK: NSTextInputClient (captures typed text + IME preedit)

    func insertText(_ string: Any, replacementRange: NSRange) {
        let s = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        keyText.append(s)
        unmarkText()
    }

    override func doCommand(by selector: Selector) {}

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let s = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        markedText = NSMutableAttributedString(string: s)
        guard let surface else { return }
        s.withCString { ghostty_surface_preedit(surface, $0, UInt(s.utf8.count)) }
    }

    func unmarkText() {
        markedText = NSMutableAttributedString()
        if let surface { ghostty_surface_preedit(surface, nil, 0) }
    }

    func hasMarkedText() -> Bool { markedText.length > 0 }
    func markedRange() -> NSRange { markedText.length > 0 ? NSRange(location: 0, length: markedText.length) : NSRange(location: NSNotFound, length: 0) }
    func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func characterIndex(for point: NSPoint) -> Int { 0 }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let surface else { return .zero }
        var x: Double = 0, y: Double = 0, w: Double = 0, h: Double = 0
        ghostty_surface_ime_point(surface, &x, &y, &w, &h)
        // ghostty gives a top-left origin point in the view; convert to screen bottom-left.
        let viewPoint = NSPoint(x: x, y: bounds.height - y)
        let windowRect = convert(NSRect(origin: viewPoint, size: .zero), to: nil)
        return window?.convertToScreen(windowRect) ?? .zero
    }

    // MARK: Drag & drop (Finder files → shell-quoted paths, like Terminal/Ghostty —
    // Claude Code reads dropped images from the pasted path)

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self, NSString.self]) ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        if let urls = pb.readObjects(forClasses: [NSURL.self],
                                     options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            sendPaste(urls.map { Self.shellQuote($0.path) }.joined(separator: " ") + " ")
            return true
        }
        if let text = pb.string(forType: .string), !text.isEmpty {
            sendPaste(text)
            return true
        }
        return false
    }

    // MARK: Mouse

    private func mousePos(_ event: NSEvent) {
        guard let surface else { return }
        let p = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, Double(p.x), Double(bounds.height - p.y), Self.mods(event.modifierFlags))
    }

    private func mouseButton(_ event: NSEvent, _ state: ghostty_input_mouse_state_e, _ button: ghostty_input_mouse_button_e) {
        guard let surface else { return }
        mousePos(event)
        _ = ghostty_surface_mouse_button(surface, state, button, Self.mods(event.modifierFlags))
    }

    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self); mouseButton(event, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT) }
    override func mouseUp(with event: NSEvent) { mouseButton(event, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT) }
    override func rightMouseDown(with event: NSEvent) { mouseButton(event, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT) }
    override func rightMouseUp(with event: NSEvent) { mouseButton(event, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT) }
    override func otherMouseDown(with event: NSEvent) { mouseButton(event, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_MIDDLE) }
    override func otherMouseUp(with event: NSEvent) { mouseButton(event, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_MIDDLE) }
    override func mouseDragged(with event: NSEvent) { mousePos(event) }
    override func rightMouseDragged(with event: NSEvent) { mousePos(event) }
    override func mouseMoved(with event: NSEvent) { mousePos(event) }

    override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }
        var mods: Int32 = 0
        if event.hasPreciseScrollingDeltas { mods = 1 }  // bit 0 = precision (pixel) scrolling
        // Momentum phase packed into bits 1-3 (ghostty_input_scroll_mods_t).
        let momentum: Int32
        switch event.momentumPhase {
        case .began: momentum = 1
        case .stationary: momentum = 2
        case .changed: momentum = 3
        case .ended: momentum = 4
        case .cancelled: momentum = 5
        case .mayBegin: momentum = 6
        default: momentum = 0
        }
        mods |= momentum << 1
        ghostty_surface_mouse_scroll(surface, Double(event.scrollingDeltaX), Double(event.scrollingDeltaY), mods)
    }
}
