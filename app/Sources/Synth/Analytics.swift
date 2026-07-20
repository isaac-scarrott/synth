import Foundation
import PostHog

/// Anonymous, opt-out product analytics (PostHog). Deliberately minimal: a small set of explicit
/// events plus PostHog's app-lifecycle events, keyed to a random per-install id — no login, no
/// autocapture, no screen recording, and no user content on the wire. It answers "how many
/// people, using what, how often, do they stick" without collecting anything that identifies
/// them.
///
/// Three things keep the numbers honest and the default safe:
///   • the dev channel never reports, so the author's own runs don't skew usage;
///   • an unset `projectKey` makes every call a no-op, so CI and forked checkouts stay silent;
///   • the opt-out toggle (Settings → Privacy) is honoured from the very first event.
///
/// Caught errors go through `error(_:)`. Native crashes (signals, `fatalError`, the vendored
/// C/C++ engines) are NOT captured here — that needs a dedicated crash handler, a follow-up.
@MainActor
enum Analytics {
    /// PostHog *project* API key — a publishable client token, not a secret (safe in source and
    /// in the shipped binary). Paste the Synth project's key here (PostHog EU) to switch analytics
    /// on; until then `bootstrap` no-ops and nothing is sent.
    private static let projectKey = "phc_zamhhrUm9DrsHh5B6f8qaUcbJoVRuU5unEzwmsSMv9VP"
    private static let host = "https://eu.i.posthog.com"

    /// True once `setup` has actually run — guards every send so calls made before bootstrap,
    /// on the dev channel, or with no key are silently dropped.
    private static var live = false

    /// Stand analytics up once, at launch. `optedOut` is the persisted Settings preference, applied
    /// before the first event so an opted-out user never sends even one.
    static func bootstrap(optedOut: Bool) {
        // The dev channel stays silent so the author's own runs never skew usage — except when
        // SYNTH_ANALYTICS_DEBUG=1 forces it on for testing. Forced dev events still carry
        // channel=dev (see the super-properties below), so real dashboards filter to stable.
        let allowDev = ProcessInfo.processInfo.environment["SYNTH_ANALYTICS_DEBUG"] == "1"
        guard !live, !isDevChannel || allowDev, projectKey.hasPrefix("phc_"),
              projectKey != "phc_REPLACE_WITH_SYNTH_PROJECT_KEY" else { return }

        let config = PostHogConfig(projectToken: projectKey, host: host)
        config.personProfiles = .identifiedOnly     // stays anonymous — we never call identify()
        config.captureApplicationLifecycleEvents = true   // app opened / backgrounded (retention)
        config.captureScreenViews = false           // macOS: nothing meaningful to autocapture
        // Session replay, element-interaction capture, and surveys are iOS-only in the SDK —
        // absent on macOS, so there's nothing to disable here; the screen is never recorded.
        config.optOut = optedOut                    // honour the saved preference from event one
        if allowDev { config.flushAt = 1 }          // forced-dev testing: send each event at once
        PostHogSDK.shared.setup(config)

        PostHogSDK.shared.register([
            "channel": isDevChannel ? "dev" : "stable",
            "app_version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
        ])
        live = true
    }

    /// Record a product event. Properties must stay non-PII — counts, kinds, durations, never
    /// paths, titles, or user text.
    static func capture(_ event: String, _ properties: [String: Any]? = nil) {
        guard live else { return }
        PostHogSDK.shared.capture(event, properties: properties)
    }

    /// A caught, non-fatal error. `domain` is a stable slug ("worktree", "browser", …); `detail`
    /// is a short, non-PII descriptor — never raw messages that might carry paths or content.
    static func error(_ domain: String, detail: String? = nil) {
        var props: [String: Any] = ["domain": domain]
        if let detail { props["detail"] = detail }
        capture("error", props)
    }

    /// Flip the opt-out at runtime (Settings toggle). PostHog stops/starts sending immediately and
    /// remembers the choice across launches.
    static func setOptOut(_ optedOut: Bool) {
        guard live else { return }
        if optedOut { PostHogSDK.shared.optOut() } else { PostHogSDK.shared.optIn() }
    }

    /// A server-controlled feature flag. Returns false when analytics is off or flags haven't
    /// loaded, so a gated feature simply stays in its default (off) state.
    static func isEnabled(_ flag: String) -> Bool {
        guard live else { return false }
        return PostHogSDK.shared.isFeatureEnabled(flag)
    }
}
