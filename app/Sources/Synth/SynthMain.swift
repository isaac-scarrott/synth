// Process entry: `--browser-check`, `--simulator-check` and `--agent-check` run the self-checks
// instead of the UI (SynthApp keeps everything else).
import Foundation

@main
enum SynthMain {
    @MainActor
    static func main() {
        // Synth serves two unix sockets (the hook seam and the control socket). A client that
        // hangs up before reading its reply makes the reply's `write` raise SIGPIPE, whose
        // default action is to kill the process — so any local process could take the app down
        // by connecting and disconnecting. Servers ignore it and read the failed write instead.
        signal(SIGPIPE, SIG_IGN)

        if CommandLine.arguments.contains("--browser-check") {
            BrowserCheck.run()
        }
        if CommandLine.arguments.contains("--simulator-check") {
            SimulatorCheck.run()
        }
        if let i = CommandLine.arguments.firstIndex(of: "--agent-check"),
           i + 1 < CommandLine.arguments.count {
            AgentCheck.run(CommandLine.arguments[i + 1])
        }
        SynthApp.main()
    }
}
