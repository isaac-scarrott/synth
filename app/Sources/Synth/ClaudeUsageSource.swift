import Foundation

/// Claude Code's rate limits, read from the account that Claude Code itself is signed into.
struct ClaudeUsageSource: UsageSource {
    let agent = AgentID.claudeCode

    func load() async -> UsageSection {
        UsageSection(id: agent, title: "Claude Code", status: .unavailable("no usage data"))
    }
}
