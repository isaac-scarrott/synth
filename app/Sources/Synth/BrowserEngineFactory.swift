import Foundation

/// The one place an engine is chosen (ADR-0011's reversible seam, in code). CEF is the
/// engine, and the only one: a build without it makes no browser at all rather than a
/// degraded one. The WKWebView hedge that used to stand here rendered pages perfectly
/// and had no CDP endpoint, so every agent tool failed against something the user could
/// watch painting correctly — refusing to make a browser, loudly, is the better failure
/// (stage five).
@MainActor
enum BrowserEngineFactory {
    struct Unavailable: LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    static func make(sessionID: UUID) throws -> BrowserEngine {
        #if canImport(CEFShim)
        // CEF needs a URL at browser creation; the home surface covers the view until
        // the session's first real navigation.
        return try CEFEngine(initialURL: URL(string: "about:blank")!, sessionID: sessionID)
        #else
        throw Unavailable(reason:
            "this build has no browser engine — CEF wasn't compiled in. Run " +
            "app/vendor/fetch-cef.sh and launch a bundle assembled by app/dev.sh.")
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
