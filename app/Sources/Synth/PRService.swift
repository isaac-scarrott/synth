import Foundation

/// A branch's pull-request state, as GitHub sees it. Derived like session status (not
/// persisted): read from `gh` on launch and refreshed on activation, never snapshotted.
enum PRState: String, Sendable {
    case open = "OPEN"
    case merged = "MERGED"
    case closed = "CLOSED"
    /// Not a `gh` state — an open PR sitting in GitHub's merge queue, promoted from `.open`
    /// when the GraphQL `mergeQueueEntry` is present (see `pullRequests`).
    case queued = "QUEUED"

    /// Rank for picking one PR per branch when several share a head ref: a queued PR (already
    /// on its way in) wins over a plain open one, which wins over merged, which wins over closed.
    var precedence: Int {
        switch self {
        case .queued: return 0
        case .open: return 1
        case .merged: return 2
        case .closed: return 3
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
        var best = list(at: repo, ghPath: ghPath)
        // Promote any open PR that's sitting in the merge queue to `.queued`. This is a second,
        // GraphQL read (`mergeQueueEntry`) because `gh pr list` only ever reports OPEN/MERGED/
        // CLOSED — the queue is a sub-state of open. Skipped when there are no PRs to promote,
        // and degrades to "nothing queued" on any error (repo without a merge queue, older gh).
        guard let sample = best.values.first else { return best }
        let queued = mergeQueued(at: repo, ghPath: ghPath, sample: sample)
        for (branch, pr) in best where pr.state == .open && queued.contains(pr.number) {
            best[branch] = PRInfo(number: pr.number, state: .queued, url: pr.url)
        }
        return best
    }

    /// The raw `gh pr list` read — one PR per head branch (strongest, then most recent),
    /// before any merge-queue promotion.
    private static func list(at repo: URL, ghPath: String) -> [String: PRInfo] {
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

    /// Numbers of the repo's open PRs that are currently in the merge queue, via GraphQL
    /// (`pullRequests.mergeQueueEntry`). Owner/name are lifted from a PR url we already hold,
    /// so no extra `repo view`. Empty on any failure — merge queue absent, field unavailable,
    /// or the CLI unauthenticated — matching the rest of the service's fail-quiet contract.
    private static func mergeQueued(at repo: URL, ghPath: String, sample: PRInfo) -> Set<Int> {
        guard let url = URL(string: sample.url), url.pathComponents.count >= 3 else { return [] }
        let owner = url.pathComponents[1]
        let name = url.pathComponents[2]
        let query = "query($owner:String!,$name:String!){repository(owner:$owner,name:$name)"
            + "{pullRequests(states:OPEN,first:100){nodes{number mergeQueueEntry{position}}}}}"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ghPath)
        process.arguments = ["api", "graphql", "-f", "query=\(query)",
                             "-F", "owner=\(owner)", "-F", "name=\(name)"]
        process.currentDirectoryURL = repo
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return [] }
            return parseQueued(data)
        } catch {
            return []
        }
    }

    /// PR numbers whose `mergeQueueEntry` came back non-null.
    private static func parseQueued(_ data: Data) -> Set<Int> {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObj = root["data"] as? [String: Any],
              let repo = dataObj["repository"] as? [String: Any],
              let prs = repo["pullRequests"] as? [String: Any],
              let nodes = prs["nodes"] as? [[String: Any]]
        else { return [] }
        var out: Set<Int> = []
        for node in nodes where node["mergeQueueEntry"] is [String: Any] {
            if let number = node["number"] as? Int { out.insert(number) }
        }
        return out
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
