import Foundation

/// Reads real data from a git repository. No mock data — everything the tree shows
/// about branches comes from here.
enum GitService {
    struct BranchInfo {
        let name: String
        let lastCommitUnix: TimeInterval
    }

    /// Local branches (refs/heads), most-recently-committed first. Empty if the path
    /// isn't a git repository.
    static func branches(at url: URL) -> [BranchInfo] {
        guard isRepository(url) else { return [] }
        let out = run(["-C", url.path, "for-each-ref",
                       "--sort=-committerdate",
                       "--format=%(refname:short)\t%(committerdate:unix)",
                       "refs/heads"])
        return out.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2, let unix = TimeInterval(parts[1]) else { return nil }
            return BranchInfo(name: String(parts[0]), lastCommitUnix: unix)
        }
    }

    static func isRepository(_ url: URL) -> Bool {
        run(["-C", url.path, "rev-parse", "--is-inside-work-tree"]).trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    }

    /// Compact relative age, matching the mock's "2h" / "5d" style.
    static func compactAge(_ unix: TimeInterval) -> String {
        let secs = max(0, Date().timeIntervalSince1970 - unix)
        switch secs {
        case ..<60:        return "now"
        case ..<3_600:     return "\(Int(secs / 60))m"
        case ..<86_400:    return "\(Int(secs / 3_600))h"
        case ..<604_800:   return "\(Int(secs / 86_400))d"
        case ..<2_592_000: return "\(Int(secs / 604_800))w"
        default:           return "\(Int(secs / 2_592_000))mo"
        }
    }

    private static func run(_ args: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }
}
