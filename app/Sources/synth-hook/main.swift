import Foundation
#if canImport(Glibc)
import Glibc
#endif

// synth-hook — the bridge between a coding-agent process and the Synth app.
//
// Roles, dispatched by how it's invoked:
//   • as an agent's binary name (`claude`, `opencode`, `agy` — symlinks Synth puts first on
//     PATH): the LAUNCH role. An agent has no way to know it's inside Synth, so we intercept its
//     command, inject whatever makes it observable, and hand control to the real binary.
//       – claude:   inject our hook config (`--settings`) + a fresh `--session-id`. Status
//                   then arrives as hook callbacks (the EVENT role below).
//       – opencode: inject `--port <assigned>` so its built-in server listens where the app
//                   already subscribes, and report agent-start/agent-end around it. opencode
//                   publishes its own typed event stream, so no hooks are needed.
//       – agy:      inject `--add-dir <synth dir>` carrying a `.agents/hooks.json` (agy loads
//                   one per workspace dir, added dirs included) so status arrives as hook
//                   callbacks like Claude's, plus `--log-file` for the confirmation prompts
//                   and interrupts no hook covers. agent-start/agent-end are reported around it.
//     The bundled MCP servers ride the same interception (`$SYNTH_MCP_*`, built by
//     `MCPInstaller.launchEnv`), each in the shape its agent takes one: `--mcp-config` for
//     claude, `OPENCODE_CONFIG_CONTENT` for opencode, `.agents/mcp_config.json` in the added
//     dir for agy. That is what keeps Synth from writing config into the user's worktree.
//     Non-interactive invocations (`claude -p`, `opencode run`, `agy --print`, subcommands)
//     pass through.
//   • as `synth-hook event <Event>`: the EVENT role. Claude and agy fire this per hook (agy's
//     events are namespaced `agy:<Event>`, since the two CLIs share event names for different
//     meanings); we read the event JSON on stdin, classify it to a status signal, and write one
//     line to the app's unix socket (path in $SYNTH_SOCKET_PATH), tagged with $SYNTH_SESSION_ID.
//   • as `synth-hook report --signal <name>`: the REPORT role. Synth's injected zsh hooks
//     fire this on a plain terminal's command start/finish, writing the same signal line to
//     the same socket — so a bare shell reports its process lifecycle through the same pipe.
//
// Correlation is entirely by env: Synth spawns the PTY with SYNTH_SESSION_ID (the row),
// SYNTH_SOCKET_PATH, SYNTH_HOOK_BIN and a SYNTH_REAL_<AGENT> per installed agent; the agent
// and its hooks inherit them.

let env = ProcessInfo.processInfo.environment
let invokedName = (CommandLine.arguments[0] as NSString).lastPathComponent

/// One agent Synth hosts, as the app describes it in `SYNTH_AGENT_MAP`: the command, the role
/// that drives it, and the id it reports as. The three are the same thing for a built-in and
/// three different things for a user's own command — `claude-personal` is driven by Claude's
/// role while reporting its own `AgentID`, which is what makes it its own row, its own flags and
/// its own mark instead of a second Claude Code.
struct HostedAgent {
    let binary: String
    let role: String
    let id: String
}

func hostedAgent(_ binary: String) -> HostedAgent? {
    for entry in (env["SYNTH_AGENT_MAP"] ?? "").split(separator: " ") {
        let f = entry.split(separator: ":", maxSplits: 2).map(String.init)
        if f.count == 3, f[0] == binary { return HostedAgent(binary: f[0], role: f[1], id: f[2]) }
    }
    return nil
}

// A shim is named after the command it stands in for, so the invoked name is the lookup key. With
// no map to consult (a stale env, or a hand-run shim) the built-in names still mean themselves.
let hosted = hostedAgent(invokedName)
switch hosted?.role ?? invokedName {
case AgentIDRaw.claudeCode, "claude":
    runClaudeLaunch(binary: invokedName, agentID: hosted?.id ?? AgentIDRaw.claudeCode,
                    userArgs: Array(CommandLine.arguments.dropFirst()))
case AgentIDRaw.opencode:
    runOpencodeLaunch(binary: invokedName, agentID: hosted?.id ?? AgentIDRaw.opencode,
                      userArgs: Array(CommandLine.arguments.dropFirst()))
case AgentIDRaw.antigravity, "agy":
    runAgyLaunch(binary: invokedName, agentID: hosted?.id ?? AgentIDRaw.antigravity,
                 userArgs: Array(CommandLine.arguments.dropFirst()))
default:
    let sub = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ""
    switch sub {
    case "launch":
        // `synth-hook launch -- <args>` (explicit form, in case PATH-shim isn't used)
        let after = CommandLine.arguments.firstIndex(of: "--").map { Array(CommandLine.arguments[($0 + 1)...]) } ?? []
        runClaudeLaunch(binary: "claude", agentID: AgentIDRaw.claudeCode, userArgs: after)
    case "event":
        // The launch role bakes the agent's id into the hook commands it writes, because an event
        // arrives as its own later process with nothing but this argv to say who it is about.
        runEvent(name: CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "",
                 agentID: CommandLine.arguments.count > 3 ? CommandLine.arguments[3] : nil)
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
    let hinted = env["SYNTH_REAL_" + envSuffix(agent)].flatMap { $0.isEmpty ? nil : $0 }
    return hinted.flatMap { isShim($0) ? nil : $0 } ?? resolveOnPath(agent)
}

/// The arguments the invoked name itself carried, for a name that was a shell alias
/// (`alias claude-personal='claude --model opus'`). The app resolved the alias — only an
/// interactive shell can — and passes what it stood for through `SYNTH_REAL_ARGS_<AGENT>`,
/// `\u{01}`-separated so an argument with a space in it survives the trip. They go in front of
/// the user's own, which is where the shell would have put them.
func aliasArgs(_ agent: String) -> [String] {
    guard let raw = env["SYNTH_REAL_ARGS_" + envSuffix(agent)], !raw.isEmpty else { return [] }
    return raw.components(separatedBy: "\u{01}").filter { !$0.isEmpty }
}

/// The alias's arguments in front of the user's own. Built by appending rather than with `+`:
/// 0.34.0 shipped a launch line assembled by chained concatenation and the release optimizer
/// miscompiled it into a trap (docs/features/2026-08-18.md), and this is the same argv on the
/// same path.
func withLeading(_ leading: [String], _ args: [String]) -> [String] {
    guard !leading.isEmpty else { return args }
    var out: [String] = []
    out.append(contentsOf: leading)
    out.append(contentsOf: args)
    return out
}

/// The env-key spelling of a command name. A user's own command can hold characters an env var
/// name can't (`claude-personal`), so everything outside `[A-Z0-9_]` becomes `_` — the same
/// transform `AgentDescriptor.envSuffix` applies, and the only reason the two ends agree.
func envSuffix(_ binary: String) -> String {
    String(binary.uppercased().map { $0.isLetter || $0.isNumber ? $0 : "_" })
}

func runClaudeLaunch(binary: String, agentID: String, userArgs: [String]) -> Never {
    guard let real = resolveAgentBinary(binary) else {
        FileHandle.standardError.write(Data("synth: \(binary) not found\n".utf8))
        exit(127)
    }
    let leading = aliasArgs(binary)

    // Only instrument interactive sessions started inside Synth. A one-shot (`-p`) or a
    // subcommand isn't a session — pass it straight through so behaviour is unchanged. The list
    // is every command the CLI answers to, which is more than `claude --help` prints: `attach`,
    // `daemon`, `logs`, `remote-control`, `respawn`, `rm`, `self-hosted-runner` and `stop` are
    // real and hidden, and `config`/`migrate-installer` survive on older installs. It errs
    // towards listing: a name missing here gets a session's flags and the subcommand fails
    // outright, while a name listed in error only costs that invocation its instrumentation.
    let subcommands: Set<String> = ["agents", "attach", "auth", "auto-mode", "config", "daemon",
                                    "doctor", "gateway", "import", "install", "logs", "mcp",
                                    "migrate-installer", "plugin", "plugins", "project",
                                    "remote-control", "respawn", "rm", "self-hosted-runner",
                                    "setup-token", "stop", "ultrareview", "update", "upgrade",
                                    "--version", "-v", "--help", "-h"]
    let isOneShot = userArgs.contains("-p") || userArgs.contains("--print")
    let isSubcommand = userArgs.first.map { subcommands.contains($0) } ?? false
    let instrument = env["SYNTH_SESSION_ID"] != nil && !isOneShot && !isSubcommand

    guard instrument else { execReal(real, withLeading(leading, userArgs)) }

    // Pull the user's own --settings (if any) out of the args so we can merge, not clobber —
    // Claude keeps only one --settings and its precedence changed across CLI versions.
    var args = userArgs
    let userSettings = takeSettingsValue(&args)
    let settings = buildSettingsJSON(userSettings: userSettings, agentID: agentID)
    // A resume/continue carries its own session id, so don't mint a fresh `--session-id`
    // (Claude rejects both together). Synth uses this path to restore a Claude row —
    // `claude --resume <id>` — and hooks still fire because we keep injecting `--settings`.
    let resuming = args.contains { ["--resume", "-r", "--continue", "-c"].contains($0) }
    let idArgs = resuming ? [] : ["--session-id", UUID().uuidString]
    // The bundled MCP servers, as JSON on the command line rather than a `.mcp.json` in the
    // user's worktree. The flag is repeatable and additive (no `--strict-mcp-config`), so a
    // user's own configuration — theirs on this line included — is untouched. Servers arriving
    // this way are also not the `.mcp.json` servers Claude asks to approve, so a fresh worktree
    // now meets only its trust prompt.
    //
    // `--mcp-config` takes a LIST (`<configs...>`), so whatever follows its value is read as
    // another config path until a flag ends the list — an injected one sitting last would eat
    // the user's first word, and a subcommand we failed to recognise died as
    // "MCP config file not found: <cwd>/setup-token". `--settings` always follows it (it is
    // always injected) and takes exactly one value, so nothing the user typed can be swallowed
    // whatever it is.
    var launchArgs = idArgs
    if let mcpConfig = env["SYNTH_MCP_CLAUDE"], !mcpConfig.isEmpty {
        launchArgs.append("--mcp-config")
        launchArgs.append(mcpConfig)
    }
    launchArgs.append("--settings")
    launchArgs.append(settings)
    // Appended one array at a time, never concatenated into a temporary: a chained `+` here is
    // what the release optimizer miscompiled in 0.34.0 (docs/features/2026-08-18.md).
    launchArgs.append(contentsOf: leading)
    launchArgs.append(contentsOf: args)
    spawnReportingExit(real, launchArgs)
}

/// opencode publishes its own event stream, so it needs no hooks — only a known port. The app
/// assigns one per row (`SYNTH_OPENCODE_PORT`) and subscribes there; the shim makes the TUI's
/// built-in server listen on it. The credentials the app locks that server to ride the env.
///
/// `agent-start` is reported by the shim rather than by the agent (as Claude's SessionStart hook
/// does), because opencode has nothing to call back with — the shim's own lifetime *is* the
/// session's.
func runOpencodeLaunch(binary: String, agentID: String, userArgs: [String]) -> Never {
    guard let real = resolveAgentBinary(binary) else {
        FileHandle.standardError.write(Data("synth: \(binary) not found\n".utf8))
        exit(127)
    }
    let leading = aliasArgs(binary)

    // Only the bare TUI is a session. `opencode run …`, `serve`, and the management
    // subcommands pass through untouched, exactly as `claude -p` does.
    let subcommands: Set<String> = ["run", "serve", "attach", "acp", "web", "auth", "providers",
                                    "models", "upgrade", "uninstall", "mcp", "agent", "stats",
                                    "export", "import", "github", "pr", "session", "plugin",
                                    "db", "debug", "completion", "--version", "-v"]
    let isSubcommand = userArgs.first.map { subcommands.contains($0) } ?? false
    let port = env["SYNTH_OPENCODE_PORT"].flatMap { $0.isEmpty ? nil : $0 }
    let instrument = env["SYNTH_SESSION_ID"] != nil && !isSubcommand && port != nil

    guard instrument, let port else { execReal(real, withLeading(leading, userArgs)) }

    // A user's own `--port` wins — they've asked for a specific one, and the supervisor simply
    // never connects rather than fighting them for the socket.
    let portArgs = userArgs.contains("--port") ? [] : ["--port", port]
    mergeOpencodeMCPConfig()
    reportAgent("agent-start:\(agentID)")
    spawnReportingExit(real, portArgs + withLeading(leading, userArgs), agent: agentID)
}

/// The bundled MCP servers reach opencode through `OPENCODE_CONFIG_CONTENT`, so nothing is
/// written into the worktree. opencode reads that variable last and merges it at project scope,
/// which leaves a user's own `opencode.json` in force.
///
/// Merged into whatever the variable already holds rather than set: it is the user's to use too,
/// and the login shell that runs this launch may have exported their value moments ago — the shim
/// is the last thing standing between them and opencode, which is the only place the two can meet.
/// An entry already under one of our names is left alone: a user who has registered
/// `synth-browser` themselves has said how they want it run, and the name is all either side has
/// to go on. Same rule as `--settings`, where the user's keys win. A value that doesn't parse is
/// left alone entirely — opencode will reject it and say so, which is a better answer for the
/// person who wrote it than Synth quietly replacing their config with its own.
func mergeOpencodeMCPConfig() {
    guard let ours = env["SYNTH_MCP_OPENCODE"], !ours.isEmpty,
          let servers = parseJSONObject(ours)?["mcp"] as? [String: Any] else { return }
    var root: [String: Any] = [:]
    if let existing = env["OPENCODE_CONFIG_CONTENT"], !existing.isEmpty {
        guard let theirs = parseJSONObject(existing) else { return }
        root = theirs
    }
    var mcp = root["mcp"] as? [String: Any] ?? [:]
    for (name, entry) in servers where mcp[name] == nil { mcp[name] = entry }
    root["mcp"] = mcp
    guard let data = try? JSONSerialization.data(withJSONObject: root),
          let merged = String(data: data, encoding: .utf8) else { return }
    setenv("OPENCODE_CONFIG_CONTENT", merged, 1)
}

/// agy (Antigravity CLI) is hook-driven like Claude Code, but it has no `--settings`: hooks are
/// only ever read from `<workspace>/.agents/hooks.json`. Writing that into the user's repo would
/// leave our instrumentation behind on disk, so the shim instead hands agy a Synth-owned dir
/// holding nothing but the hooks — `--add-dir`'d dirs are workspaces too, and their hooks fire.
///
/// What agy has no hook for is a blocked permission prompt and an interrupted turn; both only
/// surface in the CLI log, so `--log-file` points at the per-session path the supervisor tails
/// (a user's own `--log-file` wins — theirs is where they're looking, and agy keeps only one).
///
/// `agent-start` is the shim's to report, as with opencode: agy's first hook fires at the first
/// turn, which may be minutes after the TUI is up and ready for text.
func runAgyLaunch(binary: String, agentID: String, userArgs: [String]) -> Never {
    guard let real = resolveAgentBinary(binary) else {
        FileHandle.standardError.write(Data("synth: \(binary) not found\n".utf8))
        exit(127)
    }
    let leading = aliasArgs(binary)

    // Only the interactive TUI is a session. Note `agy version` is not a subcommand — it opens
    // the TTY like a session would — so only `--version` passes through.
    let subcommands: Set<String> = ["agent", "agents", "changelog", "help", "install", "models",
                                    "plugin", "plugins", "update"]
    // `--prompt-interactive`/`-i` is a session; only bare print mode is the one-shot.
    let isOneShot = hasFlag(userArgs, ["-p", "--print", "--prompt", "--version", "-h", "--help"])
    let isSubcommand = userArgs.first.map { subcommands.contains($0) } ?? false
    let instrument = env["SYNTH_SESSION_ID"] != nil && !isOneShot && !isSubcommand

    guard instrument else { execReal(real, withLeading(leading, userArgs)) }

    // A resume (`agy --conversation <id>`) needs no special case: the hooks ride the added dir,
    // not the conversation, so the same injection instruments both.
    var injected = writeAgyWorkspace(agentID: agentID).map { ["--add-dir", $0] } ?? []
    if let log = env["SYNTH_ANTIGRAVITY_LOG"], !log.isEmpty, !hasFlag(userArgs, ["--log-file"]) {
        injected += ["--log-file", log]
    }
    reportAgent("agent-start:\(agentID)")
    spawnReportingExit(real, injected + withLeading(leading, userArgs), agent: agentID)
}

/// Materialise the Synth-owned workspace dir agy is handed via `--add-dir`: `.agents/hooks.json`
/// wired back to this binary's event role, and `.agents/mcp_config.json` registering the bundled
/// servers. Returns the dir, or nil when the hooks can't be written — an uninstrumented session
/// (no status, but running) beats no session.
///
/// agy has no `--mcp-config`, and its own docs name only a global and a per-plugin config, both
/// machine-wide. An added dir is the third place: measured on agy 1.1.9, a server declared in an
/// added dir's `.agents/mcp_config.json` is spawned and its tools listed, with the dir nowhere
/// near the cwd. That is what keeps agy's registration out of the user's worktree, the same way
/// its hooks already stay out.
func writeAgyWorkspace(agentID: String) -> String? {
    let session = env["SYNTH_SESSION_ID"] ?? String(getpid())
    let dir = env["SYNTH_ANTIGRAVITY_HOOKS_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        ?? NSTemporaryDirectory() + "synth-agy-" + session
    let bin = env["SYNTH_HOOK_BIN"] ?? CommandLine.arguments[0]
    let q = shellQuote(bin)
    // Every top-level key is a *named* hook whose events merge with any other config's, so ours
    // adds to the user's rather than replacing them. The two event families take different
    // shapes: tool events wrap their handlers in a `matcher` group, lifecycle events list
    // handlers flat. The matcher is `*` because both jobs need every tool — reading the one
    // tool name that means the agent has stopped for a human (`ask_question`), and re-asserting
    // `working` on all the rest.
    //
    // All five of agy's events are wired. `PostInvocation` earns its place as the only reliable
    // end of a *blocked* step: a tool the user approves at the permission prompt need not
    // produce a `PostToolUse` at all (agy defers long-running commands to a later status step),
    // so without it a `needsInput` the log tail set could stand until the turn ends.
    func handler(_ event: String) -> [String: Any] {
        ["type": "command", "command": "\(q) event agy:\(event) \(shellQuote(agentID))", "timeout": 20]
    }
    func matchingAnyTool(_ event: String) -> [String: Any] {
        ["matcher": "*", "hooks": [handler(event)]]
    }
    let config: [String: Any] = ["synth": [
        "PreInvocation":  [handler("PreInvocation")],
        "PostInvocation": [handler("PostInvocation")],
        "PreToolUse":     [matchingAnyTool("PreToolUse")],
        "PostToolUse":    [matchingAnyTool("PostToolUse")],
        "Stop":           [handler("Stop")],
    ]]
    guard let data = try? JSONSerialization.data(withJSONObject: config) else { return nil }
    let agents = dir + "/.agents"
    guard (try? FileManager.default.createDirectory(atPath: agents, withIntermediateDirectories: true)) != nil,
          FileManager.default.createFile(atPath: agents + "/hooks.json", contents: data) else { return nil }
    if let mcp = env["SYNTH_MCP_AGY"], !mcp.isEmpty {
        FileManager.default.createFile(atPath: agents + "/mcp_config.json", contents: Data(mcp.utf8))
    }
    return dir
}

/// True when any of `names` appears in `args`, as the bare flag or in `--flag=value` form.
func hasFlag(_ args: [String], _ names: [String]) -> Bool {
    args.contains { arg in names.contains { arg == $0 || arg.hasPrefix($0 + "=") } }
}

/// The `AgentID.rawValue`s the app persists and the shim reports. Duplicated (not shared) because
/// synth-hook is a standalone Foundation-only executable that must not link the app target.
enum AgentIDRaw {
    static let claudeCode = "claudeCode"
    static let opencode = "opencode"
    static let antigravity = "antigravity"
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
func buildSettingsJSON(userSettings: String?, agentID: String) -> String {
    let bin = env["SYNTH_HOOK_BIN"] ?? CommandLine.arguments[0]
    let q = shellQuote(bin)
    // Every hook command carries the agent's id: the event role runs as its own later process, so
    // this argv is the only thing that can tell it which row's agent it is reporting for. Without
    // it a user's own `claude-personal` would announce itself as the built-in Claude Code.
    let a = shellQuote(agentID)
    func hook(_ event: String, timeout: Int? = nil) -> [String: Any] {
        var h: [String: Any] = ["type": "command", "command": "\(q) event \(event) \(a)"]
        if let timeout { h["timeout"] = timeout }
        return ["hooks": [h]]
    }
    // A `*`-matched tool hook (any tool), for the post-execution "back to working" signals.
    func toolHook(_ event: String) -> [String: Any] {
        ["matcher": "*", "hooks": [["type": "command", "command": "\(q) event \(event) \(a)"]]]
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
                        "hooks": [["type": "command", "command": "\(q) event PreToolUse \(a)"]]]],
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

/// An inline JSON object, and nothing else — `OPENCODE_CONFIG_CONTENT` is content, never a path.
func parseJSONObject(_ value: String) -> [String: Any]? {
    (try? JSONSerialization.jsonObject(with: Data(value.utf8))) as? [String: Any]
}

/// A user `--settings` value is either an inline JSON object or a path to one.
func parseSettings(_ value: String) -> [String: Any]? {
    if let obj = parseJSONObject(value) { return obj }
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

func runEvent(name: String, agentID: String?) -> Never {
    guard let sessionID = env["SYNTH_SESSION_ID"], let socketPath = env["SYNTH_SOCKET_PATH"] else { exit(0) }
    let stdin = FileHandle.standardInput.readDataToEndOfFile()
    let payload = (try? JSONSerialization.jsonObject(with: stdin)) as? [String: Any] ?? [:]
    // An unnamed agent means a hook config written before ids rode along — the event's own family
    // says which built-in it must have been.
    let agent = agentID ?? (name.hasPrefix("agy:") ? AgentIDRaw.antigravity : AgentIDRaw.claudeCode)

    let signal: String?
    switch name {
    case "SessionStart":     signal = "agent-start:\(agent)"
    case "SessionEnd":       signal = "agent-end:\(agent)"
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
    // agy's five hooks, namespaced because it reuses Claude's event names for other meanings.
    // Its PreToolUse is every tool, so it means "working" — except for the one tool that is the
    // opposite of work: `ask_question` stops the loop dead until a human answers it, exactly as
    // Claude's AskUserQuestion does, and it is the only blocked state agy gives a hook for.
    // The matching PostToolUse (which fires when the answer lands) is what clears it.
    case "agy:PreToolUse":
        signal = agyToolName(payload) == "ask_question" ? "needsInput" : "working"
    case "agy:PreInvocation", "agy:PostInvocation", "agy:PostToolUse": signal = "working"
    case "agy:Stop":         signal = agyStopSignal(payload)
    default:
        signal = nil
    }
    // A brand-new conversation (a fresh `startup` or `/clear`) starts with an empty transcript,
    // so `readAITitle` finds nothing and the row would keep the *previous* conversation's title
    // until Claude regenerates one turns later. Tell the app to drop it now. `resume`/`compact`
    // continue the same conversation (and title), so they never reset.
    let resetTitle = name == "SessionStart"
        && ["startup", "clear"].contains(payload["source"] as? String ?? "")

    // The row's auto-name, out of whichever transcript the payload points at. Claude Code writes
    // an `ai-title` line into its own (a short, evolving title it generates); agy generates
    // nothing a hook can reach, so its transcript's opening request stands in.
    let title = (payload["transcript_path"] as? String).flatMap(readAITitle)
        ?? (payload["transcriptPath"] as? String).flatMap(readRequestTitle)

    // The agent's own conversation id (on every hook payload: Claude's `session_id`, agy's
    // `conversationId`, which agy also exports to the hook process) — forwarded so Synth can
    // resume the conversation after a restart with `claude --resume <id>` / `agy --conversation
    // <id>`.
    let agentSession = ["session_id", "conversationId"]
        .compactMap { payload[$0] as? String }
        .first { !$0.isEmpty } ?? env["ANTIGRAVITY_CONVERSATION_ID"].flatMap { $0.isEmpty ? nil : $0 }

    var lines = ""
    if let signal { lines += jsonLine(["session": sessionID, "signal": signal]) }
    if resetTitle { lines += jsonLine(["session": sessionID, "titleReset": "1"]) }
    if let title  { lines += jsonLine(["session": sessionID, "title": title]) }
    if let agentSession { lines += jsonLine(["session": sessionID, "agentSession": agentSession]) }
    if !lines.isEmpty { sendLines(socketPath: socketPath, lines) }
    // Say nothing on stdout, ever. agy reads a PreToolUse handler's stdout as a verdict whose
    // `decision` is required — even `{}` reads as an unknown decision and hard-denies the tool
    // ("tool call denied by pre-tool hook"). Silence is the only "no opinion" both agents share.
    exit(0)   // never block the agent — we only observe
}

/// The tool an agy `PreToolUse` / `PostToolUse` payload is about, or nil for the steps that
/// carry no tool call (a user message, a deferred command's status).
func agyToolName(_ payload: [String: Any]) -> String? {
    (payload["toolCall"] as? [String: Any])?["name"] as? String
}

/// How an agy execution loop ended. Its `Stop` fires for every ending, successful or not, and
/// `terminationReason` is the only place the difference is recorded — so unlike Claude, which
/// splits the two across `Stop` and `StopFailure`, the payload has to be read.
///
/// A cancel is idle, not error: `USER_CANCELED` is agy's spelling of the interrupt Claude reports
/// as 130/143 and opencode as `MessageAbortedError`, and a row the user stopped themselves must
/// never wear red. A cap, though, is a turn that did not finish — reporting that as a clean idle
/// would tell the user their work is done when the agent gave up.
func agyStopSignal(_ payload: [String: Any]) -> String {
    if let error = payload["error"] as? String, !error.isEmpty { return "error" }
    let reason = (payload["terminationReason"] as? String ?? "")
        .replacingOccurrences(of: "EXECUTOR_TERMINATION_REASON_", with: "")
    let failures: Set<String> = ["ERROR", "MAX_INVOCATIONS", "MAX_FORCED_INVOCATIONS",
                                 "MAX_TOKEN_BUDGET_EXCEEDED"]
    return failures.contains(reason) ? "error" : "idle"
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

/// The request that opened an agy conversation, shaped into a row name.
///
/// agy titles its conversations too, but only into a protobuf blob inside a SQLite file no hook
/// can cheaply read, so the transcript's first step is the honest source: the user's own words,
/// wrapped by agy in `<USER_REQUEST>` with the metadata it appends around them. It is the *first*
/// request, not the latest, so the name a row settles on is the one it keeps — including across a
/// `--conversation` resume, which reopens this same transcript.
func readRequestTitle(_ path: String) -> String? {
    guard let data = FileManager.default.contents(atPath: path),
          let text = String(data: data, encoding: .utf8) else { return nil }
    for line in text.split(separator: "\n") where line.contains("<USER_REQUEST>") {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let content = obj["content"] as? String,
              let open = content.range(of: "<USER_REQUEST>"),
              let close = content.range(of: "</USER_REQUEST>", range: open.upperBound..<content.endIndex)
        else { continue }
        return rowTitle(fromCommand: String(content[open.upperBound..<close.lowerBound]))
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
