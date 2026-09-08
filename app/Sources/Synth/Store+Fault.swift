import AppKit
import Foundation

/// The screen leg of the error spine. Every surface used here already existed — the deck,
/// the tiers, the row's `.error` status, the Notification Center path. What was missing was
/// anything that decided *which one* a given failure earns, so failures reached none of them.
extension AppStore {

    /// The spine's only door into the deck. It picks between the three shapes the app has:
    /// a live row wearing its own failure, an ambient card, and a sticky one.
    func present(_ r: Fault.Record, severity: Fault.Severity, repeats: Int) {
        guard let copy = r.copy else { return }
        let sub = [r.evidence, repeats > 0 ? "\(repeats + 1) times" : nil]
            .compactMap { $0 }.joined(separator: " · ")

        // A fault that belongs to a live row lands ON the row: `.error` status, the row's own
        // card, evidence on the sub line. This deliberately bypasses `routeTransition`, whose
        // first act is to return early when the failing session is the open one and Synth is
        // frontmost — right for a status change you watched happen, wrong for a pane that went
        // blank in 40ms, and no value of `NotifRoute` defeats it.
        if let id = r.session, let s = session(id) {
            s.status = .error
            sessionFaults[id] = r
            raiseInApp(id, .error, sub: sub.isEmpty ? nil : sub)
            if let retry = retryAction(copy.retry) { notifActions[id] = retry }
            if !NSApp.isActive {
                NotificationService.shared.postAttention(store: self, id: id, kind: .error)
            }
            return
        }

        switch severity {
        case .note, .degraded:
            return          // counted, logged, never said — see the severity ladder in Fault
        case .failed:
            raiseAmbientToast(.error, message: copy.title, title: "Synth",
                              icon: Phosphor.exclamation, sub: sub.isEmpty ? nil : sub)
        case .blocked:
            raiseSystemFault(copy, sub: sub)
        }
    }

    /// A capability is gone for the run — a sticky card that waits until it is clicked, and
    /// a Notification Center alert when Synth isn't frontmost. Same chassis as
    /// `raiseWorktreeError`, with a branch and a workspace it doesn't have.
    private func raiseSystemFault(_ copy: Fault.Copy, sub: String) {
        notifSeq += 1
        let id = UUID()
        notifs.append(InAppNotif(id: id, kind: .error, seq: notifSeq, sessionKind: .terminal,
                                 title: "Synth", colorIndex: nil, outlivesSession: true,
                                 message: copy.title, iconPath: Phosphor.exclamation,
                                 tier: .attention, sub: sub.isEmpty ? nil : sub,
                                 action: copy.retry == .none ? nil : NotifAction(label: label(copy.retry))))
        if let retry = retryAction(copy.retry) { notifActions[id] = retry }
        if !NSApp.isActive {
            NotificationService.shared.postSystemError(title: copy.title,
                                                       body: sub.isEmpty ? copy.title : sub)
        }
    }

    private func label(_ retry: Fault.Retry) -> String {
        switch retry {
        case .none: return ""
        case .respawnSession: return "Retry"
        case .restartSynth: return "Quit"
        }
    }

    /// A `Fault.Retry` is a name, not a closure — this is the one place it becomes work.
    private func retryAction(_ retry: Fault.Retry) -> (@MainActor () -> Void)? {
        switch retry {
        case .none:
            return nil
        case .respawnSession(let id):
            return { [weak self] in self?.respawnTerminal(id) }
        case .restartSynth:
            return { NSApp.terminate(nil) }
        }
    }

    /// Throw away the dead surface and ask for a new one. The pane re-reads
    /// `TerminalManager.view(for:)` on the next layout pass, so this is the whole retry.
    func respawnTerminal(_ id: UUID) {
        guard let s = session(id) else { return }
        sessionFaults[id] = nil
        TerminalManager.shared.terminate(id)
        s.status = .idle
        clearNotif(id)
    }
}
