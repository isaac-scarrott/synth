import Foundation

/// `Synth --agent-check <command>`: print what a launch would actually exec for `command`, and
/// exit nonzero when nothing would. Rerunnable by the verifier (`app/harness/agents`), which is
/// the point of it — alias resolution decides whether a row can start at all, and it happens in
/// a login+interactive shell that a test can otherwise only observe by driving a whole session.
///
/// The output is the resolution, not a verdict on the agent: which program, which arguments its
/// name already carried, and what the name expanded to on the way.
@MainActor
enum AgentCheck {
    static func run(_ command: String) -> Never {
        ShellEnvironment.waitUntilResolved()
        let words = AgentDescriptor.expandAliases(command) ?? []
        // Resolution is a descriptor's job (it owns the PATH search and the impostor rules), so
        // ask through one wearing the typed command's name rather than reimplementing it here.
        let probe = AgentDescriptor(id: AgentID("check"), displayName: command, shortName: command,
                                    binaryName: command, mark: .sparkle, installHints: [])
        guard let resolved = probe.resolvedCommand else {
            print("FAIL agent-resolved \(command)\(words.isEmpty ? "" : " -> \(words.joined(separator: " "))")")
            exit(1)
        }
        print("PASS agent-resolved \(command) -> \(resolved.path)")
        print("PASS agent-args \(resolved.args.joined(separator: " "))")
        if words != [command] { print("PASS agent-via \(words.joined(separator: " "))") }
        exit(0)
    }
}
