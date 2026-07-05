import AppKit
import WebKit

/// The sanctioned no-CDP hedge behind `BrowserEngine` (ADR-0011): a plain WKWebView that
/// renders real pages so stage-one UI ships and verifies now; the CEF engine replaces it
/// at the factory switch point. `cdpPort` is 0 — WebKit has no CDP endpoint.
@MainActor final class WKWebViewEngine: NSObject, BrowserEngine {
    private let webView: WKWebView
    private var observers: [NSKeyValueObservation] = []

    weak var delegate: BrowserEngineDelegate?

    var view: NSView { webView }
    var currentURL: URL? { webView.url }
    var pageTitle: String? { webView.title }
    var canGoBack: Bool { webView.canGoBack }
    var canGoForward: Bool { webView.canGoForward }
    let cdpPort: UInt16 = 0

    override init() {
        let config = WKWebViewConfiguration()
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        // No dockable DevTools here (see showDevTools) — but the page is at least
        // inspectable from Safari's Develop menu.
        webView.isInspectable = true
        webView.uiDelegate = self
        // KVO → delegate: url/title/history all change outside our own calls (redirects,
        // pushState, in-page links), so polling our accessors would miss them.
        observers = [
            webView.observe(\.url, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated {
                    guard let self, let url = self.webView.url else { return }
                    self.delegate?.engine(self, addressDidChange: url)
                }
            },
            webView.observe(\.title, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated {
                    guard let self, let title = self.webView.title else { return }
                    self.delegate?.engine(self, titleDidChange: title)
                }
            },
            webView.observe(\.canGoBack, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.postNavState() }
            },
            webView.observe(\.canGoForward, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.postNavState() }
            },
        ]
    }

    private func postNavState() {
        delegate?.engine(self, navigationStateDidChange: webView.canGoBack,
                         canGoForward: webView.canGoForward)
    }

    func navigate(to url: URL) { webView.load(URLRequest(url: url)) }
    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }
    func reload() { webView.reload() }

    /// WebKit exposes no in-view DevTools surface — docked DevTools is the CEF engine's
    /// job (`ShowDevTools`). Deliberately empty rather than approximating with private API.
    func showDevTools() {}

    func shutdown() {
        observers = []
        webView.stopLoading()
        webView.uiDelegate = nil
        webView.removeFromSuperview()
        // In-process engine: no helper processes to reap (unlike CEF).
    }
}

extension WKWebViewEngine: WKUIDelegate {
    /// window.open / target=_blank: hand the URL to the delegate (one page per session →
    /// a NEW browser session) and return nil so WebKit never opens its own window. Returning
    /// nil also unblocks the renderer's window.open() call.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
            delegate?.engine(self, didRequestPopup: url)
        }
        return nil
    }
}
