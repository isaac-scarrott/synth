import AppKit

/// The seam that keeps the engine decision reversible (ADR-0011): the browser pane, session
/// model, and keybindings talk to this protocol, never to CEF/WebKit directly. The spike
/// proved two engines swap freely behind it; the production engine is CEF, with WKWebView as
/// the sanctioned no-CDP hedge.
@MainActor
protocol BrowserEngine: AnyObject {
    /// The live web content view, parented into the pane by the caller.
    var view: NSView { get }
    var delegate: BrowserEngineDelegate? { get set }

    var currentURL: URL? { get }
    var pageTitle: String? { get }
    var canGoBack: Bool { get }
    var canGoForward: Bool { get }

    /// The engine's Chrome DevTools Protocol port, 0 if the engine has none (WKWebView).
    /// Stage two (the bundled MCP server) attaches here; it must be live from day one.
    var cdpPort: UInt16 { get }

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

@MainActor
protocol BrowserEngineDelegate: AnyObject {
    /// Fires for every address change, including navigations the engine's CDP clients
    /// (stage two) initiated — the pane must track navigations it didn't cause.
    func engine(_ engine: BrowserEngine, addressDidChange url: URL)
    func engine(_ engine: BrowserEngine, titleDidChange title: String)
    func engine(_ engine: BrowserEngine, navigationStateDidChange canGoBack: Bool, canGoForward: Bool)
    /// window.open / target=_blank. The receiver routes this into a NEW browser session
    /// (one page per session); the engine itself must have suppressed the default popup —
    /// an unhandled popup blocks the renderer inside window.open() forever.
    func engine(_ engine: BrowserEngine, didRequestPopup url: URL)
}
