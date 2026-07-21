import AppKit
import UserNotifications

/// The unfocused-window notification path. working.html defers this case to "the native app";
/// this is it: when Synth isn't frontmost, a background session's needs-input / error / done is
/// raised through Notification Center *on top of* the in-app deck — the banner catches the eye
/// now, the toast waits in the deck for focus to return (the focus branch lives in
/// `AppStore.routeTransition`). Attention states read as alerts, `done` as a transient banner;
/// all use `.active` interruption so Focus / DND is respected (never `.timeSensitive`). Toasts
/// are grouped by branch (`threadIdentifier`), carry the session identity, and — tapped —
/// activate Synth and jump to the session (correlated by the UUID in `userInfo`).
///
/// UNUserNotificationCenter requires a bundle identifier. In dev the app runs as a bare SwiftPM
/// executable (no `.app` bundle), so `Bundle.main.bundleIdentifier` is nil and every entry
/// here no-ops rather than trapping — the in-app deck is unaffected; only this path is inert.
final class NotificationService: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = NotificationService()
    private weak var store: AppStore?

    /// The whole NC path is gated on a bundle id (its hard precondition).
    private var available: Bool { Bundle.main.bundleIdentifier != nil }

    /// Wire the delegate and request authorization once at launch (alerts + sound + badge).
    @MainActor func bootstrap(store: AppStore) {
        self.store = store
        guard available else {
            NSLog("Synth: no bundle identifier — Notification Center path disabled (in-app deck unaffected).")
            return
        }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, err in
            if let err { NSLog("Synth: notification authorization failed: \(err.localizedDescription)") }
        }
    }

    // MARK: Posting

    /// needs-input / error → a persistent alert-style notification. (macOS's alert-vs-banner
    /// persistence is a per-app System Settings choice, not a per-request API; `.active`
    /// interruption is the DND-respecting lever we set.)
    @MainActor func postAttention(store: AppStore, id: UUID, kind: NotifKind) {
        guard available, let s = store.session(id) else { return }
        let soundOn = kind == .error ? store.soundError : store.soundNeedsInput
        submit(store, s, title: notifVerb(s.kind, kind), sound: soundOn)
    }

    /// A background worktree op failed while Synth wasn't frontmost — a freeform alert
    /// with no session to correlate; tapping it just activates Synth (the persistent
    /// in-app card is also waiting for when focus returns).
    @MainActor func postSystemError(title: String, body: String) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.interruptionLevel = .active
        if store?.soundError ?? true { content.sound = .default }
        add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    /// done → a transient banner (same `.active` interruption; the sound is opt-in and off by default).
    @MainActor func postDone(store: AppStore, id: UUID) {
        guard available, let s = store.session(id) else { return }
        submit(store, s, title: notifVerb(s.kind, .done), sound: store.soundDone)
    }

    @MainActor private func submit(_ store: AppStore, _ s: Session, title: String, sound: Bool) {
        let br = store.branch(of: s)
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = identity(store, s)              // title · branch · workspace
        content.interruptionLevel = .active
        content.threadIdentifier = br?.id.uuidString ?? "synth"   // group by branch
        content.userInfo = ["session": s.id.uuidString]
        if sound { content.sound = .default }
        add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    /// NC accepts or refuses asynchronously; a dropped error here is a notification that
    /// vanishes with no trace, so both outcomes leave a log line.
    private func add(_ req: UNNotificationRequest) {
        let title = req.content.title
        UNUserNotificationCenter.current().add(req) { err in
            if let err { NSLog("Synth: notification refused (\(title)): \(err.localizedDescription)") }
            else { NSLog("Synth: notification posted (\(title))") }
        }
    }

    /// "title · branch · workspace" — the session's place in the tree, for the body line.
    @MainActor private func identity(_ store: AppStore, _ s: Session) -> String {
        let br = store.branch(of: s)
        let ws = br.flatMap { store.workspace(of: $0) }
        return [s.title, br?.name, ws?.name].compactMap { $0 }.joined(separator: " · ")
    }

    // MARK: UNUserNotificationCenterDelegate

    /// Tapping a notification activates Synth and jumps to its session (same reveal/open/mark-read
    /// path the sidebar and ⌘K use), correlating via the UUID stashed in `userInfo`.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let id = (info["session"] as? String).flatMap(UUID.init(uuidString:))
        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)   // system errors carry no session — just come front
            if let id, let s = self.store?.session(id) { self.store?.jump(to: s) }
        }
        completionHandler()
    }

    /// Defensive — we only post while unfocused, but if one presents while active, show it.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

/// The one-line verb a state reads as — named for the agent doing it ("Claude finished",
/// "OpenCode needs your input"), a plain process for a terminal (working.html `notifWhat`).
/// Shared by the in-app card and the NC title.
@MainActor func notifVerb(_ session: SessionKind, _ kind: NotifKind) -> String {
    if let agent = session.agentID {
        let who = AgentRegistry.descriptor(agent)?.shortName ?? agent.rawValue
        switch kind {
        case .error: return "\(who) hit an error"
        case .input: return "\(who) needs your input"
        case .done:  return "\(who) finished"
        }
    }
    switch kind {
    case .input: return "needs input"
    // A browser session never changes status (it stays .idle for life, no indicator),
    // so these read as they would for any plain process.
    case .error: return "exited with an error"
    case .done:  return "finished"
    }
}
