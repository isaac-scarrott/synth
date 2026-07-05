import Foundation

/// The one place an engine gets constructed. UI code asks here and handles
/// `Unavailable` (CEF assets not fetched / not bundled) with a message, never a crash.
@MainActor
enum BrowserEngineFactory {
    struct Unavailable: LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    static func make(initialURL: URL) throws -> BrowserEngine {
        #if canImport(CEFShim)
        return try CEFEngine(initialURL: initialURL)
        #else
        throw Unavailable(reason:
            "CEF is not built into this binary — run app/vendor/fetch-cef.sh, then rebuild via app/dev.sh or app/build-app.sh")
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
