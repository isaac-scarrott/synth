import Foundation

/// What Synth found when it asked a command who it is — the answer a custom agent's Settings row
/// states, and the reason adding one is a single field: the user types `claude-personal`, Synth
/// runs `claude-personal --version` and recognises Claude Code's own answer.
///
/// Recognition is not a nicety. Which built-in drives a command decides how its status is read,
/// how a comment reaches it, and what its quit does — so it has to be KNOWN, and asking the
/// binary is the only way to know it without asking the user to.
struct AgentProbeResult: Equatable, Sendable {
    enum State: Equatable, Sendable {
        /// Nothing on the login-shell PATH answers to that name.
        case missing
        /// It answers, but nothing in the reply is an agent Synth can read.
        case unrecognised
        /// It answers as one of the built-ins.
        case recognised(AgentID)
    }

    var state: State
    /// The first line of its `--version` output, trimmed — what the row shows when it is happy.
    var version: String?
    /// The command line the name expanded to, when it wasn't a program to begin with — a shell
    /// alias, followed to what it stands for. Nil when the name WAS the program, which is the
    /// ordinary case and needs no explaining on the row.
    var via: String?

    var base: AgentID? {
        if case let .recognised(id) = state { return id }
        return nil
    }
}

/// Runs `<command> --version` in a login shell and reads the answer. A login shell, because that
/// is the PATH a launched agent will resolve under (`ShellEnvironment`) — a command Synth can't
/// see there is one the session couldn't run either.
///
/// What is asked is not the typed name but the program that name resolves to, alias followed
/// (`AgentDescriptor.expandAliases`). Two reasons, and they are the same reason: an alias is
/// invisible to every shell Synth spawns, so asking by name would answer "missing" for a command
/// the user runs every day; and the row must describe what a session will ACTUALLY exec, which
/// after the alias is followed is a different program with different arguments.
enum AgentProbe {
    /// What each built-in answers to, read on the main actor and carried into the probe — the
    /// registry is main-actor state, and a background thread has no business reaching into it.
    struct Signature: Sendable {
        let id: AgentID
        let markers: [String]
    }

    /// Probe off the main thread, with a timeout: a wrapper script that stops to think must not
    /// wedge Settings, and a broken one must not wedge it forever.
    @MainActor static func probe(_ binary: String) async -> AgentProbeResult {
        let command = binary.trimmingCharacters(in: .whitespaces)
        guard !command.isEmpty else { return AgentProbeResult(state: .missing, version: nil) }
        let signatures = AgentRegistry.builtIn.map { Signature(id: $0.id, markers: $0.versionMarkers) }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                // The alias table comes from the login-shell probe, which may still be in flight
                // on a cold start. Waiting for it is the difference between "missing" and the
                // right answer, and this is already off the main thread.
                ShellEnvironment.waitUntilResolved()
                continuation.resume(returning: run(command, signatures))
            }
        }
    }

    /// The synchronous body. Nothing is interpolated into the shell line unquoted — the command is
    /// a string the user typed, and `--version` is the only argument it is ever given. An alias's
    /// own arguments are deliberately NOT passed: which agent a program is, is a fact about the
    /// program, and a wrapper handed flags it doesn't know may answer with an error instead.
    private static func run(_ command: String, _ signatures: [Signature]) -> AgentProbeResult {
        // An alias that stands for a shell fragment rather than a program comes back nil: there
        // is nothing here Synth could exec, so the row says the same thing as a name that isn't
        // there at all.
        guard let words = AgentDescriptor.expandAliases(command), let head = words.first else {
            return AgentProbeResult(state: .missing, version: nil)
        }
        let via = words == [command] ? nil : words.joined(separator: " ")
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: shell)
        // `command -v` first: a name that resolves to nothing answers "missing" in milliseconds,
        // without waiting on a `--version` that was never going to run.
        let quoted = shellQuoteAgentArg(head)
        proc.arguments = ["-l", "-c",
                          "command -v \(quoted) >/dev/null 2>&1 || exit 127; \(quoted) --version 2>/dev/null"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        proc.standardInput = FileHandle.nullDevice
        do { try proc.run() } catch { return AgentProbeResult(state: .missing, version: nil) }

        // Drain off-thread so a chatty rc file can't fill the pipe and deadlock the child before
        // it exits, then join with a timeout and kill it if it hangs — the same shape as
        // `ShellEnvironment.probe`, for the same reasons.
        let box = OutputBox()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            box.data = pipe.fileHandleForReading.readDataToEndOfFile()
            done.signal()
        }
        if done.wait(timeout: .now() + 6) == .timedOut {
            proc.terminate()
            return AgentProbeResult(state: .missing, version: nil)
        }
        proc.waitUntilExit()
        guard proc.terminationStatus != 127 else { return AgentProbeResult(state: .missing, version: nil) }

        let out = String(data: box.data, encoding: .utf8) ?? ""
        // rc-file chatter lands above the answer, so read the last non-empty line, not the first.
        let answer = out.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty }
        guard let answer, !answer.isEmpty else {
            // It resolved but said nothing a version parser could use. It is still there — which is
            // the half of the answer that decides whether the row can be launched at all.
            return AgentProbeResult(state: .unrecognised, version: nil, via: via)
        }
        let hay = answer.lowercased()
        if let match = signatures.first(where: { s in s.markers.contains { hay.contains($0) } }) {
            return AgentProbeResult(state: .recognised(match.id), version: answer, via: via)
        }
        return AgentProbeResult(state: .unrecognised, version: answer, via: via)
    }

    /// Ferries the drained output across the semaphore's happens-before edge.
    private final class OutputBox: @unchecked Sendable { var data = Data() }
}
