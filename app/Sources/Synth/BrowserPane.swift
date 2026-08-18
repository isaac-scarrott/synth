import SwiftUI
import AppKit

// The browser session's pane (ADR-0011 stage one): working.html's `.pane-surface` chrome —
// back/forward/reload, the lock+URL omnibox pill, the DevTools toggle — around the live
// engine view, with the "go to" home surface and its floating dropdown twin. Everything
// here talks to `BrowserEngine`, never a concrete engine (the factory picks one).

// MARK: - Engine ownership

/// Owns the live engines keyed by session id, *outside* the SwiftUI view tree — the
/// TerminalManager pattern: a session's page survives navigating away and back, and
/// only derived facts (address, page title, popups) reach the store via the bus.
/// A browser session carries no liveness: the engine's existence never touches
/// `Session.status`, so its sidebar row shows no indicator.
@MainActor @Observable final class BrowserManager {
    static let shared = BrowserManager()

    @ObservationIgnored weak var bus: EventBus?
    /// Which workspace a session belongs to — the profile an engine runs on (stage five).
    /// The store is the only thing that knows, and every caller of `controller(for:)`
    /// would otherwise have to carry the answer down to it.
    @ObservationIgnored weak var store: AppStore?
    @ObservationIgnored private var controllers: [UUID: BrowserSessionController] = [:]

    /// Sessions already terminated. A pane re-render mid-delete must not lazily
    /// resurrect an engine for a dead row — that orphans a CDP target and a profile
    /// dir until app quit (session ids are never reused, so tombstones are safe).
    @ObservationIgnored private var dead: Set<UUID> = []

    /// Sessions whose engine is being created right now. Engine creation pumps the
    /// main runloop (CEF's async browser bootstrap), which can run a SwiftUI render
    /// pass that re-enters this method for the same session — without the guard that
    /// second entry builds a duplicate engine (two CDP targets claiming one session,
    /// one of them leaked).
    @ObservationIgnored private var creating: Set<UUID> = []

    /// Why a session has no engine, when the factory refused to make one (stage five:
    /// there is no fallback engine to hide behind). Sticky — the reasons are structural
    /// (no CEF in the build, no free CDP port), so retrying on every render would only
    /// re-fail, and the pane needs something to say either way.
    @ObservationIgnored private var failures: [UUID: String] = [:]

    /// Bumped when an engine finishes bootstrapping. A pane that rendered nil during
    /// a reentrant render (the `creating` guard) observes this and re-renders now that
    /// the controller is cached — the nudge the old `.statusChanged(.running)` post
    /// provided before browser rows dropped status entirely.
    private var generation = 0

    func controller(for session: Session) -> BrowserSessionController? {
        _ = generation   // subscribe the calling render to engine-creation completions
        guard !dead.contains(session.id), !creating.contains(session.id),
              failures[session.id] == nil else { return nil }
        if let existing = controllers[session.id] { return existing }
        creating.insert(session.id)
        defer { creating.remove(session.id) }
        let engine: BrowserEngine
        do {
            engine = try BrowserEngineFactory.make(sessionID: session.id,
                                                   workspaceKey: profileKey(for: session))
        } catch {
            failures[session.id] = error.localizedDescription
            generation += 1
            return nil
        }
        let ctrl = BrowserSessionController(session: session, engine: engine, bus: bus)
        controllers[session.id] = ctrl
        generation += 1
        return ctrl
    }

    /// The refusal to show in the pane, if this session's engine could not be made.
    func failure(_ id: UUID) -> String? {
        _ = generation
        return failures[id]
    }

    /// The profile directory this session's engine runs on. A session whose workspace can't
    /// be resolved (a row mid-teardown) gets its own, so it can never silently land in
    /// another project's signed-in profile.
    private func profileKey(for session: Session) -> String {
        guard let store,
              let branch = store.branch(of: session),
              let workspace = store.workspace(of: branch) else { return "session-\(session.id.uuidString)" }
        return workspace.browserProfileKey
    }

    /// Tears down every live engine in a workspace so its profile can be cleared, and clears
    /// the tombstones so the panes rebuild — the rows are not going anywhere, only the
    /// browsers on them. Returns the sessions that had one.
    @discardableResult
    func recycle(_ ids: [UUID]) -> [UUID] {
        let live = ids.filter { controllers[$0] != nil }
        for id in live {
            controllers[id]?.shutdown()
            controllers[id] = nil
        }
        for id in ids { dead.remove(id); failures.removeValue(forKey: id) }
        generation += 1
        return live
    }

    /// The live controller, if the session's pane has ever been opened — never spins
    /// up an engine. Used to move first-responder focus onto an open page (⌘1).
    func existing(_ id: UUID) -> BrowserSessionController? { controllers[id] }

    /// The pane's non-blocking read: the engine if it's already up, else nil — but it *subscribes*
    /// to `generation` (unlike `existing`, whose `controllers` map is observation-ignored), so the
    /// pane re-renders the instant a deferred create completes. Crucially it never creates: the pane
    /// triggers creation itself, one runloop turn later, so CEF's runloop-pumping bootstrap lands
    /// after the open frame has painted a placeholder instead of freezing it.
    func paneEngine(for session: Session) -> BrowserSessionController? {
        _ = generation
        guard !dead.contains(session.id) else { return nil }
        return controllers[session.id]
    }

    /// A pane must not schedule a create for a row that's being deleted (it would render a
    /// placeholder card mid-teardown); this distinguishes "gone" from "not up yet".
    func isDead(_ id: UUID) -> Bool { dead.contains(id) }

    /// Whether the window's first responder sits inside any engine view — the browser
    /// twin of the key monitor's Ghostty/NSText passthrough guard, so a focused page
    /// keeps its own keys (Space must click the page's button, not re-open the
    /// selected sidebar row — the native analog of the mock's address-key propagation fix).
    func ownsFirstResponder(_ responder: NSResponder?) -> Bool {
        guard let view = responder as? NSView else { return false }
        return controllers.values.contains {
            view === $0.engine.view || view.isDescendant(of: $0.engine.view)
        }
    }

    /// The session whose engine view is (or contains) `view` — TerminalManager's reverse
    /// lookup for browser surfaces, so a first-responder change maps back to its pane.
    func sessionID(containing view: NSView) -> UUID? {
        controllers.first {
            view === $0.value.engine.view || view.isDescendant(of: $0.value.engine.view)
        }?.key
    }

    func terminate(_ id: UUID) {
        dead.insert(id)
        controllers[id]?.shutdown()
        controllers[id] = nil
    }

    /// App quit: no engine may outlive the app (BrowserEngine.shutdown contract).
    func shutdownAll() {
        dead.formUnion(controllers.keys)
        for ctrl in controllers.values { ctrl.shutdown() }
        controllers.removeAll()
    }
}

/// Per-session seam between the engine and the two state layers (ADR-0001): pane-local,
/// higher-frequency facts (address shown, back/forward, DevTools on) live here as
/// observable state; store-level facts (row rename, recents, popup→new session) are
/// posted onto the bus as events.
@MainActor @Observable final class BrowserSessionController {
    let sessionID: UUID
    let engine: BrowserEngine
    @ObservationIgnored weak var bus: EventBus?

    /// The address the chrome shows — nil is the fresh "go to" home surface. Set
    /// optimistically on our own navigations so the chrome swaps instantly, and by the
    /// delegate for ones we didn't cause (redirects, in-page links, future CDP clients).
    private(set) var address: URL?
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    /// The bar toggle's on-state, resynced from the engine at each toggle — the user
    /// can close the native DevTools window directly, behind the chrome's back.
    var devToolsOpen = false
    /// Bumped on every navigation — drives the reload button's one-shot spin.
    private(set) var spinNonce = 0
    /// Set by ⌘L / the palette's "Go to address…" — the pane consumes it and presses
    /// the omnibox: home refocuses the "Go to…" field, a loaded page opens the drop.
    /// Consumable rather than a nonce so a palette action that jumps here first can
    /// still land: the pane mounts after the set and consumes it on appear.
    private(set) var pendingFocusAddress = false

    var isHome: Bool { address == nil }

    func focusAddress() { pendingFocusAddress = true }

    func consumeFocusAddress() -> Bool {
        defer { pendingFocusAddress = false }
        return pendingFocusAddress
    }

    init(session: Session, engine: BrowserEngine, bus: EventBus?) {
        self.sessionID = session.id
        self.bus = bus
        self.engine = engine
        engine.delegate = self
        // A restored (or popup-born) session reopens its page in the fresh engine.
        if let url = session.browserURL { navigate(to: url) }
    }

    func navigate(to url: URL) {
        address = url
        spinNonce += 1
        engine.navigate(to: url)
    }

    /// Returns whether the text made a navigable URL (normalization: URL.fromBrowserInput).
    @discardableResult
    func go(_ text: String) -> Bool {
        guard let url = URL.fromBrowserInput(text) else { return false }
        navigate(to: url)
        return true
    }

    func goBack() { engine.goBack(); spinNonce += 1 }
    func goForward() { engine.goForward(); spinNonce += 1 }
    func reload() { engine.reload(); spinNonce += 1 }

    func toggleDevTools() {
        let open = engine.devToolsOpen
        if open { engine.closeDevTools() } else { engine.showDevTools() }
        devToolsOpen = !open
    }

    // Device mode (working.html devframe): like devToolsOpen, controller state — it
    // survives navigating away and back, and page navigations (like comment mode).
    private(set) var deviceModeOn = false
    private(set) var device: HardwareDevice = .initial
    private(set) var deviceLandscape = false
    /// The stage's fit scale, reported by the pane — folded into the CDP override so
    /// the w×h viewport renders exactly into the (w·s)×(h·s) engine view.
    @ObservationIgnored private var deviceFitScale: Double = 1
    @ObservationIgnored private var deviceEmulator: DeviceEmulator?

    func toggleDeviceMode() {
        deviceModeOn.toggle()
        if deviceModeOn { applyDeviceEmulation() } else { deviceEmulator?.clear() }
    }

    func setDevice(_ d: HardwareDevice) {
        guard d != device else { return }
        device = d
        applyDeviceEmulation()
    }

    func rotateDevice() {
        deviceLandscape.toggle()
        applyDeviceEmulation()
    }

    // Absolute setters for the control-socket verb (browser.deviceMode) — an agent
    // states the mode it wants; toggles would race a user flipping the same switch.
    func setDeviceMode(on: Bool) {
        guard on != deviceModeOn else { return }
        toggleDeviceMode()
    }

    func setDeviceLandscape(_ landscape: Bool) {
        guard landscape != deviceLandscape else { return }
        rotateDevice()
    }

    func reportDeviceFitScale(_ s: Double) {
        guard abs(s - deviceFitScale) > 0.0005 else { return }
        deviceFitScale = s
        if deviceModeOn { applyDeviceEmulation() }
    }

    private func applyDeviceEmulation() {
        guard deviceModeOn else { return }
        let emulator = deviceEmulator
            ?? DeviceEmulator(sessionID: sessionID, cdpPort: engine.cdpPort)
        deviceEmulator = emulator
        // The viewport the device's own browser leaves the page, not the whole screen —
        // its bars are drawn, so the page is emulated at the height it really gets.
        let page = device.pageViewport(landscape: deviceLandscape)
        emulator.apply(width: Int(page.width), height: Int(page.height),
                       deviceScaleFactor: device.deviceScaleFactor,
                       scale: deviceFitScale, urlHint: address)
    }

    /// Comment mode (ADR-0011 stage three), lazily created on first toggle — it holds
    /// a CDP attachment to this session's page target while on. The bar button reads
    /// `commentMode?.active` (also flipped off by the page's own exitMode binding call).
    private(set) var commentMode: CommentModeController?

    func toggleCommentMode(store: AppStore) {
        // `engaged`, not `active`: a toggle during the in-flight attach must cancel it,
        // not race a second attach on top (leaked CDP clients / event tasks).
        if let cm = commentMode, cm.engaged {
            Task { await cm.exit() }
            return
        }
        let cm = commentMode ?? CommentModeController(sessionID: sessionID, cdpPort: engine.cdpPort)
        commentMode = cm
        cm.enter(store: store, urlHint: address)
    }

    // Page zoom (⌘+/⌘−), controller state like devToolsOpen: it steps a fixed ladder and
    // rides navigation (re-applied in the address delegate) — the native twin of the mock's
    // re-apply-after-paint. `zoom` is a factor (1 = 100%); the engine maps it to its scale.
    static let zoomSteps: [Double] = [0.25, 0.33, 0.5, 0.67, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3]
    private(set) var zoom: Double = 1

    var zoomPercent: Int { Int((zoom * 100).rounded()) }
    var isZoomed: Bool { zoom != 1 }

    func zoomIn()  { stepZoom(1) }
    func zoomOut() { stepZoom(-1) }
    func resetZoom() { applyZoom(1) }

    private func stepZoom(_ dir: Int) {
        let steps = Self.zoomSteps
        let i = steps.firstIndex(of: zoom) ?? steps.firstIndex(of: 1)!
        applyZoom(steps[min(steps.count - 1, max(0, i + dir))])
    }

    private func applyZoom(_ factor: Double) {
        zoom = factor
        engine.setZoom(factor)
    }

    func shutdown() {
        commentMode?.teardown()
        deviceEmulator?.teardown()
        engine.shutdown()
    }
}

extension BrowserSessionController: BrowserEngineDelegate {
    func engine(_ engine: BrowserEngine, addressDidChange url: URL) {
        // CEF idles on about:blank behind the home surface (an engine needs a URL at
        // creation); that's not a navigation — home stays until a real one. Never
        // conditional on `address` still being nil: a session that opens straight onto a
        // page (restored, popup-born, agent-created) navigates in `init`, on the same turn
        // the engine is built, so the creation-time callback can land *after* that and
        // would clobber the real URL with plumbing no re-fire ever corrects.
        if url.absoluteString == "about:blank" { return }
        address = url
        // Zoom rides navigation (the mock re-applies after every paint). CEF stores zoom
        // per-origin, so a cross-origin hop would otherwise snap back to 100%.
        if zoom != 1 { engine.setZoom(zoom) }
        bus?.post(.browserNavigated(sessionID, url))
    }
    func engine(_ engine: BrowserEngine, titleDidChange title: String) {
        bus?.post(.browserPageTitled(sessionID, title))
    }
    func engine(_ engine: BrowserEngine, navigationStateDidChange canGoBack: Bool, canGoForward: Bool) {
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
    }
    func engine(_ engine: BrowserEngine, didRequestPopup url: URL) {
        bus?.post(.browserPopupRequested(sessionID, url))
    }
}

// MARK: - Pane

/// working.html `.pane-surface`: the rounded card (4/14/14 margins, radius 10, raised bg) holding
/// the toolbar over the page — or over the "go to" home when nothing is loaded yet.
struct BrowserPane: View {
    @Environment(AppStore.self) private var store
    let session: Session

    @State private var dropOpen = false
    /// Bumped when the home-state omnibox is clicked → refocus the home "Go to…" field.
    @State private var homeFocusNonce = 0

    private var recents: [BrowserRecent] {
        store.branch(of: session)?.browserRecents ?? []
    }

    var body: some View {
        if let ctrl = BrowserManager.shared.paneEngine(for: session) {
            pane(ctrl)
        } else if let reason = BrowserManager.shared.failure(session.id) {
            refusal(reason)
        } else if !BrowserManager.shared.isDead(session.id) {
            // Engine not up yet: paint the pane's card immediately, then bootstrap the engine on
            // the next runloop turn (the focus:false create's proven deferral, Store.newBrowser) so
            // CEF's bootstrap doesn't freeze the open animation. `generation` re-renders us when it
            // lands. A deleted session (isDead) renders nothing, as before.
            placeholder
                .onAppear {
                    DispatchQueue.main.async { _ = BrowserManager.shared.controller(for: session) }
                }
        }
    }

    /// No engine, and there never will be one for this session (stage five: the
    /// WKWebView fallback is gone, so a build without CEF makes no browser rather than a
    /// pane that renders fine and answers no agent tool). Says what is wrong in the card
    /// the page would have filled, in the home surface's own quiet register.
    private func refusal(_ reason: String) -> some View {
        VStack(spacing: 10) {
            Phos(path: Phosphor.globe, size: 34).foregroundStyle(Theme.inkFaint)
            Text("No browser engine")
                .font(.sans(13, 600)).foregroundStyle(Theme.ink)
            Text(reason)
                .font(.sans(12)).foregroundStyle(Theme.inkFaint)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.raised)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.borderStrong, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.06), radius: 1.5, y: 1)
        .padding(EdgeInsets(top: 4, leading: 14, bottom: 14, trailing: 14))
    }

    /// The pane's chrome with no engine yet — matches `pane`'s outer card so the swap to the live
    /// page is a fill, not a layout jump.
    private var placeholder: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(Theme.raised)
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.borderStrong, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.06), radius: 1.5, y: 1)
            .padding(EdgeInsets(top: 4, leading: 14, bottom: 14, trailing: 14))
    }

    private func pane(_ ctrl: BrowserSessionController) -> some View {
        VStack(spacing: 0) {
            BrowserBar(ctrl: ctrl, dropOpen: $dropOpen, homeFocusNonce: $homeFocusNonce)
            if ctrl.deviceModeOn && !ctrl.isHome {
                DeviceBar(ctrl: ctrl)
            }
            ZStack(alignment: .top) {
                if ctrl.isHome {
                    BrowserHome(recents: recents, focusNonce: homeFocusNonce) { ctrl.go($0) }
                } else if ctrl.deviceModeOn {
                    DeviceStage(ctrl: ctrl)
                } else {
                    EngineHost(engineView: ctrl.engine.view)
                }
                if dropOpen {
                    // Outside-click catcher under the dropdown (mock's document mousedown).
                    Color.black.opacity(0.001)
                        .contentShape(Rectangle())
                        .onTapGesture { dropOpen = false }
                    OmniDrop(ctrl: ctrl, recents: recents) { dropOpen = false }
                }
                if let notice = ctrl.commentMode?.notice {
                    CommentNotice(text: notice)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.raised)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.borderStrong, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.06), radius: 1.5, y: 1)
        .padding(EdgeInsets(top: 4, leading: 14, bottom: 14, trailing: 14))
        // ⌘L / palette "Go to address…" — same routing as clicking the omnibox pill.
        // onChange serves the live pane; onAppear one the action's jump just mounted.
        .onChange(of: ctrl.pendingFocusAddress) { _, pending in
            if pending, ctrl.consumeFocusAddress() { pressOmnibox(ctrl) }
        }
        .onAppear {
            if ctrl.consumeFocusAddress() { pressOmnibox(ctrl) }
        }
    }

    private func pressOmnibox(_ ctrl: BrowserSessionController) {
        if ctrl.isHome { homeFocusNonce += 1 } else { dropOpen = true }
    }
}

/// Hosts the engine's NSView (owned by BrowserManager, not created here), filling the
/// area below the bar — the TerminalHost pattern, without the focus grab: the address
/// field owns focus on home, and a loaded page takes keys via ⌘1/Esc (focusContent).
private struct EngineHost: NSViewRepresentable {
    let engineView: NSView

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        engineView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(engineView)
        NSLayoutConstraint.activate([
            engineView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            engineView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            engineView.topAnchor.constraint(equalTo: container.topAnchor),
            engineView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - Device mode

/// working.html `.browser__devicebar`: the fleet chips, the live W × H readout
/// (swaps on rotate), and the rotate button, on a second chrome strip below the bar.
private struct DeviceBar: View {
    let ctrl: BrowserSessionController

    var body: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 3) {
                    ForEach(HardwareDevice.fleet) { d in
                        DeviceChip(name: d.name, active: d == ctrl.device) {
                            ctrl.setDevice(d)
                        }
                    }
                }
            }
            // The page's viewport, not the screen's: with the device's own browser bars
            // drawn, the height a media query sees is what's left under them.
            let page = ctrl.device.pageViewport(landscape: ctrl.deviceLandscape)
            // verbatim: Text's Int interpolation adds locale grouping ("1,032") —
            // the readout is a CSS pixel count, not a quantity.
            Text(verbatim: "\(Int(page.width)) × \(Int(page.height))")
                .font(.mono(11))
                .foregroundStyle(Theme.inkFaint)
                .lineLimit(1).fixedSize()
            // The device glyph turned to the orientation a press would give — a
            // circular arrow here reads as reload next to the toolbar's real one.
            PaneBarButton(icon: Phosphor.deviceMobile, help: "Rotate device",
                          rotation: ctrl.deviceLandscape ? 0 : 90) {
                ctrl.rotateDevice()
            }
        }
        .padding(.vertical, 6).padding(.horizontal, 10)
        .background(Theme.chrome)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.border).frame(height: 0.5)
        }
    }
}

/// `.devicebar__chip`: capsule device names; the active one holds the hover look.
private struct DeviceChip: View {
    let name: String
    let active: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(name)
                .font(.sans(11, 500))
                .foregroundStyle(active ? Theme.ink : Theme.inkMuted)
                .lineLimit(1).fixedSize()
                .padding(.vertical, 4).padding(.horizontal, 10)
                .background(Capsule().fill(active || hovering ? Theme.rowHover : .clear))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// working.html `.devstage`: the chrome-grey stage centering the hardware frame. The
/// frame lays out at true device points — screen plus the hardware's own bezels — and
/// scales DOWN to fit within a 24pt margin, never up, so small devices stay life-size.
/// The fit scale is reported back to the controller: the engine view sits at the page
/// viewport times s, and the CDP override's `scale: s` renders that viewport into it.
private struct DeviceStage: View {
    let ctrl: BrowserSessionController

    var body: some View {
        GeometryReader { geo in
            let d = ctrl.device
            let land = ctrl.deviceLandscape
            let screen = d.screenSize(landscape: land)
            let bez = d.bezels(landscape: land)
            let frameW = screen.width + bez.leading + bez.trailing
            let frameH = screen.height + bez.top + bez.bottom
            let s = max(0.05, min(1, (geo.size.width - 48) / frameW,
                                     (geo.size.height - 48) / frameH))
            DeviceFrame(device: d, landscape: land, s: s) {
                BrowserDeviceScreen(device: d, landscape: land,
                                    host: ctrl.address?.browserHostPath ?? "", s: s,
                                    engineView: ctrl.engine.view)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .onAppear { ctrl.reportDeviceFitScale(s) }
            .onChange(of: s) { _, new in ctrl.reportDeviceFitScale(new) }
        }
        .background(Theme.chrome)
    }
}

// MARK: - Bar

/// working.html `.pane-bar`: nav cluster · omnibox pill · comment-mode toggle ·
/// DevTools toggle, on the chrome-grey strip with a hairline below.
private struct BrowserBar: View {
    @Environment(AppStore.self) private var store
    let ctrl: BrowserSessionController
    @Binding var dropOpen: Bool
    @Binding var homeFocusNonce: Int

    private var commentOn: Bool { ctrl.commentMode?.active ?? false }
    private var pendingComments: Int { ctrl.commentMode?.pendingCount ?? 0 }
    private var commentHelp: String {
        if commentOn {
            if let t = ctrl.commentMode?.targetTitle { return "Comment mode → \(t)" }
            return "Comment mode (no agent session in this branch)"
        }
        // Off with a batch still parked on the page: say it is being kept, not lost.
        if pendingComments > 0 {
            return "Comment mode · \(pendingComments) comment\(pendingComments == 1 ? "" : "s") not sent"
        }
        return "Comment mode"
    }

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 2) {
                PaneBarButton(icon: Phosphor.back, help: "Back",
                              disabled: !ctrl.canGoBack) { ctrl.goBack() }
                PaneBarButton(icon: Phosphor.forward, help: "Forward",
                              disabled: !ctrl.canGoForward) { ctrl.goForward() }
                ReloadButton(ctrl: ctrl)
            }
            OmniPill(ctrl: ctrl, editing: dropOpen) {
                if ctrl.isHome { homeFocusNonce += 1 } else { dropOpen = true }
            }
            if ctrl.isZoomed {
                // The live zoom readout, which clicks back to 100% — the reset affordance,
                // since ⌘0 stays Synth's focus-sidebar.
                PaneBadge(text: "\(ctrl.zoomPercent)%", help: "Reset zoom to 100%") {
                    ctrl.resetZoom()
                }
            }
            PaneBarButton(icon: Phosphor.commentMode, help: commentHelp,
                          disabled: ctrl.isHome, on: commentOn) { ctrl.toggleCommentMode(store: store) }
                .overlay(alignment: .topTrailing) {
                    if pendingComments > 0 { CommentCountBadge(count: pendingComments) }
                }
            PaneBarButton(icon: Phosphor.deviceMobile, help: "Device mode",
                          disabled: ctrl.isHome, on: ctrl.deviceModeOn) { ctrl.toggleDeviceMode() }
            PaneBarButton(icon: Phosphor.devtools, help: "DevTools",
                          disabled: ctrl.isHome, on: ctrl.devToolsOpen) { ctrl.toggleDevTools() }
            PaneBarButton(icon: Phosphor.external, help: "Open in default browser",
                          disabled: ctrl.isHome) {
                if let url = ctrl.address { NSWorkspace.shared.open(url) }
            }
        }
        .paneBar()
    }
}

/// working.html `.pane-cnt`: how many comments are queued on the page and waiting to be
/// sent, as a copper pill notched into the comment button's top-right corner. Absent at 0.
private struct CommentCountBadge: View {
    let count: Int

    var body: some View {
        // verbatim: a pin number, not a quantity to be grouped by locale.
        Text(verbatim: "\(count)")
            .font(.sans(10, 700, tabular: true))
            .foregroundStyle(.white)
            .padding(.horizontal, 4)
            .frame(minWidth: 14, minHeight: 14)
            .background(Capsule().fill(Theme.copper))
            // The negative padding grows the shape past the pill: the CSS ring sits outside it.
            .background(Capsule().fill(Theme.chrome).padding(-1.5))
            .offset(x: 2, y: -1)
            .help(count == 1 ? "1 comment queued — ⌘⌥⏎ to send"
                             : "\(count) comments queued — ⌘⌥⏎ to send")
    }
}

/// Transient comment-mode notice floated under the bar (delivery result, attach errors).
/// The controller auto-clears it after a few seconds.
private struct CommentNotice: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.sans(12))
            .foregroundStyle(Theme.ink)
            .lineLimit(2)
            .padding(.vertical, 6).padding(.horizontal, 12)
            .background(Capsule().fill(Theme.panel))
            .overlay(Capsule().strokeBorder(Theme.borderStrong, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
            .padding(.top, 10)
            .transition(.opacity)
    }
}

/// The reload button spins one full turn on every navigation (`pane-btn--spin`,
/// 0.6s) — driven by the controller's spinNonce so back/forward/recents spin it too.
private struct ReloadButton: View {
    let ctrl: BrowserSessionController
    @State private var angle = 0.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        PaneBarButton(icon: Phosphor.reload, help: "Reload",
                      disabled: ctrl.isHome, rotation: angle) { ctrl.reload() }
            .onChange(of: ctrl.spinNonce) { _, _ in
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.6)) { angle += 360 }
            }
    }
}

/// `.pane-omni`: the flexible lock+URL pill. On home it shows the placeholder and
/// refocuses the "Go to…" field; loaded, it floats the OmniDrop. `is-editing` = blue
/// border + soft focus ring while the dropdown is up.
private struct OmniPill: View {
    let ctrl: BrowserSessionController
    let editing: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let url = ctrl.address {
                    Phos(path: Phosphor.lock, size: 12).foregroundStyle(Theme.inkFaint)
                    Text(url.browserHostPath)
                        .font(.mono(12))
                        .foregroundStyle(Theme.inkMuted)
                        .lineLimit(1).truncationMode(.tail)
                } else {
                    Text("Search or enter address")
                        .font(.mono(12))
                        .foregroundStyle(Theme.inkFaint)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 5).padding(.horizontal, 11)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.raised))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(editing ? Theme.accent
                                          : (hovering ? Theme.borderStrong : Theme.border),
                                  lineWidth: 0.5)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .inset(by: -2)
                    .stroke(Theme.accent.opacity(0.16), lineWidth: 3)
                    .opacity(editing ? 1 : 0)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Home surface + omnibox dropdown

/// `.pane-start`: centered globe glyph, the "Go to…" field (focused), and the
/// branch's Recent list. Enter or clicking a recent navigates.
private struct BrowserHome: View {
    let recents: [BrowserRecent]
    let focusNonce: Int
    let go: (String) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Phos(path: Phosphor.globe, size: 34)
                    .foregroundStyle(Theme.inkFaint)
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 18)
                GoToField(placeholder: "Go to…", focusNonce: focusNonce, onSubmit: go)
                if !recents.isEmpty {
                    RecentsList(recents: recents, labelTopPadding: 22) { go($0.url) }
                }
                // `.pane-start__hint`: the quiet pointer to the Page group's verbs.
                HStack(spacing: 5) {
                    Text("Press")
                    KeyCap(text: "⌘")
                    KeyCap(text: "K")
                    Text("for the command menu")
                }
                .font(.sans(12))
                .foregroundStyle(Theme.inkFaint)
                .frame(maxWidth: .infinity)
                .padding(.top, 26)
            }
            .frame(maxWidth: 440)
            .padding(.top, 60).padding(.horizontal, 22).padding(.bottom, 28)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.raised)
    }
}

/// `.pane-drop`: the same go-to/recents surface floated under the omnibox over a
/// loaded page, seeded with the current address (selected). Esc or an outside click
/// closes; Enter / a recent navigates and closes.
private struct OmniDrop: View {
    let ctrl: BrowserSessionController
    let recents: [BrowserRecent]
    let close: () -> Void

    var body: some View {
        PaneDrop {
            GoToField(placeholder: "Search or enter address",
                      seed: ctrl.address?.browserHostPath,
                      onSubmit: { text in if ctrl.go(text) { close() } },
                      onCancel: close)
            if !recents.isEmpty {
                RecentsList(recents: recents, labelTopPadding: 12) { r in
                    close()
                    ctrl.go(r.url)
                }
            }
        }
    }
}

/// `.pane-rec__label` + `.pane-rec`: the RECENT header over the visited rows.
private struct RecentsList: View {
    let recents: [BrowserRecent]
    let labelTopPadding: CGFloat
    let open: (BrowserRecent) -> Void

    var body: some View {
        PaneRecLabel(text: "Recent", topPadding: labelTopPadding)
        VStack(spacing: 1) {
            ForEach(recents, id: \.url) { r in
                PaneRecRow(icon: Phosphor.globe,
                           key: URL(string: r.url)?.browserHostPath ?? r.url,
                           name: r.title) { open(r) }
            }
        }
    }
}
