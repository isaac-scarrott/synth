import Foundation

/// Every agent's usage reader, assembled for the board.
///
/// Each agent's numbers arrive over a different transport — the same asymmetry the supervisors
/// already live with — so there is no shared client here, only a list of readers that each know
/// one agent's own account or local history.
enum UsageSources {
    /// Readers for the agents Synth may actually run. An agent with no reader is not an error:
    /// its band says so, which is honest about the fact that not every agent publishes usage.
    @MainActor static func all(for agents: [AgentDescriptor]) -> [UsageSource] {
        agents.compactMap { source(for: $0) }
    }

    /// Dispatch on `hostID`, so a custom agent is read by whichever built-in hosts it — the same
    /// rule that picks its supervisor. The whole descriptor goes to the reader rather than just
    /// its id: a custom agent's band has to carry the user's own name for it, and reach the
    /// command the user pointed it at, not the built-in's.
    @MainActor private static func source(for agent: AgentDescriptor) -> UsageSource? {
        switch agent.hostID {
        case .claudeCode: return ClaudeUsageSource(descriptor: agent)
        case .opencode: return OpencodeUsageSource(descriptor: agent, generation: .v1)
        case .opencode2: return OpencodeUsageSource(descriptor: agent, generation: .v2)
        case .antigravity: return AntigravityUsageSource(descriptor: agent)
        default: return nil
        }
    }
}
