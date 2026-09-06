import Foundation

/// OpenCode's token and cost history, read from the local database it already keeps.
///
/// One reader serves both generations because they differ in where the history lives, not in what
/// it says — v2 is a preview of the same product, and a board that showed them in two different
/// shapes would be reporting on Synth's plumbing rather than on the user's spending.
struct OpencodeUsageSource: UsageSource {
    enum Generation: Sendable { case v1, v2 }

    let agent: AgentID
    let generation: Generation

    func load() async -> UsageSection {
        UsageSection(id: agent,
                     title: generation == .v1 ? "OpenCode" : "OpenCode 2",
                     status: .unavailable("no usage data"))
    }
}
