import Foundation
#if canImport(Glibc)
import Glibc
#endif

// synth-hook — the bridge between a coding-agent process and the Synth app.
//
// Roles, dispatched by how it's invoked:
//   • as an agent's binary name (`claude`, `opencode` — symlinks Synth puts first on PATH):
//     the LAUNCH role. An agent has no way to know it's inside Synth, so we intercept its
//     command, inject whatever makes it observable, and hand control to the real binary.
//       – claude:   inject our hook config (`--settings`) + a fresh `--session-id`. Status
//                   then arrives as hook callbacks (the EVENT role below).
//       – opencode: inject `--port <assigned>` so its built-in server listens where the app
//                   already subscribes, and report agent-start/agent-end around it. opencode
//                   publishes its own typed event stream, so no hooks are needed.
//     Non-interactive invocations (`claude -p`, `opencode run`, subcommands) pass through.
//   • as `synth-hook event <Event>`: the EVENT role. Claude fires this per hook; we read
//     the event JSON on stdin, classify it to a status signal, and write one line to the
//     app's unix socket (path in $SYNTH_SOCKET_PATH), tagged with $SYNTH_SESSION_ID.
//   • as `synth-hook report --signal <name>`: the REPORT role. Synth's injected zsh hooks
//     fire this on a plain terminal's command start/finish, writing the same signal line to
//     the same socket — so a bare shell reports its process lifecycle through the same pipe.
//
// Correlation is entirely by env: Synth spawns the PTY with SYNTH_SESSION_ID (the row),
// SYNTH_SOCKET_PATH, SYNTH_HOOK_BIN and a SYNTH_REAL_<AGENT> per installed agent; the agent
// and its hooks inherit them.

let env = ProcessInfo.processInfo.environment
let invokedName = (CommandLine.arguments[0] as NSString).lastPathComponent

switch invokedName {
case "claude":
    runClaudeLaunch(userArgs: Array(CommandLine.arguments.dropFirst()))
case "opencode":
    runOpencodeLaunch(userArgs: Array(CommandLine.arguments.dropFirst()))
default:
    let sub = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ""
    switch sub {
    case "launch":
        // `synth-hook launch -- <args>` (explicit form, in case PATH-shim isn't used)
        let after = CommandLine.arguments.firstIndex(of: "--").map { Array(CommandLine.arguments[($0 + 1)...]) } ?? []
        runClaudeLaunch(userArgs: after)
    case "event":
        runEvent(name: CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "")
    case "report":
        runReport(args: Array(CommandLine.arguments.dropFirst(2)))
    default:
        FileHandle.standardError.write(Data("synth-hook: unknown invocation\n".utf8))
        exit(2)
    }
}

/// Announce an agent attaching/detaching from this row, so Synth flips the row's kind and
/// (for a stream-based agent) connects its supervisor.
func reportAgent(_ signal: String) {
    guard let sessionID = env["SYNTH_SESSION_ID"], let socketPath = env["SYNTH_SOCKET_PATH"] else { return }
    sendLines(socketPath: socketPath, jsonLine(["session": sessionID, "signal": signal]))
}

// MARK: - Launch role

/// The real binary for `agent`, or nil. `SYNTH_REAL_<AGENT>` can point back at a shim when Synth
/// is launched from inside another Synth session (its PATH already carries a `synth-shims-*`
/// dir). Exec'ing a shim would re-enter this launch role and self-exec forever, growing argv
/// each pass until execv fails with E2BIG.
func resolveAgentBinary(_ agent: String) -> String? {
    let hinted = env["SYNTH_REAL_" + agent.uppercased()].flatMap { $0.isEmpty ? nil : $0 }
    return hinted.flatMap { isShim($0) ? nil : $0 } ?? resolveOnPath(agent)
}

func runClaudeLaunch(userArgs: [String]) -> Never {
    guard let real = resolveAgentBinary("claude") else {
        FileHandle.standardError.write(Data("synth: claude not found\n".utf8))
        exit(127)
    }

    // Only instrument interactive sessions started inside Synth. A one-shot (`-p`) or a
    // subcommand isn't a session — pass it straight through so behaviour is unchanged.
    let subcommands: Set<String> = ["mcp", "config", "update", "doctor", "migrate-installer", "install", "--version", "-v"]
    let isOneShot = userArgs.contains("-p") || userArgs.contains("--print")
    let isSubcommand = userArgs.first.map { subcommands.contains($0) } ?? false
    let instrument = env["SYNTH_SESSION_ID"] != nil && !isOneShot && !isSubcommand

    guard instrument else { execReal(real, userArgs) }

    // Pull the user's own --settings (if any) out of the args so we can merge, not clobber —
    // Claude keeps only one --settings and its precedence changed across CLI versions.
    var args = userArgs
    let userSettings = takeSettingsValue(&args)
    let settings = buildSettingsJSON(userSettings: userSettings)
    // A resume/continue carries its own session id, so don't mint a fresh `--session-id`
    // (Claude rejects both together). Synth uses this path to restore a Claude row —
    // `claude --resume <id>` — and hooks still fire because we keep injecting `--settings`.
    let resuming = args.contains { ["--resume", "-r", "--continue", "-c"].contains($0) }
    let idArgs = resuming ? [] : ["--session-id", UUID().uuidString]
    spawnReportingExit(real, idArgs + ["--settings", settings] + args)
}

/// opencode publishes its own event stream, so it needs no hooks — only a known port. The app
/// assigns one per row (`SYNTH_OPENCODE_PORT`) and subscribes there; the shim makes the TUI's
/// built-in server listen on it. The credentials the app locks that server to ride the env.
///
/// `agent-start` is reported by the shim rather than by the agent (as Claude's SessionStart hook
/// does), because opencode has nothing to call back with — the shim's own lifetime *is* the
/// session's.
func runOpencodeLaunch(userArgs: [String]) -> Never {
    guard let real = resolveAgentBinary("opencode") else {
        FileHandle.standardError.write(Data("synth: opencode not found\n".utf8))
        exit(127)
    }

    // Only the bare TUI is a session. `opencode run …`, `serve`, and the management
    // subcommands pass through untouched, exactly as `claude -p` does.
    let subcommands: Set<String> = ["run", "serve", "attach", "acp", "web", "auth", "providers",
                                    "models", "upgrade", "uninstall", "mcp", "agent", "stats",
                                    "export", "import", "github", "pr", "session", "plugin",
                                    "db", "debug", "completion", "--version", "-v"]
    let isSubcommand = userArgs.first.map { subcommands.contains($0) } ?? false
    let port = env["SYNTH_OPENCODE_PORT"].flatMap { $0.isEmpty ? nil : $0 }
    let instrument = env["SYNTH_SESSION_ID"] != nil && !isSubcommand && port != nil

    guard instrument, let port else { execReal(real, userArgs) }

    // A user's own `--port` wins — they've asked for a specific one, and the supervisor simply
    // never connects rather than fighting them for the socket.
    let portArgs = userArgs.contains("--port") ? [] : ["--port", port]
    reportAgent("agent-start:\(AgentIDRaw.opencode)")
    spawnReportingExit(real, portArgs + userArgs, agent: AgentIDRaw.opencode)
}

/// The `AgentID.rawValue`s the app persists and the shim reports. Duplicated (not shared) because
/// synth-hook is a standalone Foundation-only executable that must not link the app target.
enum AgentIDRaw {
    static let claudeCode = "claudeCode"
    static let opencode = "opencode"
}

/// Run the real agent as a child, then mirror its exit — reporting the true code over the
/// hook socket first. An exec would be simpler, but the code would die on the way up:
/// libghostty wraps every PTY child in macOS `login`, which exits 0 whatever its child's
/// status was, so the socket is the only channel the code survives (features 2026-07-06).
/// `agent` also announces the agent's departure once the child is gone.
func spawnReportingExit(_ path: String, _ args: [String], agent: String? = nil) -> Never {
    // The shim must outlive the session's own signals to still be there to report:
    // ignore INT/QUIT here, hand the child the defaults back.
    var attr: posix_spawnattr_t?
    posix_spawnattr_init(&attr)
    var childDefaults = sigset_t()
    sigemptyset(&childDefaults)
    sigaddset(&childDefaults, SIGINT)
    sigaddset(&childDefaults, SIGQUIT)
    posix_spawnattr_setsigdefault(&attr, &childDefaults)
    posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSIGDEF))
    signal(SIGINT, SIG_IGN)
    signal(SIGQUIT, SIG_IGN)

    let argv = ([path] + args).map { strdup($0) } + [nil]
    var pid: pid_t = 0
    let rc = posix_spawn(&pid, path, nil, &attr, argv, environ)
    posix_spawnattr_destroy(&attr)
    guard rc == 0 else {
        FileHandle.standardError.write(Data("synth: spawn failed: \(String(cString: strerror(rc)))\n".utf8))
        exit(126)
    }
    var status: Int32 = 0
    while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
    let code: Int32 = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
    if let agent { reportAgent("agent-end:\(agent)") }
    if let sessionID = env["SYNTH_SESSION_ID"], let socketPath = env["SYNTH_SOCKET_PATH"] {
        sendLines(socketPath: socketPath, jsonLine(["session": sessionID, "exitCode": String(code)]))
    }
    exit(code)
}

/// Remove a `--settings <value>` pair from the args and return the value, if present.
func takeSettingsValue(_ args: inout [String]) -> String? {
    guard let i = args.firstIndex(of: "--settings"), i + 1 < args.count else { return nil }
    let value = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return value
}

/// Our hooks, deep-merged with any user-supplied settings (hook arrays concatenated so
/// both fire; user scalar keys win). Returns a compact JSON string for `--settings`.
func buildSettingsJSON(userSettings: String?) -> String {
    let bin = env["SYNTH_HOOK_BIN"] ?? CommandLine.arguments[0]
    let q = shellQuote(bin)
    func hook(_ event: String, timeout: Int? = nil) -> [String: Any] {
        var h: [String: Any] = ["type": "command", "command": "\(q) event \(event)"]
        if let timeout { h["timeout"] = timeout }
        return ["hooks": [h]]
    }
    // A `*`-matched tool hook (any tool), for the post-execution "back to working" signals.
    func toolHook(_ event: String) -> [String: Any] {
        ["matcher": "*", "hooks": [["type": "command", "command": "\(q) event \(event)"]]]
    }
    let hooks: [String: Any] = [
        "SessionStart":     [hook("SessionStart")],
        "UserPromptSubmit": [hook("UserPromptSubmit")],
        "Stop":             [hook("Stop")],
        "StopFailure":      [hook("StopFailure")],
        "SessionEnd":       [hook("SessionEnd")],
        "Notification":     [hook("Notification")],
        // The permission dialog appearing means Claude is waiting on the user. Observe only
        // (exit 0, no decision) so the normal permission flow is untouched.
        "PermissionRequest": [hook("PermissionRequest", timeout: 120)],
        // Under --dangerously-skip-permissions no PermissionRequest fires, so catch the two
        // tools that always block on the user directly.
        "PreToolUse": [["matcher": "AskUserQuestion|ExitPlanMode",
                        "hooks": [["type": "command", "command": "\(q) event PreToolUse"]]]],
        // A tool finishing means Claude is unblocked and actively working again — this is
        // what clears `needsInput` after the user answers a question, approves a plan, or
        // grants a permission (none of which have a dedicated "resumed" hook). Matching every
        // tool also self-heals a dropped/reordered signal: the next tool call re-asserts
        // `working`. ~4ms per call, dwarfed by tool + model latency.
        "PostToolUse":        [toolHook("PostToolUse")],
        "PostToolUseFailure": [toolHook("PostToolUseFailure")],
    ]
    var settings: [String: Any] = [
        "hooks": hooks,
        // Claude's own OSC/terminal notifications would double up with ours — silence them.
        "preferredNotifChannel": "notifications_disabled",
    ]
    if let userSettings, let userObj = parseSettings(userSettings) {
        settings = mergeSettings(ours: settings, user: userObj)
    }
    let data = (try? JSONSerialization.data(withJSONObject: settings)) ?? Data("{}".utf8)
    return String(data: data, encoding: .utf8) ?? "{}"
}

/// A user `--settings` value is either an inline JSON object or a path to one.
func parseSettings(_ value: String) -> [String: Any]? {
    if let obj = (try? JSONSerialization.jsonObject(with: Data(value.utf8))) as? [String: Any] { return obj }
    if let data = FileManager.default.contents(atPath: value),
       let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] { return obj }
    return nil
}

func mergeSettings(ours: [String: Any], user: [String: Any]) -> [String: Any] {
    var out = ours
    for (key, value) in user {
        if key == "hooks", let userHooks = value as? [String: Any] {
            var merged = (out["hooks"] as? [String: Any]) ?? [:]
            for (event, arr) in userHooks {
                let existing = (merged[event] as? [Any]) ?? []
                let added = (arr as? [Any]) ?? []
                merged[event] = existing + added
            }
            out["hooks"] = merged
        } else {
            out[key] = value   // user scalar / non-hook keys win
        }
    }
    return out
}

func execReal(_ path: String, _ args: [String]) -> Never {
    let argv = ([path] + args).map { strdup($0) } + [nil]
    execv(path, argv)
    FileHandle.standardError.write(Data("synth: exec failed: \(String(cString: strerror(errno)))\n".utf8))
    exit(126)
}

/// Fallback lookup when `SYNTH_REAL_<AGENT>` is unset or points at a shim — scan PATH for the
/// first `name` that is the real binary, not one of our shims. Skipping only `$SYNTH_SHIM_DIR`
/// isn't enough: stale `synth-shims-*` dirs accumulate on PATH, and any of their symlinks
/// resolves back to this binary, so exec'ing one would loop.
func resolveOnPath(_ name: String) -> String? {
    for dir in (env["PATH"] ?? "").split(separator: ":").map(String.init) {
        let candidate = dir + "/" + name
        if FileManager.default.isExecutableFile(atPath: candidate), !isShim(candidate) { return candidate }
    }
    return nil
}

/// True when `path` is (or symlinks to) a `synth-hook` shim — the identity we must never
/// exec as the agent, or the launch role re-enters itself.
func isShim(_ path: String) -> Bool {
    let resolved = (try? FileManager.default.destinationOfSymbolicLink(atPath: path)).map {
        ($0 as NSString).isAbsolutePath ? $0 : (path as NSString).deletingLastPathComponent + "/" + $0
    } ?? path
    return (resolved as NSString).lastPathComponent == "synth-hook"
}

// MARK: - Event role

func runEvent(name: String) -> Never {
    guard let sessionID = env["SYNTH_SESSION_ID"], let socketPath = env["SYNTH_SOCKET_PATH"] else { exit(0) }
    let stdin = FileHandle.standardInput.readDataToEndOfFile()
    let payload = (try? JSONSerialization.jsonObject(with: stdin)) as? [String: Any] ?? [:]

    let signal: String?
    switch name {
    case "SessionStart":     signal = "agent-start:\(AgentIDRaw.claudeCode)"
    case "SessionEnd":       signal = "agent-end:\(AgentIDRaw.claudeCode)"
    case "UserPromptSubmit": signal = "working"
    // A tool completing (or failing) means the user has answered / approved and Claude is
    // running again — clears whatever `needsInput` the preceding PreToolUse/PermissionRequest set.
    case "PostToolUse", "PostToolUseFailure": signal = "working"
    case "Stop":             signal = "idle"
    case "StopFailure":      signal = "error"
    case "PermissionRequest", "PreToolUse":
        signal = "needsInput"
    case "Notification":
        let type = payload["notification_type"] as? String ?? ""
        // elicitation_dialog: an MCP server is prompting the user mid-tool — also a block.
        signal = ["permission_prompt", "idle_prompt", "agent_needs_input", "elicitation_dialog"].contains(type) ? "needsInput" : nil
    default:
        signal = nil
    }
    // A brand-new conversation (a fresh `startup` or `/clear`) starts with an empty transcript,
    // so `readAITitle` finds nothing and the row would keep the *previous* conversation's title
    // until Claude regenerates one turns later. Tell the app to drop it now. `resume`/`compact`
    // continue the same conversation (and title), so they never reset.
    let resetTitle = name == "SessionStart"
        && ["startup", "clear"].contains(payload["source"] as? String ?? "")

    // Claude Code writes an `ai-title` line into the transcript (a short, evolving title it
    // generates) — read the latest and forward it so Synth can auto-name the row.
    let title = (payload["transcript_path"] as? String).flatMap(readAITitle)

    // Claude's own session id (present on every hook payload) — forwarded so Synth can
    // resume this conversation with `claude --resume <id>` after a restart.
    let agentSession = (payload["session_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }

    var lines = ""
    if let signal { lines += jsonLine(["session": sessionID, "signal": signal]) }
    if resetTitle { lines += jsonLine(["session": sessionID, "titleReset": "1"]) }
    if let title  { lines += jsonLine(["session": sessionID, "title": title]) }
    if let agentSession { lines += jsonLine(["session": sessionID, "agentSession": agentSession]) }
    if !lines.isEmpty { sendLines(socketPath: socketPath, lines) }
    exit(0)   // never block Claude — we only observe
}

// MARK: - Report role

/// `synth-hook report --signal <name> [--title <cmd>] | --exit <code>` — the terminal
/// counterpart to the event role. Synth's injected zsh preexec/precmd hooks call this to
/// report a foreground command's lifecycle (`term-run`, `term-idle`, `term-error`) over the
/// same socket, tagged with $SYNTH_SESSION_ID; the zshexit hook calls it with `--exit` to
/// carry the shell's true exit status past macOS `login` (which reports 0 regardless).
/// `--title` carries the command line on term-run so the row auto-names itself after what
/// it's running. A missing correlation env — a shell started outside Synth — is a silent
/// no-op, and it runs on every prompt, so it does the minimum: one line, one socket write,
/// no stdin read.
func runReport(args: [String]) -> Never {
    guard let sessionID = env["SYNTH_SESSION_ID"], let socketPath = env["SYNTH_SOCKET_PATH"] else { exit(0) }
    var lines = ""
    if let i = args.firstIndex(of: "--signal"), i + 1 < args.count {
        lines += jsonLine(["session": sessionID, "signal": args[i + 1]])
        if let t = args.firstIndex(of: "--title"), t + 1 < args.count,
           let title = rowTitle(fromCommand: args[t + 1]) {
            lines += jsonLine(["session": sessionID, "title": title])
        }
    }
    if let e = args.firstIndex(of: "--exit"), e + 1 < args.count {
        lines += jsonLine(["session": sessionID, "exitCode": args[e + 1]])
    }
    guard !lines.isEmpty else { exit(0) }
    sendLines(socketPath: socketPath, lines)
    exit(0)
}

/// A sidebar-sized name from a typed command line: first line only, whitespace collapsed,
/// capped — or nil when nothing usable remains.
func rowTitle(fromCommand cmd: String) -> String? {
    let firstLine = cmd.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true).first ?? ""
    let words = firstLine.split(whereSeparator: \.isWhitespace)
    guard !words.isEmpty else { return nil }
    var title = words.joined(separator: " ")
    if title.count > 60 { title = String(title.prefix(59)) + "…" }
    return title
}

/// The most recent `ai-title` in a Claude Code transcript (scanning from the end), or nil.
func readAITitle(_ path: String) -> String? {
    guard let data = FileManager.default.contents(atPath: path),
          let text = String(data: data, encoding: .utf8) else { return nil }
    for line in text.split(separator: "\n").reversed() where line.contains("\"ai-title\"") {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              obj["type"] as? String == "ai-title",
              let title = (obj["aiTitle"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else { continue }
        return title
    }
    return nil
}

func jsonLine(_ dict: [String: String]) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: dict),
          let s = String(data: data, encoding: .utf8) else { return "" }
    return s + "\n"
}

func sendLines(socketPath: String, _ payload: String) {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return }
    defer { close(fd) }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let cap = MemoryLayout.size(ofValue: addr.sun_path)
    _ = socketPath.withCString { src in
        withUnsafeMutablePointer(to: &addr.sun_path) { dst in
            dst.withMemoryRebound(to: CChar.self, capacity: cap) {
                strncpy($0, src, cap - 1)
            }
        }
    }
    let len = socklen_t(MemoryLayout<sockaddr_un>.size)
    let connected = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) }
    }
    guard connected == 0 else { return }
    _ = payload.withCString { write(fd, $0, strlen($0)) }
}

func shellQuote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
