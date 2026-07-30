import Darwin
import Foundation
import os

/// Attributes running processes to the Synth session that started them, using the
/// `SYNTH_SESSION_ID` stamp `HookEnvironment.decorate` puts into every PTY's environment.
///
/// Teardown reaps a session's process *group* (`GhosttySurfaceView.reapProcessTree`), which is
/// the right unit for everything a shell runs in the foreground. It is not the right unit for
/// anything that calls `setsid`: Claude Code's Bash tool detaches its background shells, so a
/// dev server an agent starts leaves the group the moment it launches and — once the shell that
/// spawned it exits — reparents to launchd. `killpg` can no longer reach it and no ppid chain
/// leads back to us, so it survives the session, the window, and the app. These accumulate for
/// as long as the machine stays up; measured on a normal day's use, the escaped servers held
/// more than twice the memory of everything still inside the groups.
///
/// The environment stamp survives all three moves — leaving the group, reparenting, and the
/// owning Synth exiting — because it is a property of the process image rather than of any
/// relationship that can be broken.
///
/// Two kinds of process carry no readable stamp, both by the kernel's choice rather than ours.
/// A SIP-protected platform binary (`/bin/sleep`, `/usr/bin/login`) has its environment stripped
/// from `KERN_PROCARGS2` outright, and a process that called `setproctitle` has overwritten the
/// region the environment lived in. The first is unreachable and stays that way; the second is
/// recovered from its nearest stamped ancestor. Neither matters much for what this is for — every
/// dev server worth reclaiming is a user binary (node, python, bun), which reads back fine.
enum SessionProcesses {
    static let log = Logger(subsystem: "io.github.isaac-scarrott.synth", category: "reaper")

    /// What one process claims about its origin. `session` is the row it was started under;
    /// `instance` is the Synth that owns that row, recovered from the hook socket path
    /// (`/tmp/synth-hook-<pid>.sock`) so an orphan can be told from a live instance's child
    /// without consulting any file we might have failed to write.
    struct Origin: Equatable {
        var session: String
        var instance: pid_t?
    }

    // MARK: Reaping

    /// Reap what closing `session` left outside its process group. The group itself is already
    /// signalled by the time this runs (`GhosttySurfaceView.reapProcessTree`), so in the ordinary
    /// case there is nothing here to find.
    ///
    /// Returns immediately; the sweep happens on `queue`.
    static func reapEscaped(session: UUID) {
        let id = session.uuidString
        let closedAt = Date()
        queue.async {
            // Latest close wins: a row closed, reopened, and closed again must be allowed to reap
            // the second incarnation's leftovers, which the first close's cutoff would spare.
            pendingSessions[id] = max(pendingSessions[id] ?? closedAt, closedAt)
            scheduleDrain()
        }
    }

    /// Reap processes stamped by a Synth that is no longer running — the escapees of an instance
    /// that crashed, was force-quit, or simply quit before this code existed.
    /// `InstanceRegistry.reapOrphanedSessionTrees` covers the same ground for trees that kept
    /// their process group; this covers the ones that left it. Neither subsumes the other.
    ///
    /// A live instance's processes are never touched, including our own: keying on the pid in the
    /// hook socket path is what makes "orphan" decidable rather than guessed.
    ///
    /// Returns immediately; the sweep happens on `queue`.
    static func reapOrphansOfDeadInstances() {
        queue.async {
            pendingOrphanSweep = true
            scheduleDrain()
        }
    }

    /// Reclaim orphans whenever the system reports memory pressure.
    ///
    /// Launch is the only other time this runs, and instances die while we are up — a sibling
    /// Synth force-quit an hour ago leaves escapees that nothing reclaims until the next cold
    /// start. Pressure is a better trigger than a timer because it costs nothing on a machine
    /// that isn't struggling.
    ///
    /// Deliberately narrow: pressure reclaims *orphans*, never a live session's processes. A dev
    /// server belonging to a row the user still has open is theirs, and the system asking for
    /// memory back is not permission to stop it.
    static func startPressureMonitor() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical],
                                                             queue: queue)
        source.setEventHandler { reapOrphansOfDeadInstances() }
        source.resume()
        pressureMonitor = source
    }

    // MARK: Scheduling

    /// One sweep reads every process on the machine twice over — the environment of each, then
    /// the cwd of each survivor — and costs ~80ms. Both callers arrive in bursts: quitting closes
    /// every session at once, and the pressure source re-fires for as long as the machine is
    /// tight. So requests accumulate here and one sweep serves all of them.
    private static let queue = DispatchQueue(
        label: "io.github.isaac-scarrott.synth.session-processes", qos: .utility)

    /// Each closed session, against the instant it closed — the cutoff `drain` reaps against.
    /// Touched only from `queue`, which is serial; likewise the two flags below.
    private nonisolated(unsafe) static var pendingSessions: [String: Date] = [:]
    private nonisolated(unsafe) static var pendingOrphanSweep = false
    private nonisolated(unsafe) static var drainScheduled = false
    /// Written once at launch from the main thread and never again; a cancelled pressure source
    /// stops firing, and nothing ever wants to stop watching.
    private nonisolated(unsafe) static var pressureMonitor: DispatchSourceMemoryPressure?

    /// Long enough to absorb a quit's worth of closes, short enough that a single closed row is
    /// reaped while its folder is still warm.
    private static let coalescingWindow: DispatchTimeInterval = .milliseconds(250)

    private static func scheduleDrain() {
        guard !drainScheduled else { return }
        drainScheduled = true
        queue.asyncAfter(deadline: .now() + coalescingWindow) { drain() }
    }

    /// Nothing here runs on app quit — the process is gone before the window elapses, so a quit
    /// leaks its escapees exactly as it does today. They are caught on the next launch instead,
    /// by which point this instance is dead and they are orphans by definition.
    private static func drain() {
        drainScheduled = false
        let sessions = pendingSessions
        let orphans = pendingOrphanSweep
        pendingSessions.removeAll()
        pendingOrphanSweep = false
        guard !sessions.isEmpty || orphans else { return }

        let table = attribute()
        signal(pids(in: table) { node in
            guard let origin = node.origin else { return false }
            // Started before the row closed, or it isn't the row's leftover. `softReopenSession`
            // tears a session down and then restores the *same* Session object — same id — so a
            // reopened agent carries the stamp of the row we were sent to clean up after. The
            // start time is what tells the successor apart from the remains.
            if let closedAt = sessions[origin.session], node.started < closedAt { return true }
            guard orphans, let instance = origin.instance else { return false }
            return instance != getpid() && !isAlive(instance)
        })
    }

    // MARK: Selection

    /// The two-stage kill every other teardown path in the app uses: TERM, then KILL for whatever
    /// ignored it (a wedged node event loop is the usual holdout).
    private static func signal(_ pids: [pid_t]) {
        guard !pids.isEmpty else { return }
        // A reaper that kills silently is one you cannot argue with after the fact. Naming each
        // pid is the only record that a process died on purpose rather than crashed — and at
        // `notice`, because `info` is not persisted and a record you have to reproduce to read
        // is no record at all.
        log.notice("reaping \(pids.count, privacy: .public) escaped: \(pids.map(String.init).joined(separator: ","), privacy: .public)")
        for pid in pids { kill(pid, SIGTERM) }
        queue.asyncAfter(deadline: .now() + 2) {
            for pid in pids where isAlive(pid) { kill(pid, SIGKILL) }
        }
    }

    /// Processes whose origin satisfies `predicate`, with everything we must not kill already
    /// removed. Deepest-first, so a parent never gets to re-spawn or orphan a child we were
    /// about to signal.
    private static func pids(in table: [pid_t: Node],
                             matching predicate: (Node) -> Bool) -> [pid_t] {
        // Our own ancestry is off limits in every case. Synth may be running *inside* another
        // Synth's session (dev.sh in an agent turn), which stamps this very process with the
        // outer session's id — reaping that session by stamp would otherwise kill the app
        // executing the reap, and its whole tree with it.
        let protected = selfAndAncestors(in: table)
        let victims = table.filter { pid, node in
            guard pid > 1, !protected.contains(pid) else { return false }
            return predicate(node) && isSessionWork(pid)
        }
        return victims.keys.sorted { depth(of: $0, in: table) > depth(of: $1, in: table) }
    }

    /// Whether a stamped process is doing this session's work, rather than merely descending
    /// from it: does it sit in a folder Synth created?
    ///
    /// Carrying the stamp is not enough on its own, and the difference is not academic. Anything
    /// launched from a Synth terminal inherits the environment and keeps it forever — a user who
    /// typed `orbstack` in a session eight instances ago still has, right now, a sixteen-day-old
    /// OrbStack carrying that session's id, `setsid`'d to its own group and reparented to launchd.
    /// By stamp and ancestry it is indistinguishable from a leaked dev server. By cwd it is not:
    /// the dev servers sit in `…/Synth/worktrees/<repo>/<branch>/…` and OrbStack sits in `/`.
    ///
    /// Positive evidence, deliberately, rather than a blocklist of things not to kill: a list of
    /// applications that daemonise can only ever be as complete as the last one someone hit.
    /// A dev server started in a checkout Synth doesn't manage is missed, and that is the right
    /// way to be wrong — the cost is memory that stays held, not a process the user wanted.
    private static func isSessionWork(_ pid: pid_t) -> Bool {
        guard let cwd = workingDirectory(of: pid) else { return false }
        return cwd == worktreeRoot || cwd.hasPrefix(worktreeRoot + "/")
    }

    /// Resolved once: `AppSupport.dir` is a fixed per-channel location, and resolving symlinks
    /// on every one of ~900 processes is the difference between a sweep and a stall.
    private static let worktreeRoot: String =
        AppSupport.dir("worktrees").resolvingSymlinksInPath().standardized.path

    /// A process's current directory, from `proc_pidinfo`. Nil when it can't be read — which is
    /// a refusal to reap, not a pass, matching `ArchiveSweeper`'s treatment of a failed cwd probe.
    private static func workingDirectory(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = MemoryLayout<proc_vnodepathinfo>.size
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, Int32(size)) == Int32(size)
        else { return nil }
        return withUnsafeBytes(of: &info.pvi_cdir.vip_path) { raw in
            let bytes = raw.bindMemory(to: CChar.self)
            return bytes.baseAddress.map { String(cString: $0) }
        }
    }

    // MARK: Attribution

    private struct Node {
        var ppid: pid_t
        /// When the process began. The kernel's own record, so it cannot be confused by a pid
        /// that was reused after we listed it.
        var started: Date
        /// Nil until `attribute` fills it in — either read from this process's own environment
        /// or inherited from the nearest ancestor that had one.
        var origin: Origin?
    }

    /// Every same-uid process, each tagged with the session it belongs to.
    ///
    /// Two passes, because a stamp can be unreadable. `setproctitle` overwrites the region
    /// `KERN_PROCARGS2` reads — Next.js's server renames itself to `next-server (v14.2.8)` and
    /// takes its own environment with it — so the biggest memory holders are exactly the ones
    /// that cannot answer for themselves. They are recovered from the nearest ancestor that
    /// still can, which for a renamed server is the launcher that forked it.
    private static func attribute() -> [pid_t: Node] {
        var table: [pid_t: Node] = [:]
        for proc in liveProcesses() {
            table[proc.pid] = Node(ppid: proc.ppid, started: proc.started,
                                   origin: origin(of: proc.pid))
        }
        // Resolved against the first pass, never against itself: walking up to the nearest
        // *directly* stamped ancestor gives the same answer as chaining through inherited
        // ones, and keeping the table frozen while it's read costs nothing to say.
        let stamped = table
        for pid in stamped.keys where stamped[pid]?.origin == nil {
            table[pid]?.origin = inheritedOrigin(of: pid, in: stamped)
        }
        return table
    }

    /// The nearest marked ancestor's origin. Walks `ppid` rather than trusting a process group,
    /// and stops at init — a chain that reaches pid 1 without finding a stamp means the marked
    /// ancestor is already gone, and this process is unattributable for the rest of its life.
    private static func inheritedOrigin(of pid: pid_t, in table: [pid_t: Node]) -> Origin? {
        var seen: Set<pid_t> = [pid]
        var current = table[pid]?.ppid ?? 0
        while current > 1, seen.insert(current).inserted, let node = table[current] {
            if let origin = node.origin { return origin }
            current = node.ppid
        }
        return nil
    }

    /// Hops to init. Only used to order the kills, so an unreachable chain scoring 0 is fine.
    private static func depth(of pid: pid_t, in table: [pid_t: Node]) -> Int {
        var seen: Set<pid_t> = [pid]
        var current = table[pid]?.ppid ?? 0
        var hops = 0
        while current > 1, seen.insert(current).inserted, let node = table[current] {
            hops += 1
            current = node.ppid
        }
        return hops
    }

    /// This process and everything above it, so a reap can never sever its own branch.
    private static func selfAndAncestors(in table: [pid_t: Node]) -> Set<pid_t> {
        var chain: Set<pid_t> = [getpid()]
        var current = table[getpid()]?.ppid ?? 0
        while current > 1, chain.insert(current).inserted {
            current = table[current]?.ppid ?? 0
        }
        return chain
    }

    // MARK: Kernel reads

    private struct LiveProcess {
        var pid: pid_t
        var ppid: pid_t
        var started: Date
    }

    /// Every process owned by this user, from one `KERN_PROC_ALL` read. Other users' processes
    /// are dropped here rather than later: their argv is unreadable anyway, and nothing Synth
    /// starts is ever owned by anyone else.
    private static func liveProcesses() -> [LiveProcess] {
        var mib: [CInt] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        // The table can grow between sizing and reading; over-allocate so a process spawning
        // mid-call costs a truncated read rather than a failed one.
        size += size / 8
        let count = size / MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: count)
        guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return [] }
        let uid = getuid()
        return procs.prefix(size / MemoryLayout<kinfo_proc>.stride).compactMap { proc in
            let pid = proc.kp_proc.p_pid
            guard pid > 1, proc.kp_eproc.e_ucred.cr_uid == uid else { return nil }
            let start = proc.kp_proc.p_un.__p_starttime
            return LiveProcess(pid: pid, ppid: proc.kp_eproc.e_ppid,
                               started: Date(timeIntervalSince1970: Double(start.tv_sec)
                                             + Double(start.tv_usec) / 1_000_000))
        }
    }

    /// The stamp in `pid`'s environment, or nil when there isn't one or it can't be read.
    private static func origin(of pid: pid_t) -> Origin? {
        guard let env = environment(of: pid),
              let session = env["SYNTH_SESSION_ID"], !session.isEmpty
        else { return nil }
        return Origin(session: session, instance: env["SYNTH_SOCKET_PATH"].flatMap(instancePID))
    }

    /// The Synth that owns a hook socket, from `/tmp/synth-hook-<pid>.sock`. The convention is
    /// `Hooks.socketPath`'s; parsing it here rather than recording the pid separately keeps the
    /// stamp to variables that already exist in every session.
    private static func instancePID(fromSocketPath path: String) -> pid_t? {
        let name = (path as NSString).lastPathComponent
        guard name.hasPrefix("synth-hook-"), name.hasSuffix(".sock") else { return nil }
        return pid_t(name.dropFirst("synth-hook-".count).dropLast(".sock".count))
    }

    /// A process's environment, parsed out of `KERN_PROCARGS2`.
    ///
    /// The buffer is one flat run of NUL-separated strings: `argc`, the exec path, alignment
    /// NULs, `argc` argv strings, then the environment. Only the tail is returned — a marker
    /// sitting in argv is not a marker (an agent's own command line can quote one), the same
    /// distinction `InstanceRegistry.reapOrphanedSessionTrees` draws when it insists on a
    /// `login` leader rather than any command mentioning the login script.
    private static func environment(of pid: pid_t) -> [String: String]? {
        var argmax: CInt = 0
        var argmaxSize = MemoryLayout<CInt>.size
        var argmaxMIB: [CInt] = [CTL_KERN, KERN_ARGMAX]
        guard sysctl(&argmaxMIB, 2, &argmax, &argmaxSize, nil, 0) == 0, argmax > 0 else { return nil }

        var buffer = [CChar](repeating: 0, count: Int(argmax))
        var size = Int(argmax)
        var mib: [CInt] = [CTL_KERN, KERN_PROCARGS2, pid]
        // EINVAL for a process that exited between the listing and this read, EPERM for one we
        // may not inspect. Neither is worth distinguishing: both mean "no stamp available".
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<CInt>.size
        else { return nil }

        var argc: CInt = 0
        withUnsafeMutableBytes(of: &argc) { dst in
            buffer.withUnsafeBytes { src in
                dst.copyMemory(from: UnsafeRawBufferPointer(rebasing: src[0..<MemoryLayout<CInt>.size]))
            }
        }
        guard argc >= 0 else { return nil }

        let bytes = buffer.prefix(size).map { UInt8(bitPattern: $0) }
        var index = MemoryLayout<CInt>.size

        func nextString() -> String? {
            guard index < bytes.count else { return nil }
            var end = index
            while end < bytes.count, bytes[end] != 0 { end += 1 }
            defer { index = end + 1 }
            return String(decoding: bytes[index..<end], as: UTF8.self)
        }

        _ = nextString()                                    // exec path
        while index < bytes.count, bytes[index] == 0 { index += 1 }   // alignment NULs
        for _ in 0..<argc where index < bytes.count { _ = nextString() }

        var env: [String: String] = [:]
        while let entry = nextString() {
            guard let split = entry.firstIndex(of: "=") else { continue }
            env[String(entry[entry.startIndex..<split])] = String(entry[entry.index(after: split)...])
        }
        return env
    }

    /// Matches `Hooks.isAlive`: 0 → alive, EPERM → alive but not ours to signal.
    private static func isAlive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 || errno == EPERM }
}
