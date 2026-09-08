import Foundation

/// The last N `(domain/code)` pairs, in order — the breadcrumb trail that turns a bare
/// "surface_new_failed" into a sentence. Two readers want it and they have opposite
/// constraints, which is why it is a ring in memory *and* a fixed-size file:
///
///   • `Analytics.fault` attaches the recent slugs to every fault event, so a report says
///     what led to it rather than only what ended it;
///   • `CrashReporter.reportPending` reads the FILE on the next launch, so a crash that
///     unwound the process before any send could finish still arrives with its run-up.
///
/// The file is a flat array of fixed-width slots written with one `pwrite` per breadcrumb —
/// no allocation, no seek, no truncate — so the last write before a `SIGSEGV` has already
/// landed. Only closed-vocabulary slugs are ever written, so the trail is wire-safe by the
/// same rule as `Fault.Detail`: there is no way to put a path or a message into it.
final class FaultTrail: @unchecked Sendable {
    /// One slot per breadcrumb, NUL-padded. 63 characters is comfortably longer than the
    /// longest `domain/code` pair and keeps the arithmetic obvious.
    private static let slotSize = 64
    private let capacity: Int
    private let lock = NSLock()
    private var slugs: [String]
    private var next = 0
    private var wrapped = false
    /// Opened once, kept for the life of the process. -1 when the trail could not be opened,
    /// which costs the crash half and nothing else — the in-memory ring still works.
    private let fd: Int32

    init(capacity: Int, url: URL?) {
        self.capacity = capacity
        self.slugs = []
        self.slugs.reserveCapacity(capacity)
        guard let url else { fd = -1; return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        let opened = url.path.withCString { open($0, O_WRONLY | O_CREAT | O_TRUNC, 0o644) }
        if opened >= 0 { ftruncate(opened, off_t(capacity * Self.slotSize)) }
        fd = opened
    }

    func append(_ slug: String) {
        lock.lock()
        let slot = next
        next = (next + 1) % capacity
        if next == 0 { wrapped = true }
        if slugs.count < capacity { slugs.append(slug) } else { slugs[slot] = slug }
        lock.unlock()
        guard fd >= 0 else { return }
        var buf = [UInt8](repeating: 0, count: Self.slotSize)
        for (i, b) in slug.utf8.prefix(Self.slotSize - 1).enumerated() { buf[i] = b }
        buf.withUnsafeBufferPointer {
            _ = pwrite(fd, $0.baseAddress, Self.slotSize, off_t(slot * Self.slotSize))
        }
    }

    /// The most recent `limit` slugs, oldest first — the order you read a run-up in.
    func recent(_ limit: Int) -> [String] {
        lock.lock(); defer { lock.unlock() }
        guard !slugs.isEmpty else { return [] }
        let ordered = wrapped ? Array(slugs[next...] + slugs[..<next]) : slugs
        return Array(ordered.suffix(limit))
    }

    /// The previous run's trail, read from disk. Slot order is unknown after a wrap — the
    /// file carries no write counter — so this returns the set of slugs the run touched,
    /// which is what a crash report needs: "these are the failures that preceded it".
    static func previousRun(_ url: URL) -> [String] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return stride(from: 0, to: data.count, by: slotSize).compactMap { off in
            let slot = data[off..<min(off + slotSize, data.count)]
            let text = String(decoding: slot.prefix { $0 != 0 }, as: UTF8.self)
            return text.isEmpty ? nil : text
        }
    }
}
