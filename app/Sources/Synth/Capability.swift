import Foundation

/// Things Synth needs that can be down, and can usually be brought back.
///
/// The point of this file is that most failures are not events, they are *states* — the hook
/// socket is not listening, the terminal engine never came up, the login wrapper is gone — and
/// a state can be retried. Handling those as one-shot errors is what produced the two bad
/// outcomes this app had: either the failure was swallowed and the feature quietly did nothing
/// forever, or it was latched and the feature stayed dead after a blip that had already passed.
///
/// So: try to fix it, quietly, a bounded number of times. Tell the user only when that is
/// exhausted, and then only once. A healing attempt is a breadcrumb; an exhausted one is a
/// sentence.
///
/// What this is deliberately not: a retry loop around anything that fails. Every heal here
/// undoes a *specific, understood* cause — a socket path left behind by a process that died,
/// a temp file swept out from under a long-running app, an engine that lost its device. None of
/// them retries a deterministic failure hoping for a different answer, which is the move that
/// turns "self-healing" into a hang with extra steps.
@MainActor
protocol Capability: AnyObject {
    /// Stable slug — the telemetry breakdown and the log category.
    static var id: String { get }
    /// The fault domain this capability's failures belong to.
    static var domain: Fault.Domain { get }
    /// What the user is told if healing runs out. Nil means this capability degrades silently:
    /// nothing the user asked for is broken, so there is nothing to say.
    static var copy: Fault.Copy? { get }

    /// Is it working *right now*? Cheap and honest — no side effects, no caching.
    var isUp: Bool { get }
    /// Make it work. Throw if it can't. Called on the first failure and on each retry, so it
    /// must be safe to run against a half-started capability.
    func heal() throws
}

/// How hard to try before admitting it. Deliberately short: three attempts over ~six seconds.
/// A capability that has not come back by then is not blinking, and holding the user in a
/// "still trying" state past the point of belief is its own kind of lie.
struct HealPolicy: Sendable {
    var attempts: Int = 3
    var delays: [Duration] = [.milliseconds(250), .seconds(2), .seconds(4)]
    static let standard = HealPolicy()
    /// For a capability whose failure is almost always a stale artefact from a dead process:
    /// one immediate retry fixes it or nothing will.
    static let once = HealPolicy(attempts: 1, delays: [.milliseconds(50)])
}

@MainActor
enum Capabilities {
    enum State: String, Sendable { case up, healing, down }

    private static var states: [String: State] = [:]
    private static var healing: Set<String> = []
    private static var announced: Set<String> = []

    /// What the UI should believe. `.down` is the only one worth rendering differently — a
    /// capability mid-heal has not failed yet, and flashing an error at the user for something
    /// that fixes itself 250ms later is noise, not honesty.
    static func state(_ id: String) -> State { states[id] ?? .up }

    /// Check a capability and, if it is down, try to bring it back. Safe to call often — an
    /// in-flight heal is not restarted, and a healthy capability costs one `isUp`.
    ///
    /// Returns immediately; healing is asynchronous by design, because a heal that blocked the
    /// main actor would freeze the very UI it is trying to keep usable.
    static func ensure<C: Capability>(_ capability: C, policy: HealPolicy = .standard) {
        guard !capability.isUp else {
            if states[C.id] != nil { recovered(C.self) }
            return
        }
        guard !healing.contains(C.id) else { return }
        healing.insert(C.id)
        states[C.id] = .healing
        Fault.note(C.domain, .healing)

        Guarded.mainTask {
            defer { healing.remove(C.id) }
            for attempt in 0..<policy.attempts {
                try? await Task.sleep(for: policy.delays[min(attempt, policy.delays.count - 1)])
                do {
                    try capability.heal()
                } catch {
                    Fault.note(C.domain, .healFailed)
                    continue
                }
                if capability.isUp {
                    // Counted, never said: from the user's side nothing happened, which is the
                    // whole point. The rate is what tells us whether the heal is real.
                    Analytics.capture("capability_recovered",
                                      ["capability": C.id, "attempt": attempt + 1])
                    recovered(C.self)
                    return
                }
            }
            exhausted(C.self, attempts: policy.attempts)
        }
    }

    private static func recovered<C: Capability>(_ type: C.Type) {
        states[C.id] = .up
        announced.remove(C.id)
        Fault.note(C.domain, .healed)
    }

    /// Healing is over and it did not work. This is the only place a capability failure reaches
    /// the user, and it happens once per capability per run: a structural failure is true all
    /// session, and saying so repeatedly does not make it more true.
    private static func exhausted<C: Capability>(_ type: C.Type, attempts: Int) {
        states[C.id] = .down
        guard announced.insert(C.id).inserted else { return }
        let details: [Fault.Detail] = [.attempt(attempts), .count("healed", 0)]
        if let copy = C.copy {
            Fault.surface(C.domain, .capabilityDown, severity: .blocked, say: copy,
                          details: details,
                          evidence: "Synth tried \(attempts) times to bring it back.")
        } else {
            Fault.report(C.domain, .capabilityDown, severity: .degraded, details: details)
        }
    }

    /// Test/gate handle: every capability's current state.
    static var snapshot: [String: String] { states.mapValues(\.rawValue) }
}
