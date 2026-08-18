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

    /// `workspaceKey` names the profile the engine runs on — per workspace, so every
    /// browser session in one repo is the same signed-in browser (stage five).
    static func make(sessionID: UUID, workspaceKey: String) throws -> BrowserEngine {
        #if canImport(CEFShim)
        // CEF needs a URL at browser creation; the home surface covers the view until
        // the session's first real navigation.
        return try CEFEngine(initialURL: URL(string: "about:blank")!, sessionID: sessionID,
                             workspaceKey: workspaceKey)
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

    // The engine's profile facts, reachable from the store and Settings without either of
    // them naming a CEF type — the #if lives here, once, like globalShutdown's.

    /// Where a workspace's browser profile sits on disk. The live root while the engine is
    /// up, the persistent one before that — so what Settings measures is what Clear removes.
    static func profileDirectory(workspaceKey: String) -> URL {
        #if canImport(CEFShim)
        return BrowserProcessSupervisor.shared.profilePath(workspaceKey: workspaceKey)
        #else
        return AppSupport.dir("BrowserProfiles/shared")
            .appendingPathComponent(workspaceKey, isDirectory: true)
        #endif
    }

    /// False when another live Synth of this channel holds the persistent profile root and
    /// this instance is browsing on a throwaway one.
    static var profilesPersist: Bool {
        #if canImport(CEFShim)
        return BrowserProcessSupervisor.shared.profilesPersist
        #else
        return false
        #endif
    }

    /// False when the profile could not be thrown away — another Synth is live on it, or this
    /// build has no engine and therefore nothing that owns one.
    static func clearProfile(workspaceKey: String) -> Bool {
        #if canImport(CEFShim)
        return BrowserProcessSupervisor.shared.clearProfile(workspaceKey: workspaceKey)
        #else
        return false
        #endif
    }
}
