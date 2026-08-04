import Foundation
import Observation

/// Bytes on disk under a folder. The archive is the only surface that asks: "still on disk" is
/// a claim about disk, and a list of folders that never says what they cost is asking the user
/// to take the sweeper's word for it.
enum FolderSize {
    /// Blocking. Walks the whole tree. Never call this from the main actor — `FolderSizeCache`
    /// exists so nothing has to.
    ///
    /// `node_modules` is walked like everything else. It is usually most of the bytes, and a
    /// disk-usage number that skips the biggest directory is not a disk-usage number — the
    /// nested-repo scan skips it because it is looking for a `.git`, which is a different
    /// question.
    static func bytes(of url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        let fm = FileManager.default
        // No `.skipsHiddenFiles`: `.git` and a worktree's `.env` are real bytes. An error
        // handler that keeps going, because one unreadable directory is a short count, not a
        // failed measurement.
        guard let walk = fm.enumerator(at: url, includingPropertiesForKeys: keys,
                                       options: [], errorHandler: { _, _ in true })
        else { return 0 }
        var total = allocated(url, keys: keys)
        for case let entry as URL in walk { total += allocated(entry, keys: keys) }
        return total
    }

    /// Allocated, not logical: `du`'s number, and the one that answers "what would deleting
    /// this give back". `totalFileAllocatedSizeKey` covers a file's metadata and any resource
    /// fork; `fileAllocatedSizeKey` is the fallback for the volumes that don't report it.
    private static func allocated(_ url: URL, keys: [URLResourceKey]) -> Int64 {
        guard let v = try? url.resourceValues(forKeys: Set(keys)) else { return 0 }
        return Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
    }

    /// working.html's `fmtSize`. One decimal past a gigabyte, whole megabytes under it — a
    /// worktree is never interesting to the tenth of a megabyte.
    static func format(_ bytes: Int64) -> String {
        let mb = Double(bytes) / 1_048_576
        if mb >= 1024 { return String(format: "%.1f GB", mb / 1024) }
        return "\(Int(mb.rounded())) MB"
    }
}

/// Measured folder sizes, per URL. The pane reads it during layout and must never block; the
/// walk happens off the main actor and lands here, and `@Observable` re-renders the row when
/// it does.
///
/// Nothing is ever re-measured. An archived worktree is a folder nobody is working in — that
/// is what archived means — so a second walk would spend a multi-GB tree's worth of stats to
/// confirm the first one.
@MainActor @Observable final class FolderSizeCache {
    static let shared = FolderSizeCache()

    private var sizes: [URL: Int64] = [:]
    /// Not observed: a walk starting is not a fact any view renders, and publishing it would
    /// invalidate the pane twice per measurement.
    @ObservationIgnored private var inFlight: Set<URL> = []

    /// nil = not measured yet. Callers show nothing rather than a zero — an unmeasured folder
    /// claiming 0 MB is worse than a folder claiming nothing.
    func bytes(for url: URL) -> Int64? { sizes[url] }

    /// Measure anything not already measured or in flight. Called from a SwiftUI body on every
    /// re-render, so the dedupe is the whole point: without it a scrolling list would spawn a
    /// fresh walk of every archived worktree per frame.
    func warm(_ urls: [URL]) {
        for url in urls where sizes[url] == nil && !inFlight.contains(url) {
            inFlight.insert(url)
            Task.detached(priority: .utility) {
                let measured = FolderSize.bytes(of: url)
                await MainActor.run {
                    self.sizes[url] = measured
                    self.inFlight.remove(url)
                }
            }
        }
    }
}
