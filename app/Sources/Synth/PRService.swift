import Foundation

/// A branch's pull-request state, as GitHub sees it. Derived like session status (not
/// persisted): read from GitHub on launch and refreshed on activation, never snapshotted.
enum PRState: String, Sendable {
    case open = "OPEN"
    case merged = "MERGED"
    case closed = "CLOSED"
    /// Not a state the API reports directly — an open PR sitting in GitHub's merge queue,
    /// promoted from `.open` when the query's own `mergeQueueEntry` field is present.
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
    /// The branch this PR merges *into*. The sweeper needs it to catch commits made after a
    /// merge — GitHub still reports MERGED while the local tip has moved past the merge commit.
    var baseRefName: String = ""
    /// A draft reads OPEN today, so nothing depends on this yet. It's here so that the next
    /// person to simplify the state check can't accidentally make drafts sweepable.
    var isDraft: Bool = false
    /// Login of the account owning the head repo. A cross-fork PR merges the *fork's* branch;
    /// a same-named local branch is a different thing and must not inherit its merged state.
    var headRepositoryOwner: String = ""
}

/// Reads pull requests straight from GitHub's GraphQL API — no `gh` binary. Auth comes from
/// whatever git itself already has on file (`GitService.credential`, so osxkeychain/Git
/// Credential Manager/`gh`'s own credential helper if that's what's configured) or
/// `GH_TOKEN`/`GITHUB_TOKEN`; Synth never manages a token of its own. A repo whose `origin`
/// isn't `github.com`, or with nothing to authenticate with, both resolve to "no PRs" rather
/// than an error — matching `gh` itself, which also refuses to answer unauthenticated.
///
/// Every read is scoped to one named branch via GraphQL's `headRefName` filter — never a
/// repo-wide "list everything" call, which silently truncates on a busy repo (a page cap
/// pushes an older branch's PR off the tail, and that reads exactly like "this branch has no
/// PR"). This also has to be GraphQL and not REST's `pulls?head=owner:branch` filter: that
/// filter's `owner` must name the *head* repo's owner, which for a PR opened from a fork is
/// the fork owner, not this repo's — information Synth doesn't have going in, since finding
/// it out is the point of the call. `headRefName` takes a bare branch name and searches
/// correctly regardless of which fork it lives in (confirmed against `gh`'s own query, which
/// hits this same field).
enum PRService {
    /// The PR for whatever branch is actually checked out at `worktree` right now — asks
    /// git what's really there (`checkedOutBranch`) rather than trusting the model, so a
    /// `git checkout` run by hand inside the folder doesn't leave a stale badge. Nil when
    /// detached HEAD, or when nothing could be asked (see `pullRequest(branch:at:)`).
    static func pullRequest(at worktree: URL) -> PRInfo?? {
        pullRequest(at: worktree, token: authToken(at: worktree))
    }

    /// Same as `pullRequest(at:)`, but with the auth token already resolved — what a batch
    /// refresh over many branches uses, so `git credential fill` (a subprocess call, possibly
    /// a Keychain round trip) runs once per repo instead of once per branch.
    static func pullRequest(at worktree: URL, token: String?) -> PRInfo?? {
        guard let branch = GitService.checkedOutBranch(at: worktree) else { return .none }
        return pullRequest(branch: branch, at: worktree, token: token)
    }

    /// One named branch's PR, regardless of what's checked out where — what the sweeper
    /// uses for a worktree that's already gone from disk, keyed by the branch name it last
    /// knew.
    ///
    /// **nil means "couldn't ask"** — no GitHub remote, no credential to authenticate with,
    /// offline, unparseable answer — and is not the same as `.some(nil)`, which means "asked,
    /// and this branch has no PR". Display can treat both as "no badge"; nothing that
    /// *deletes* anything may.
    static func pullRequest(branch: String, at repo: URL) -> PRInfo?? {
        pullRequest(branch: branch, at: repo, token: authToken(at: repo))
    }

    /// Same as `pullRequest(branch:at:)`, but with the auth token already resolved (see
    /// `pullRequest(at:token:)`). GraphQL answers nothing unauthenticated, so no token means
    /// "couldn't ask" outright — there is no unauthenticated fallback to try.
    static func pullRequest(branch: String, at repo: URL, token: String?) -> PRInfo?? {
        guard let (owner, name) = githubOwnerRepo(at: repo), let token else { return .none }
        guard let data = query(owner: owner, name: name, branch: branch, token: token),
              let candidates = parseNodes(data)
        else { return .none }
        guard let best = strongest(candidates) else { return .some(nil) }
        return .some(best)
    }

    /// `owner/name`, when `origin` is a `github.com` remote (https, ssh, or `git@` scp-style)
    /// — nil for any other host, or no `origin` at all.
    private static func githubOwnerRepo(at repo: URL) -> (owner: String, name: String)? {
        guard let raw = GitService.remoteURL("origin", at: repo) else { return nil }
        var rest: String?
        if raw.hasPrefix("git@github.com:") {
            rest = String(raw.dropFirst("git@github.com:".count))
        } else if let url = URL(string: raw), url.host?.lowercased() == "github.com" {
            rest = url.path
        }
        guard var path = rest else { return nil }
        if path.hasPrefix("/") { path.removeFirst() }
        if path.hasSuffix(".git") { path.removeLast(4) }
        let parts = path.split(separator: "/")
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return (String(parts[0]), String(parts[1]))
    }

    /// A token to authenticate with. Exposed (not `private`) so a batch caller (Store) can
    /// resolve this once per repo and pass it to every branch's call, rather than each
    /// branch re-spawning `git credential fill`.
    static func authToken(at repo: URL) -> String? {
        let env = ProcessInfo.processInfo.environment
        if let t = env["GH_TOKEN"], !t.isEmpty { return t }
        if let t = env["GITHUB_TOKEN"], !t.isEmpty { return t }
        if let t = GitService.credential(protocol: "https", host: "github.com")?.password { return t }
        return ghAuthToken()
    }

    /// Last-resort fallback, tried only when nothing else answered: `gh auth token`, if `gh`
    /// happens to be installed and signed in. Not a dependency — every path above works with
    /// `gh` completely absent — but a real gap without it: someone who ran `gh auth login`
    /// and chose SSH as their git protocol has no reason to ever have an HTTPS credential
    /// cached for github.com, so `GitService.credential` alone leaves them with no PR badges
    /// at all despite being fully authenticated. `gh auth token` is a local keyring read
    /// (no network), so this costs nothing when `gh` isn't there and one fast subprocess
    /// when it is.
    private static func ghAuthToken() -> String? {
        let home = NSHomeDirectory()
        let pathDirs = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map(String.init)
        let hints = ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin"]
        guard let ghPath = (pathDirs + hints).map({ "\($0)/gh" })
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ghPath)
        process.arguments = ["auth", "token"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (token?.isEmpty == false) ? token : nil
        } catch {
            return nil
        }
    }

    /// Every PR (any state) whose head ref is exactly `branch`, newest first, with the
    /// merge-queue field already inline — one request in, no separate merge-queue round
    /// trip. 20, not fewer: a branch reopened a few times has one PR per reopen, all sharing
    /// this head name, and `strongest` needs every candidate in the page to pick correctly.
    private static func query(owner: String, name: String, branch: String, token: String) -> Data? {
        guard let url = URL(string: "https://api.github.com/graphql") else { return nil }
        let text = """
        query($owner:String!,$name:String!,$head:String!){\
        repository(owner:$owner,name:$name){\
        pullRequests(headRefName:$head,states:[OPEN,CLOSED,MERGED],first:20,\
        orderBy:{field:CREATED_AT,direction:DESC}){nodes{\
        number state url isDraft baseRefName headRepositoryOwner{login} \
        mergeQueueEntry{position}}}}}
        """
        let payload: [String: Any] = [
            "query": text,
            "variables": ["owner": owner, "name": name, "head": branch]
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return perform(request)
    }

    /// Blocking request/response, matching the rest of the codebase's convention of doing
    /// I/O synchronously and leaving callers to dispatch it off the main thread (GitService's
    /// `Process` calls do the same). A short timeout plus a non-2xx check stand in for the
    /// exit-code check on a subprocess.
    private static func perform(_ request: URLRequest) -> Data? {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Data?
        var status: Int?
        let task = URLSession.shared.dataTask(with: request) { data, response, _ in
            status = (response as? HTTPURLResponse)?.statusCode
            result = data
            semaphore.signal()
        }
        task.resume()
        semaphore.wait()
        guard let status, (200..<300).contains(status) else { return nil }
        return result
    }

    /// Fold a branch's PR list down to the one worth showing: the strongest state, then the
    /// most recent when a branch was reopened and so has several.
    private static func strongest(_ prs: [PRInfo]) -> PRInfo? {
        var best: PRInfo?
        for pr in prs {
            guard let existing = best else { best = pr; continue }
            let stronger = pr.state.precedence < existing.state.precedence
                || (pr.state.precedence == existing.state.precedence && pr.number > existing.number)
            if stronger { best = pr }
        }
        return best
    }

    /// The GraphQL response's `data.repository.pullRequests.nodes` into `PRInfo`s. GraphQL's
    /// `PullRequestState` enum is OPEN/CLOSED/MERGED directly — no REST-style `merged_at`
    /// timestamp heuristic needed, and its raw strings already match `PRState`'s.
    private static func parseNodes(_ data: Data) -> [PRInfo]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let d = root["data"] as? [String: Any],
              let repository = d["repository"] as? [String: Any],
              let prs = repository["pullRequests"] as? [String: Any],
              let nodes = prs["nodes"] as? [[String: Any]]
        else { return nil }
        return nodes.compactMap { node in
            guard let number = node["number"] as? Int,
                  let stateRaw = node["state"] as? String,
                  var state = PRState(rawValue: stateRaw),
                  let url = node["url"] as? String
            else { return nil }
            if state == .open, node["mergeQueueEntry"] is [String: Any] { state = .queued }
            let owner = (node["headRepositoryOwner"] as? [String: Any])?["login"] as? String ?? ""
            return PRInfo(number: number, state: state, url: url,
                          baseRefName: node["baseRefName"] as? String ?? "",
                          isDraft: node["isDraft"] as? Bool ?? false, headRepositoryOwner: owner)
        }
    }
}
