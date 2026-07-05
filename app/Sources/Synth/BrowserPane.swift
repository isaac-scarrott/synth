import SwiftUI
import AppKit

// The browser session's pane (ADR-0011 stage one): working.html's `.browser` chrome —
// back/forward/reload, the lock+URL omnibox pill, the DevTools toggle — around the live
// engine view, with the "go to" home surface and its floating dropdown twin. Everything
// here talks to `BrowserEngine`, never a concrete engine (the factory picks one).

// MARK: - Engine ownership

/// Owns the live engines keyed by session id, *outside* the SwiftUI view tree — the
/// TerminalManager pattern: a session's page survives navigating away and back, and
/// only derived facts (address, page title, popups) reach the store via the bus.
@MainActor final class BrowserManager {
    static let shared = BrowserManager()

    weak var bus: EventBus?
    private var controllers: [UUID: BrowserSessionController] = [:]

    /// Sessions already terminated. A pane re-render mid-delete must not lazily
    /// resurrect an engine for a dead row — that orphans a CDP target and a profile
    /// dir until app quit (session ids are never reused, so tombstones are safe).
    private var dead: Set<UUID> = []

    /// Sessions whose engine is being created right now. Engine creation pumps the
    /// main runloop (CEF's async browser bootstrap), which can run a SwiftUI render
    /// pass that re-enters this method for the same session — without the guard that
    /// second entry builds a duplicate engine (two CDP targets claiming one session,
    /// one of them leaked).
    private var creating: Set<UUID> = []

    func controller(for session: Session) -> BrowserSessionController? {
        guard !dead.contains(session.id), !creating.contains(session.id) else { return nil }
        if let existing = controllers[session.id] { return existing }
        creating.insert(session.id)
        defer { creating.remove(session.id) }
        let ctrl = BrowserSessionController(session: session, bus: bus)
        controllers[session.id] = ctrl
        // The engine is the session's live process: running while it exists (a restored
        // row sat idle until this first open). The event also re-renders the pane that
        // saw nil during a reentrant render, now that the controller is cached.
        bus?.post(.statusChanged(session.id, .running))
        return ctrl
    }

    /// The live controller, if the session's pane has ever been opened — never spins
    /// up an engine. Used to move first-responder focus onto an open page (⌘1).
    func existing(_ id: UUID) -> BrowserSessionController? { controllers[id] }

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

    var isHome: Bool { address == nil }

    init(session: Session, bus: EventBus?) {
        self.sessionID = session.id
        self.bus = bus
        self.engine = BrowserEngineFactory.make(sessionID: session.id)
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

    func shutdown() { engine.shutdown() }
}

extension BrowserSessionController: BrowserEngineDelegate {
    func engine(_ engine: BrowserEngine, addressDidChange url: URL) {
        // CEF idles on about:blank behind the home surface (an engine needs a URL at
        // creation); that's not a navigation — home stays until a real one.
        if address == nil && url.absoluteString == "about:blank" { return }
        address = url
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

/// working.html `.browser`: the rounded card (14 margin, radius 10, raised bg) holding
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
        // nil = the session was deleted while this pane was still on screen; render
        // nothing for the frame it takes the selection to move on.
        if let ctrl = BrowserManager.shared.controller(for: session) {
            pane(ctrl)
        }
    }

    private func pane(_ ctrl: BrowserSessionController) -> some View {
        VStack(spacing: 0) {
            BrowserBar(ctrl: ctrl, dropOpen: $dropOpen, homeFocusNonce: $homeFocusNonce)
            ZStack(alignment: .top) {
                if ctrl.isHome {
                    BrowserHome(recents: recents, focusNonce: homeFocusNonce) { ctrl.go($0) }
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
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.raised)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.borderStrong, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.06), radius: 1.5, y: 1)
        .padding(14)
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

// MARK: - Bar

/// working.html `.browser__bar`: nav cluster · omnibox pill · DevTools toggle, on the
/// chrome-grey strip with a hairline below.
private struct BrowserBar: View {
    let ctrl: BrowserSessionController
    @Binding var dropOpen: Bool
    @Binding var homeFocusNonce: Int

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 2) {
                BarButton(icon: Phosphor.back, help: "Back",
                          disabled: !ctrl.canGoBack) { ctrl.goBack() }
                BarButton(icon: Phosphor.forward, help: "Forward",
                          disabled: !ctrl.canGoForward) { ctrl.goForward() }
                ReloadButton(ctrl: ctrl)
            }
            OmniPill(ctrl: ctrl, editing: dropOpen) {
                if ctrl.isHome { homeFocusNonce += 1 } else { dropOpen = true }
            }
            BarButton(icon: Phosphor.devtools, help: "DevTools",
                      disabled: ctrl.isHome, on: ctrl.devToolsOpen) { ctrl.toggleDevTools() }
        }
        .padding(.vertical, 7).padding(.horizontal, 10)
        .background(Theme.chrome)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.border).frame(height: 0.5)
        }
    }
}

/// `.browser__btn`: 26×26, radius 7, muted glyph; hover fills + darkens, press dips to
/// 0.9, disabled fades to 0.32, `is-on` keeps the hover look (the DevTools on-state).
private struct BarButton: View {
    let icon: String
    let help: String
    var disabled = false
    var on = false
    var rotation: Double = 0
    let action: () -> Void
    @State private var hovering = false

    private var lit: Bool { (hovering && !disabled) || on }

    var body: some View {
        Button(action: action) {
            Phos(path: icon, size: 16)
                .foregroundStyle(lit ? Theme.ink : Theme.inkMuted)
                .rotationEffect(.degrees(rotation))
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 7).fill(lit ? Theme.rowHover : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(BarPressStyle())
        .disabled(disabled)
        .opacity(disabled ? 0.32 : 1)
        .help(help)
        .onHover { hovering = $0 && !disabled }
    }
}

/// `.browser__btn:active`: scale(0.9).
private struct BarPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(.easeOut(duration: 0.11), value: configuration.isPressed)
    }
}

/// The reload button spins one full turn on every navigation (`browser__btn--spin`,
/// 0.6s) — driven by the controller's spinNonce so back/forward/recents spin it too.
private struct ReloadButton: View {
    let ctrl: BrowserSessionController
    @State private var angle = 0.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        BarButton(icon: Phosphor.reload, help: "Reload",
                  disabled: ctrl.isHome, rotation: angle) { ctrl.reload() }
            .onChange(of: ctrl.spinNonce) { _, _ in
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.6)) { angle += 360 }
            }
    }
}

/// `.browser__omni`: the flexible lock+URL pill. On home it shows the placeholder and
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
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(Theme.inkMuted)
                        .lineLimit(1).truncationMode(.tail)
                } else {
                    Text("Search or enter address")
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(Theme.inkFaint)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 5).padding(.horizontal, 11)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.raised))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(editing ? Theme.attention
                                          : (hovering ? Theme.borderStrong : Theme.border),
                                  lineWidth: 0.5)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .inset(by: -2)
                    .stroke(Theme.attention.opacity(0.16), lineWidth: 3)
                    .opacity(editing ? 1 : 0)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Home surface + omnibox dropdown

/// `.browser__home`: centered globe glyph, the "Go to…" field (focused), and the
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
            }
            .frame(maxWidth: 440)
            .padding(.top, 60).padding(.horizontal, 22).padding(.bottom, 28)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.raised)
    }
}

/// `.browser__drop`: the same go-to/recents surface floated under the omnibox over a
/// loaded page, seeded with the current address (selected). Esc or an outside click
/// closes; Enter / a recent navigates and closes.
private struct OmniDrop: View {
    let ctrl: BrowserSessionController
    let recents: [BrowserRecent]
    let close: () -> Void

    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
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
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.borderStrong, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.17), radius: 18, y: 14)
        .padding(.horizontal, 10).padding(.top, 1)
        .opacity(shown ? 1 : 0)
        .offset(y: shown ? 0 : -6)
        .onAppear {
            if reduceMotion { shown = true }
            else { withAnimation(.easeOut(duration: 0.14)) { shown = true } }
        }
    }
}

/// `.browser__field`: search glyph + mono address input on a raised panel card, with
/// the blue focus ring. Shared by the home surface and the dropdown.
private struct GoToField: View {
    let placeholder: String
    var seed: String? = nil
    var focusNonce: Int = 0
    let onSubmit: (String) -> Void
    var onCancel: (() -> Void)? = nil

    @State private var text: String
    @FocusState private var focused: Bool

    init(placeholder: String, seed: String? = nil, focusNonce: Int = 0,
         onSubmit: @escaping (String) -> Void, onCancel: (() -> Void)? = nil) {
        self.placeholder = placeholder
        self.seed = seed
        self.focusNonce = focusNonce
        self.onSubmit = onSubmit
        self.onCancel = onCancel
        _text = State(initialValue: seed ?? "")
    }

    var body: some View {
        HStack(spacing: 9) {
            Phos(path: Phosphor.search, size: 16).foregroundStyle(Theme.inkFaint)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(Theme.ink)
                .focused($focused)
                .onSubmit { onSubmit(text) }
                .onExitCommand { onCancel?() }
        }
        .padding(.vertical, 11).padding(.horizontal, 14)
        .background(RoundedRectangle(cornerRadius: 11).fill(Theme.panel))
        .overlay(
            RoundedRectangle(cornerRadius: 11)
                .strokeBorder(focused ? Theme.attention : Theme.borderStrong, lineWidth: 0.5)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 13)
                .inset(by: -2)
                .stroke(Theme.attention.opacity(0.16), lineWidth: 3)
                .opacity(focused ? 1 : 0)
        )
        .shadow(color: .black.opacity(0.05), radius: 1.5, y: 1)
        .onAppear {
            focused = true
            // Seeded (dropdown): current address pre-selected so a keystroke replaces —
            // working.html's input.select().
            if seed != nil {
                DispatchQueue.main.async {
                    (NSApp.keyWindow?.firstResponder as? NSTextView)?.selectAll(nil)
                }
            }
        }
        .onChange(of: focusNonce) { _, _ in focused = true }
    }
}

/// `.browser__reclabel` + `.browser__rec`: the RECENT header over the visited rows.
private struct RecentsList: View {
    let recents: [BrowserRecent]
    let labelTopPadding: CGFloat
    let open: (BrowserRecent) -> Void

    var body: some View {
        Text("Recent")
            .textCase(.uppercase)
            .font(.system(size: 10.5, weight: .semibold)).kerning(0.42)
            .foregroundStyle(Theme.inkFaint)
            .padding(.top, labelTopPadding).padding(.horizontal, 4).padding(.bottom, 7)
        VStack(spacing: 1) {
            ForEach(recents, id: \.url) { r in
                RecentRow(recent: r) { open(r) }
            }
        }
    }
}

/// `.browser__recitem`: globe · mono URL · faint page-title, hover-filled row.
private struct RecentRow: View {
    let recent: BrowserRecent
    let action: () -> Void
    @State private var hovering = false

    private var display: String {
        URL(string: recent.url)?.browserHostPath ?? recent.url
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Phos(path: Phosphor.globe, size: 15).foregroundStyle(Theme.inkFaint)
                Text(display)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 8)
                if !recent.title.isEmpty {
                    Text(recent.title)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.inkFaint)
                        .lineLimit(1)
                }
            }
            .padding(.vertical, 8).padding(.horizontal, 10)
            .background(RoundedRectangle(cornerRadius: 8).fill(hovering ? Theme.rowHover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
