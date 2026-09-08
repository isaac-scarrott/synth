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
///   • the opt-out toggle (Settings → About) is honoured from the very first event.
///
/// Caught failures do not come here directly — they go through `Fault`, which decides what the
/// user is told and then calls `fault(_:repeats:surfaced:)` below. Native crashes (signals,
/// `fatalError`, the vendored C/C++ engines) unwind before any send can finish, so they are
/// caught by `CrashReporter`'s marker and reported on the next launch.
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
        // Native crash capture with real stacks: PLCrashReporter's Mach handler, the process's
        // only one — libghostty's Breakpad is evicted right after ghostty_init (MachExceptionPorts),
        // because stacked under this it deadlocks the forward and a crash becomes a hang. Needs
        // exception autocapture enabled on the PostHog project too — the SDK skips the integration
        // when remote config says no.
        config.errorTrackingConfig.autoCapture = true
        if allowDev { config.flushAt = 1 }          // forced-dev testing: send each event at once
        PostHogSDK.shared.setup(config)

        PostHogSDK.shared.register([
            "channel": isDevChannel ? "dev" : "stable",
            "app_version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
        ])
        live = true
        // The store was built before this ran, so anything it faulted on the way up is
        // waiting. Flush it now that the gates above have been applied.
        Fault.telemetryDidGoLive()
    }

    /// Record a product event. Properties must stay non-PII — counts, kinds, durations, never
    /// paths, titles, or user text.
    static func capture(_ event: String, _ properties: [String: Any]? = nil) {
        guard live else { return buffer(.event(event, properties)) }
        PostHogSDK.shared.capture(event, properties: properties)
    }

    /// A caught failure, as `Fault` decided it. Sent as a PostHog `$exception` — `Fault.Record`
    /// is an `Error` whose `CustomNSError` conformance fingerprints the issue on our own
    /// `domain/code` slugs rather than on whatever `localizedDescription` happened to hold, so
    /// these group into Error Tracking issues instead of piling up as anonymous event rows.
    ///
    /// `surfaced` is the property the whole audit turns on: `surfaced=false` IS the
    /// silent-failure backlog, ranked by how often it actually happens to real people rather
    /// than by how alarming it looked in a code review.
    static func fault(_ r: Fault.Record, repeats: Int, surfaced: Bool) {
        var props = r.errorUserInfo
        props["surfaced"] = surfaced
        if repeats > 0 { props["repeats"] = repeats }
        let trail = Fault.recentTrail()
        if !trail.isEmpty { props["trail"] = trail.joined(separator: ",") }
        guard live else { return buffer(.fault(r, props)) }
        PostHogSDK.shared.addExceptionStep("\(r.domain.rawValue)/\(r.code.rawValue)")
        PostHogSDK.shared.captureException(r, properties: props)
    }

    /// Whether this launch can report a native crash at all. PostHog's crash integration
    /// installs only from the *cached* remote config, so a fresh install has no crash capture
    /// on its first run and a debugger suppresses it entirely — without this event, "no
    /// crashes" and "no coverage" are the same observation.
    static func reportCrashCaptureState() {
        capture("crash_capture_state", [
            "opted_out": PostHogSDK.shared.isOptOut(),
            "debugger_attached": isDebuggerAttached(),
        ])
    }

    private static func isDebuggerAttached() -> Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return false }
        return (info.kp_proc.p_flag & P_TRACED) != 0
    }

    // MARK: Pre-bootstrap buffer

    /// Everything minted before `live` — which is the ENTIRE `AppStore` construction, since
    /// SwiftUI builds the store before `applicationDidFinishLaunching` runs — is held here and
    /// flushed once the dev-channel and opt-out gates have been applied. It is why the spine
    /// does not depend on launch ordering, and why `bootstrap` did not have to move ahead of
    /// `GhosttyApp.start()` (SynthApp documents that order as load-bearing).
    ///
    /// Capped: a spine must not become a leak on a machine where everything is failing.
    private enum Pending {
        case event(String, [String: Any]?)
        case fault(Fault.Record, [String: Any])
    }
    private static var pending: [Pending] = []
    private static func buffer(_ p: Pending) {
        guard pending.count < 100 else { return }
        pending.append(p)
    }

    /// Drain the buffer. Called by `Fault.telemetryDidGoLive()` at the end of `bootstrap` —
    /// and only there, so a build that never brings analytics up simply never sends.
    static func flushBuffered() {
        guard live else { return }
        let held = pending
        pending = []
        for p in held {
            switch p {
            case let .event(name, props):
                PostHogSDK.shared.capture(name, properties: props)
            case let .fault(r, props):
                PostHogSDK.shared.addExceptionStep("\(r.domain.rawValue)/\(r.code.rawValue)")
                PostHogSDK.shared.captureException(r, properties: props)
            }
        }
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
