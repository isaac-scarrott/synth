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

    @MainActor private static func source(for agent: AgentDescriptor) -> UsageSource? {
        switch agent.hostID {
        case .claudeCode: return ClaudeUsageSource()
        case .opencode: return OpencodeUsageSource(agent: agent.id, generation: .v1)
        case .opencode2: return OpencodeUsageSource(agent: agent.id, generation: .v2)
        case .antigravity: return AntigravityUsageSource()
        default: return nil
        }
    }
}
