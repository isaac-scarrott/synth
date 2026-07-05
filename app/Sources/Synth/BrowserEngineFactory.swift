import Foundation
import os.log

/// The one place an engine is chosen (ADR-0011's reversible seam, in code). CEF is the
/// engine; WKWebView is the sanctioned hedge, taken only when CEF isn't built in (bare-binary
/// run, assets not fetched) or fails to start — the pane keeps working, but with no CDP
/// endpoint for stage two, so the fallback is loud in the log, never silent.
@MainActor
enum BrowserEngineFactory {
    struct Unavailable: LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    private static let log = Logger(subsystem: "tech.holibob.synth", category: "browser")

    static func make() -> BrowserEngine {
        #if canImport(CEFShim)
        do {
            // CEF needs a URL at browser creation; the home surface covers the view until
            // the session's first real navigation.
            return try CEFEngine(initialURL: URL(string: "about:blank")!)
        } catch {
            log.error("CEF engine unavailable, falling back to WKWebView (no CDP): \(error.localizedDescription)")
            return WKWebViewEngine()
        }
        #else
        log.error("CEF not built into this binary (run app/vendor/fetch-cef.sh, launch via dev.sh) — WKWebView fallback, no CDP")
        return WKWebViewEngine()
        #endif
    }

    /// Tears down the shared CEF runtime (no-op when CEF isn't built in). App exit or
    /// check-mode only — CEF cannot re-initialize in the same process.
    static func globalShutdown() {
        #if canImport(CEFShim)
        BrowserProcessSupervisor.shared.shutdownNow()
        #endif
    }
}
