import Foundation

/// The roll-up token a status contributes, and its precedence.
/// Mirrors working.html: needs-input > error > working > running > idle.
enum RollupState: Int, Comparable {
    case input = 0, error, work, run, idle
    static func < (lhs: RollupState, rhs: RollupState) -> Bool { lhs.rawValue < rhs.rawValue }
}

extension SessionStatus {
    /// Human-readable label for tooltips.
    var label: String {
        switch self {
        case .running:    return "Busy"
        case .idle:       return "Idle"
        case .exited:     return "Exited"
        case .working:    return "Busy"
        case .needsInput: return "Needs input"
        case .error:      return "Error"
        }
    }

    var rollup: RollupState {
        switch self {
        case .needsInput:        return .input
        case .error:             return .error
        case .working:           return .work
        case .running:           return .run
        case .idle, .exited:     return .idle
        }
    }
}

extension Branch {
    /// Highest-priority session state, or nil when every session is idle
    /// (caller then shows last-activity).
    var rollup: RollupState? {
        let worst = sessions.map(\.status.rollup).min()
        return (worst == nil || worst == .idle) ? nil : worst
    }

    /// A collapsed branch with a finished-but-unseen session surfaces an unread
    /// cue once it has settled: below the live roll-up states (which win while
    /// anything is still live), above last-activity. Mirrors working.html
    /// rollUpGroups' unread fallback.
    var hasUnread: Bool { sessions.contains(where: \.unread) }
}

extension Workspace {
    /// The attention roll-up shown on a *collapsed* workspace: the worst of any
    /// nested session, but only when it demands attention (needs-input / error).
    /// Hidden once the workspace is open (the detail is then visible).
    var attention: RollupState? {
        let worst = branches.flatMap(\.sessions).map(\.status.rollup).min()
        switch worst {
        case .input, .error: return worst
        default:             return nil
        }
    }
}
