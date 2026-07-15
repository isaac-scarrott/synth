import Foundation

/// A branch's pull-request state, as GitHub sees it. Derived like session status (not
/// persisted): read from `gh` on launch and refreshed on activation, never snapshotted.
enum PRState: String, Sendable {
    case open = "OPEN"
    case merged = "MERGED"
    case closed = "CLOSED"

    /// Rank for picking one PR per branch when several share a head ref: a live open PR
    /// wins over a merged one, which wins over a plain closed one.
    var precedence: Int {
        switch self {
        case .open: return 0
        case .merged: return 1
        case .closed: return 2
        }
    }
}

struct PRInfo: Sendable, Equatable {
    let number: Int
    let state: PRState
    let url: String
}

/// Reads pull requests from the GitHub CLI (`gh`). Everything the tree shows about a
/// branch's PR comes from here — no mock data. A repo with no GitHub remote, a missing or
/// unauthenticated `gh`, all resolve to "no PRs" rather than an error.
enum PRService {
    /// Where `gh` really lives, resolved once on the launch PATH (bare under Dock/`open`,
    /// so the common Homebrew locations are searched too, mirroring AgentDescriptor).
    static let ghPath: String? = {
        let home = NSHomeDirectory()
        let pathDirs = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map(String.init)
        let hints = ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin"]
        for dir in pathDirs + hints {
            let candidate = dir + "/gh"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }()

    /// Open, closed and merged PRs for `repo`, keyed by head branch name (`gh`'s
    /// `headRefName`). One entry per branch — the highest-precedence, then most recent PR
    /// when a branch has several. Empty when `gh` is absent, the repo has no GitHub remote,
    /// or the CLI isn't authenticated.
    static func pullRequests(at repo: URL) -> [String: PRInfo] {
        guard let ghPath else { return [:] }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ghPath)
        process.arguments = ["pr", "list", "--state", "all", "--limit", "100",
                             "--json", "number,state,url,headRefName"]
        process.currentDirectoryURL = repo
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()   // swallow "no default remote" / auth chatter
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return [:] }
            return parse(data)
        } catch {
            return [:]
        }
    }

    /// Fold `gh`'s JSON array into one PR per head branch, keeping the strongest.
    private static func parse(_ data: Data) -> [String: PRInfo] {
        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return [:]
        }
        var best: [String: PRInfo] = [:]
        for row in rows {
            guard let branch = row["headRefName"] as? String,
                  let number = row["number"] as? Int,
                  let stateRaw = row["state"] as? String,
                  let state = PRState(rawValue: stateRaw),
                  let url = row["url"] as? String
            else { continue }
            let pr = PRInfo(number: number, state: state, url: url)
            if let existing = best[branch] {
                let stronger = pr.state.precedence < existing.state.precedence
                    || (pr.state.precedence == existing.state.precedence && pr.number > existing.number)
                if stronger { best[branch] = pr }
            } else {
                best[branch] = pr
            }
        }
        return best
    }
}
