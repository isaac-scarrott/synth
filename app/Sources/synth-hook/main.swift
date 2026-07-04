import Foundation
#if canImport(Glibc)
import Glibc
#endif

// synth-hook — the bridge between a Claude Code process and the Synth app.
//
// Two roles, dispatched by how it's invoked:
//   • as `claude` (a symlink Synth puts first on PATH): the LAUNCH role. Claude Code
//     has no way to know it's inside Synth, so we intercept the `claude` command,
//     inject our hook config (`--settings`) + a fresh `--session-id`, and exec the
//     real binary. Non-interactive invocations (`claude -p`, subcommands) pass through.
//   • as `synth-hook event <Event>`: the EVENT role. Claude fires this per hook; we read
//     the event JSON on stdin, classify it to a status signal, and write one line to the
//     app's unix socket (path in $SYNTH_SOCKET_PATH), tagged with $SYNTH_SESSION_ID.
//
// Correlation is entirely by env: Synth spawns the PTY with SYNTH_SESSION_ID (the row),
// SYNTH_SOCKET_PATH, SYNTH_HOOK_BIN and SYNTH_REAL_CLAUDE; Claude and its hooks inherit them.

let env = ProcessInfo.processInfo.environment
let invokedName = (CommandLine.arguments[0] as NSString).lastPathComponent

if invokedName == "claude" {
    runLaunch(userArgs: Array(CommandLine.arguments.dropFirst()))
} else {
    let sub = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ""
    switch sub {
    case "launch":
        // `synth-hook launch -- <args>` (explicit form, in case PATH-shim isn't used)
        let after = CommandLine.arguments.firstIndex(of: "--").map { Array(CommandLine.arguments[($0 + 1)...]) } ?? []
        runLaunch(userArgs: after)
    case "event":
        runEvent(name: CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "")
    default:
        FileHandle.standardError.write(Data("synth-hook: unknown invocation\n".utf8))
        exit(2)
    }
}

// MARK: - Launch role

func runLaunch(userArgs: [String]) -> Never {
    let real = env["SYNTH_REAL_CLAUDE"].flatMap { $0.isEmpty ? nil : $0 } ?? resolveRealClaude()
    guard let real else {
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
    execReal(real, ["--session-id", UUID().uuidString, "--settings", settings] + args)
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

/// Fallback claude lookup when SYNTH_REAL_CLAUDE is unset — scan PATH, skipping our shim dir.
func resolveRealClaude() -> String? {
    let shim = env["SYNTH_SHIM_DIR"]
    for dir in (env["PATH"] ?? "").split(separator: ":").map(String.init) {
        if dir == shim { continue }
        let candidate = dir + "/claude"
        if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
    }
    return nil
}

// MARK: - Event role

func runEvent(name: String) -> Never {
    guard let sessionID = env["SYNTH_SESSION_ID"], let socketPath = env["SYNTH_SOCKET_PATH"] else { exit(0) }
    let stdin = FileHandle.standardInput.readDataToEndOfFile()
    let payload = (try? JSONSerialization.jsonObject(with: stdin)) as? [String: Any] ?? [:]

    let signal: String?
    switch name {
    case "SessionStart":     signal = "claude-start"
    case "SessionEnd":       signal = "claude-end"
    case "UserPromptSubmit": signal = "working"
    case "Stop":             signal = "idle"
    case "StopFailure":      signal = "error"
    case "PermissionRequest", "PreToolUse":
        signal = "needsInput"
    case "Notification":
        let type = payload["notification_type"] as? String ?? ""
        signal = ["permission_prompt", "idle_prompt", "agent_needs_input"].contains(type) ? "needsInput" : nil
    default:
        signal = nil
    }
    // Claude Code writes an `ai-title` line into the transcript (a short, evolving title it
    // generates) — read the latest and forward it so Synth can auto-name the row.
    let title = (payload["transcript_path"] as? String).flatMap(readAITitle)

    var lines = ""
    if let signal { lines += jsonLine(["session": sessionID, "signal": signal]) }
    if let title  { lines += jsonLine(["session": sessionID, "title": title]) }
    if !lines.isEmpty { sendLines(socketPath: socketPath, lines) }
    exit(0)   // never block Claude — we only observe
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
