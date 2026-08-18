import AppKit

/// The seam that keeps the engine decision reversible (ADR-0011): the browser pane, session
/// model, and keybindings talk to this protocol, never to CEF directly. The spike proved two
/// engines swap freely behind it; CEF is the one that ships, and stage five removed the
/// WKWebView hedge that stood beside it — an engine with no CDP is not a browser Synth can
/// offer.
@MainActor
protocol BrowserEngine: AnyObject {
    /// The live web content view, parented into the pane by the caller.
    var view: NSView { get }
    var delegate: BrowserEngineDelegate? { get set }

    var currentURL: URL? { get }
    var pageTitle: String? { get }
    var canGoBack: Bool { get }
    var canGoForward: Bool { get }

    /// The engine's Chrome DevTools Protocol port. Stage two (the bundled MCP server)
    /// attaches here; an engine without one has no business being behind this protocol.
    var cdpPort: UInt16 { get }

    /// Find in page. `findNext` false starts a new search for `text`; true walks the matches
    /// of the search already running. Results arrive on the delegate.
    func find(_ text: String, forward: Bool, matchCase: Bool, findNext: Bool)
    /// Ends the search and drops the highlights; `activate` leaves the last match selected.
    func stopFinding(activate: Bool)

    func navigate(to url: URL)
    func goBack()
    func goForward()
    func reload()
    /// Sets page zoom as a factor (1.0 = 100%); the engine maps it to its native scale
    /// (CEF's logarithmic zoom level, WebKit's linear pageZoom).
    func setZoom(_ factor: Double)
    func showDevTools()
    func closeDevTools()
    /// Read at toggle time, not cached — the user can close the native DevTools
    /// window directly, behind the chrome's back.
    var devToolsOpen: Bool { get }

    /// Hard teardown: the engine's processes must be gone when this returns or shortly
    /// after — a surviving instance owns the profile singleton and silently absorbs the
    /// next launch (spike LEARNINGS).
    func shutdown()
}

/// What a page can put to the user (ADR-0011 stage five). Each of these stops the page until
/// it is answered, and every one of them was unanswerable before: a self-signed certificate
/// had no proceed path, basic auth had no prompt, alert/confirm/prompt were undefined, and
/// the camera was denied silently.
enum BrowserAskKind: String {
    case certificate, auth, alert, confirm, prompt, beforeUnload, permission
}

/// One question, and the answer it is holding for. Exactly one answer reaches the page; a
/// second is a no-op, so a double-fired button cannot strand a renderer.
@MainActor
protocol BrowserAsk: AnyObject {
    var kind: BrowserAskKind { get }
    /// Who is asking, as a host — the one thing the answer turns on.
    var origin: String { get }
    /// The page's own words for a dialog, the realm for auth, what is wanted for a
    /// permission, why the certificate was rejected.
    var detail: String? { get }
    /// window.prompt's default value.
    var defaultText: String? { get }

    func allow()
    func allow(text: String)
    func allow(user: String, password: String)
    func deny()
}

/// One row of the page's right-click menu. The model is CEF's, so this reports what the engine
/// built rather than inventing a second vocabulary for it.
struct BrowserMenuItem {
    let title: String
    let commandID: Int
    let enabled: Bool
    var isSeparator: Bool { title.isEmpty }
}

@MainActor
protocol BrowserEngineDelegate: AnyObject {
    /// Fires for every address change, including navigations the engine's CDP clients
    /// (stage two) initiated — the pane must track navigations it didn't cause.
    func engine(_ engine: BrowserEngine, addressDidChange url: URL)
    func engine(_ engine: BrowserEngine, titleDidChange title: String)
    func engine(_ engine: BrowserEngine, navigationStateDidChange canGoBack: Bool, canGoForward: Bool)
    /// The page is holding for an answer.
    func engine(_ engine: BrowserEngine, didAsk ask: any BrowserAsk)
    /// The question was taken back (the page navigated, the browser closed). Take it off
    /// screen — answering it now would reach nothing.
    func engine(_ engine: BrowserEngine, didWithdraw ask: any BrowserAsk)
    /// Find-in-page progress: which match is current (1-based, 0 for none), how many there
    /// are, and whether this is the last report for the query.
    func engine(_ engine: BrowserEngine, didFindMatch active: Int, of count: Int, final: Bool)
    /// The page was right-clicked. Show `items` at `point` in the engine's view and call
    /// `choose` exactly once — the picked item's commandID, or 0 for a dismissal. The page
    /// waits on that call.
    func engine(_ engine: BrowserEngine, didRequestContextMenu items: [BrowserMenuItem],
                at point: CGPoint, choose: @escaping (Int) -> Void)
    /// A menu item Synth performs rather than the engine: open this URL in the user's real
    /// browser, the same thing the pane's toolbar button does.
    func engine(_ engine: BrowserEngine, didRequestOpenExternal url: URL)
}
