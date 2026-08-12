import Foundation

/// Getting a comment to an agent — the one implementation, shared by the browser (ADR-0011 stage
/// three) and the simulator (ADR-0015). Extracted rather than copied because this is a security
/// boundary, and two copies of a security boundary is one copy too many.
///
/// SECURITY: a comment embeds text the *subject* controls — a page's title and element HTML, or an
/// app's accessibility labels. Claude Code has no injection API, so delivery pastes the text and
/// presses Enter. Into anything but a live Claude TUI (say the bare shell left behind when a restored
/// row's `claude --resume` fails) that would hand a hostile page or app arbitrary shell execution. So
/// delivery runs ONLY against a session the supervisor seam has confirmed live — immediately when one
/// exists, else after booting the target row and WAITING for its liveness signal, never merely for
/// its terminal view existing. (opencode delivers over its message API, where there is no shell to
/// fall back to; the same gate applies and costs nothing.)
///
/// The ladder: owner live → deliver; owner dormant → boot it and wait; no owner → spawn a fresh agent
/// in the branch, adopt the subject under it so the next comment hits the first rung, and
/// boot-and-wait.
///
/// Every Swift string logged here goes through `%@`. A `%s` hands `strlen` a tagged NSString pointer
/// and faults — and libghostty's bundled Breakpad owns the task's Mach exception ports, so that fault
/// arrives as neither a signal nor a crash report, only a silent `exit(1)` seconds after a comment was
/// delivered. One `%s` on the success line is what took the whole app down and withheld this feature.
@MainActor
final class CommentDelivery {

    /// The row being commented on: the one adopted when a fresh agent is spawned, and the one focus
    /// returns to after the spawn's momentary detour.
    let subjectID: UUID
    private weak var store: AppStore?
    /// How the subject is described in logs — "browser" or "simulator".
    private let subjectKindLabel: String

    /// Transient user-facing text, surfaced by whichever pane owns this.
    var onNotice: ((String) -> Void)?
    /// The resolved target's title, for the bar's chip. Nil when there is no owner yet.
    var onTarget: ((String?) -> Void)?
    /// The ladder's terminal answer, for a subject that holds its comments until it hears one:
    /// `onLanded` with the receiving row's title, or `onLost` with a short reason. The browser's
    /// queue lives on the page and only a landed delivery may take it off (ADR-0011) — a batch
    /// cleared on the way out would be gone from both sides when the last rung fails. The
    /// simulator sends one comment at a time and holds nothing, so it leaves these nil.
    var onLanded: ((String) -> Void)?
    var onLost: ((String) -> Void)?

    private var deliveryTask: Task<Void, Never>?

    init(sessionID: UUID, store: AppStore?, subjectKindLabel: String) {
        self.subjectID = sessionID
        self.store = store
        self.subjectKindLabel = subjectKindLabel
    }

    func cancel() {
        deliveryTask?.cancel()
        deliveryTask = nil
    }

    /// The agent row that owns the subject, if any.
    func ownerRow() -> Session? {
        guard let store, let session = store.session(subjectID) else { return nil }
        return store.owner(of: session)
    }

    /// `count` is how many comments this message carries — the browser batches, the simulator sends
    /// one at a time. It only ever changes wording, but the wording is the whole feedback the user
    /// gets that a batch went somewhere.
    func deliver(_ message: String, count: Int = 1, screenshots: [String]) {
        guard let store, let subject = store.session(subjectID) else {
            Self.discard(screenshots)
            return
        }
        if let owner = ownerRow() {
            onTarget?(owner.title)
            // Rung 1: live owner — hand it to the agent's supervisor now.
            if let supervisor = store.liveSupervisor(for: owner), supervisor.deliver(message, to: owner.id) {
                NSLog("Synth: %@ comment delivered to owning agent session %@ (%@)",
                      subjectKindLabel, owner.id.uuidString, owner.title)
                sent(count, to: owner.title)
                return
            }
            // Rung 2: dormant owner — open it (mounts the pane, launches the agent / resumes), then
            // wait for the supervisor seam before delivering.
            onNotice?("Opening \(owner.title) to deliver \(Self.theComments(count))…")
            store.open(owner)
            bootAndSubmit(owner, message: message, count: count, screenshots: screenshots)
            return
        }
        // Rung 3: unowned — spawn the subject's own agent. The PTY only boots when its pane mounts
        // (GhosttySurfaceView creates the surface on window attach), so open the row for one beat and
        // come straight back; both views live outside the SwiftUI tree and survive the swap.
        // `availableAgents`, not the registry's installed set: an agent switched off in Settings is
        // not one Synth may start, and "every agent is off" is a distinct thing to say — there is
        // nobody to send this to, which the user can fix.
        guard let agent = store.availableAgents.first?.id else {
            onNotice?("No agent enabled — turn one on in Settings")
            onLost?("No agent enabled")
            Self.discard(screenshots)
            return
        }
        guard let branch = store.branch(of: subject),
              let spawned = store.spawnAgent(agent, in: branch) else {
            onNotice?("Couldn't start an agent session for the comment")
            onLost?("Couldn't start an agent")
            Self.discard(screenshots)
            return
        }
        store.adopt(subject, by: spawned)
        onTarget?(spawned.title)
        store.open(spawned)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak store, subjectID] in
            guard let store, store.openSessionID == spawned.id,
                  let back = store.session(subjectID) else { return }
            store.open(back)
        }
        onNotice?("Starting \(spawned.title) to deliver \(Self.theComments(count))…")
        bootAndSubmit(spawned, message: message, count: count, screenshots: screenshots)
    }

    /// Boot-and-wait delivery to `row`: poll the hook seam for its liveness signal (~20s), then
    /// submit — the security boundary above, shared by rungs 2 and 3.
    private func bootAndSubmit(_ row: Session, message: String, count: Int,
                               screenshots: [String]) {
        deliveryTask?.cancel()
        deliveryTask = Task { [weak self] in
            for _ in 0..<40 {   // ~20s: the agent boots and reports in, or never will
                try? await Task.sleep(for: .seconds(0.5))
                guard let self, !Task.isCancelled else { return }
                guard let store = self.store, store.isLiveAgent(row.id) else { continue }
                // Live confirmed — one more beat so a TUI is past its first paint and won't eat an
                // early paste; re-check liveness after the beat.
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, store.isLiveAgent(row.id),
                      let supervisor = store.liveSupervisor(for: row) else { continue }
                if supervisor.deliver(message, to: row.id) {
                    NSLog("Synth: %@ comment delivered to agent session %@ (%@) after booting it",
                          self.subjectKindLabel, row.id.uuidString, row.title)
                    self.sent(count, to: row.title)
                    return
                }
            }
            // The agent never reported in (e.g. the resume failed and left a bare shell): drop the
            // comment — and its now-orphaned screenshots — rather than paste.
            self?.onNotice?("Couldn't reach “\(row.title)” — "
                + (count == 1 ? "comment" : "comments") + " not delivered")
            self?.onLost?("Couldn't reach \(row.title)")
            Self.discard(screenshots)
        }
    }

    private func sent(_ count: Int, to title: String) {
        onNotice?(count == 1 ? "Comment sent to \(title)" : "\(count) comments sent to \(title)")
        onLanded?(title)
    }

    private static func theComments(_ count: Int) -> String {
        count == 1 ? "the comment" : "the \(count) comments"
    }

    /// Screenshots captured for a comment that was never delivered are orphans — remove.
    static func discard(_ screenshots: [String]) {
        for path in screenshots {
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    /// Where a subject's comment screenshots live.
    static func commentsDir(sessionID: UUID) -> URL {
        let dir = AppSupport.dir("comments/\(sessionID.uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func timestamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return f.string(from: Date())
    }
}
