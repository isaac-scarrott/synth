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
    /// The branch this PR merges *into* — what the hover card's diffstat measures against.
    var baseRefName: String = ""
    /// A draft reads OPEN today, so nothing depends on this yet. It's here so that the next
    /// person to simplify the state check can't accidentally make drafts read as finished.
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
/// Every lookup is scoped to one named branch via GraphQL's `headRefName` filter — never a
/// repo-wide "list everything" call, which silently truncates on a busy repo (a page cap
/// pushes an older branch's PR off the tail, and that reads exactly like "this branch has no
/// PR"). This also has to be GraphQL and not REST's `pulls?head=owner:branch` filter: that
/// filter's `owner` must name the *head* repo's owner, which for a PR opened from a fork is
/// the fork owner, not this repo's — information Synth doesn't have going in, since finding
/// it out is the point of the call. `headRefName` takes a bare branch name and searches
/// correctly regardless of which fork it lives in (confirmed against `gh`'s own query, which
/// hits this same field).
enum PRService {
    /// One branch row to ask about: the name the model last recorded, and its folder.
    struct Row: Sendable {
        let id: UUID
        let name: String
        let worktree: URL
    }

    /// Every row's PR, read in one pass over the repo. What is the same for every row is asked
    /// once: `origin` (one `remote get-url`), the credential (one `git credential fill`, possibly
    /// a Keychain round trip) and what each folder really has checked out (one `worktree list`
    /// — asking git rather than trusting the model, so a `git checkout` run by hand inside a
    /// folder doesn't leave a stale badge). A row with no folder on disk yet (mid-create, or
    /// re-cut on restore) is asked by the name it last knew. The branches then go to GitHub `pageSize` to a request.
    ///
    /// **A row missing from the answer means "couldn't ask"** — no GitHub remote, no
    /// credential to authenticate with (GraphQL answers nothing unauthenticated), detached
    /// HEAD, offline, unparseable answer — and is not the same as a nil value, which means
    /// "asked, and this branch has no PR". Display can treat both as "no badge".
    static func pullRequests(for rows: [Row], in repo: URL) -> [UUID: PRInfo?] {
        guard let (owner, name) = githubOwnerRepo(at: repo), let token = authToken() else { return [:] }
        let checkedOut = GitService.checkedOutBranches(at: repo)
        var heads: [UUID: String] = [:]
        for row in rows {
            heads[row.id] = FileManager.default.fileExists(atPath: row.worktree.path)
                ? checkedOut[row.worktree.resolvingSymlinksInPath().path]
                : row.name
        }
        let branches = Array(Set(heads.values))
        var answers: [String: PRInfo?] = [:]
        for start in stride(from: 0, to: branches.count, by: pageSize) {
            let page = Array(branches[start..<min(start + pageSize, branches.count)])
            guard let data = query(owner: owner, name: name, branches: page, token: token) else { continue }
            for (i, candidates) in parsePage(data, count: page.count) {
                answers[page[i]] = strongest(candidates)
            }
        }
        return heads.compactMapValues { answers[$0] }
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

    private static func authToken() -> String? {
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

    /// Branches per request. GitHub bills a query by the connections it asks for, a point per
    /// hundred, so a page of 100 aliased lookups costs what one lookup alone does.
    private static let pageSize = 100

    /// For each branch in the page, every PR (any state) whose head ref is exactly that
    /// branch, newest first, with the merge-queue field already inline — aliased `b0`, `b1`, …
    /// in one request, no separate merge-queue round trip. 20, not fewer: a branch reopened a
    /// few times has one PR per reopen, all sharing this head name, and `strongest` needs
    /// every candidate in the page to pick correctly.
    private static func query(owner: String, name: String, branches: [String], token: String) -> Data? {
        guard let url = URL(string: "https://api.github.com/graphql") else { return nil }
        let params = branches.indices.map { ",$h\($0):String!" }.joined()
        let lookups = branches.indices.map { i in
            "b\(i):pullRequests(headRefName:$h\(i),states:[OPEN,CLOSED,MERGED],first:20,"
                + "orderBy:{field:CREATED_AT,direction:DESC}){nodes{"
                + "number state url isDraft baseRefName headRepositoryOwner{login} "
                + "mergeQueueEntry{position}}}"
        }.joined(separator: " ")
        let text = "query($owner:String!,$name:String!\(params)){"
            + "repository(owner:$owner,name:$name){\(lookups)}}"
        var variables: [String: Any] = ["owner": owner, "name": name]
        for (i, branch) in branches.enumerated() { variables["h\(i)"] = branch }
        let payload: [String: Any] = ["query": text, "variables": variables]
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
        // The transport error is read for its two halves here rather than carried out whole:
        // `Error` is not Sendable, and only its code and its sentence are ever wanted.
        var failureCode: Int?
        var failureText: String?
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            status = (response as? HTTPURLResponse)?.statusCode
            failureCode = (error as? NSError)?.code
            failureText = error?.localizedDescription
            result = data
            semaphore.signal()
        }
        task.resume()
        semaphore.wait()
        // Every arm still answers "couldn't ask" — that contract is what keeps a revoked token
        // from reading as "this branch has no PR". What changes is that a revoked
        // token, an SSO block, a rate limit and being offline stop being the same silence: the
        // status code separates them, and the badges vanishing off every row is now countable.
        guard let status else {
            let why = failureText ?? "No response from GitHub."
            Fault.report(.worktree, .uncaught,
                         details: [.stage(.handshake), .count("url_error", failureCode ?? 0)],
                         evidence: why)
            return nil
        }
        guard (200..<300).contains(status) else {
            Fault.report(.worktree, .uncaught,
                         details: [.stage(.handshake), .count("http_status", status)])
            return nil
        }
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

    /// A page's response, `data.repository.b<i>.nodes`, into each branch's `PRInfo`s keyed by
    /// its index in the page. An alias GitHub didn't answer is absent: that branch couldn't be
    /// asked. GraphQL's `PullRequestState` enum is OPEN/CLOSED/MERGED directly — no REST-style
    /// `merged_at` timestamp heuristic needed, and its raw strings already match `PRState`'s.
    private static func parsePage(_ data: Data, count: Int) -> [Int: [PRInfo]] {
        let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let repository = (root?["data"] as? [String: Any])?["repository"] as? [String: Any]
        var found: [Int: [PRInfo]] = [:]
        for i in 0..<count {
            guard let prs = repository?["b\(i)"] as? [String: Any],
                  let nodes = prs["nodes"] as? [[String: Any]]
            else { continue }
            found[i] = nodes.compactMap(prInfo)
        }
        if found.count < count {
            // A 200 carrying a GraphQL `errors` payload lands here — the shape a scope-less
            // token or a renamed repo takes — and it is otherwise indistinguishable from being
            // offline, because both arrive at the caller as the same "couldn't ask".
            Fault.report(.worktree, .uncaught, details: [.stage(.handshake)],
                         evidence: "GitHub answered 2xx with no pullRequests nodes.")
        }
        return found
    }

    private static func prInfo(_ node: [String: Any]) -> PRInfo? {
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
