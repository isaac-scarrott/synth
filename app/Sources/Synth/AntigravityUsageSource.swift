import Foundation

/// Antigravity's quota buckets, read from the agent's own local server.
struct AntigravityUsageSource: UsageSource {
    let agent = AgentID.antigravity

    func load() async -> UsageSection {
        UsageSection(id: agent, title: "Antigravity", status: .unavailable("no usage data"))
    }
}
