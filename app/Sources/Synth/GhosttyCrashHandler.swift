import Darwin
import Foundation

/// libghostty statically links sentry-native, whose Breakpad backend claims the task's Mach
/// exception ports and SIGABRT. Left in place it owns every crash in the process: it writes a
/// minidump nobody uploads (~/.local/state/cmux/crash) and calls `_exit(1)` — no `.ips`, no
/// PLCrashReporter report, no CrashReporter marker. Synth "just exits" and every channel we
/// read says nothing happened (29 Sep 2026: a fault inside CEF at 22:12 and a SwiftUI
/// FocusBridge assertion at 18:54, both recovered only from those minidumps). Stacked under
/// PLCrash instead, the forward to Breakpad never returns and a crash becomes a hang
/// (21 Aug 2026).
///
/// `ghostty_init` does not claim the ports itself: it spawns a `sentry-init` thread that does,
/// some time after `ghostty_init` has returned. A capture/restore around the call raced that
/// thread and usually lost. So wait for the thread to finish, then `sentry_close()` — Sentry's
/// own shutdown, which tears down Breakpad's ExceptionHandler and hands back the ports and the
/// SIGABRT action it found. PLCrash (Analytics) and CrashReporter install after this, onto a
/// task nothing else holds.
///
/// GhosttyKit is a pinned third-party prebuilt (vendor/fetch-ghostty.sh), so Sentry cannot be
/// built out; Ghostty's own crash dumps were never uploaded anyway.
enum GhosttyCrashHandler {
    @_silgen_name("sentry_close") private static func sentry_close() -> Int32

    /// Sentry's init takes a few milliseconds (1–5ms measured); the bounds only matter when
    /// something is wrong, and each of those outcomes is reported rather than guessed past.
    private static let appearGrace: TimeInterval = 0.25
    private static let finishBound: TimeInterval = 1

    /// Call once, straight after `ghostty_init`, on the thread that called it.
    static func evict() {
        let start = Date()
        var seen = false
        while true {
            let running = threadExists(named: "sentry-init")
            seen = seen || running
            let waited = Date().timeIntervalSince(start)
            if waited > finishBound {
                // Closing under a live sentry_init races its database lock and backend setup.
                // Leave it installed and say so: crashes this run go unreported — a silent exit,
                // or a hang once PLCrash installs over it (21 Aug 2026).
                Fault.report(.crash, .crashCaptureUnavailable,
                             details: [.flag("sentry_init_timed_out", true)])
                return
            }
            if !running && (seen || inProcessHandlers() > 0 || waited > appearGrace) { break }
            usleep(500)
        }
        let claimed = inProcessHandlers()
        _ = sentry_close()
        let remaining = inProcessHandlers()
        NSLog("Synth: Ghostty's Sentry %@ after %.1fms; in-process crash handlers %d → %d",
              seen ? "finished" : "never seen", Date().timeIntervalSince(start) * 1000,
              claimed, remaining)
        // Not seen and nothing claimed may mean the thread simply hasn't run yet and will
        // install Breakpad after this — the silent-exit state this type exists to prevent.
        if remaining != 0 || (!seen && claimed == 0) {
            Fault.report(.crash, .crashCaptureUnavailable,
                         details: [.flag("sentry_init_seen", seen), .count("handlers_left", remaining)])
        }
    }

    private static func threadExists(named name: String) -> Bool {
        var threads: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &threads, &count) == KERN_SUCCESS, let threads else {
            return false
        }
        defer {
            for i in 0..<Int(count) { mach_port_deallocate(mach_task_self_, threads[i]) }
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: threads),
                          vm_size_t(Int(count) * MemoryLayout<thread_act_t>.stride))
        }
        var buf = [CChar](repeating: 0, count: 64)
        for i in 0..<Int(count) {
            guard let pthread = pthread_from_mach_thread_np(threads[i]),
                  pthread_getname_np(pthread, &buf, buf.count) == 0 else { continue }
            if String(cString: buf) == name { return true }
        }
        return false
    }

    /// Crash-class exception ports whose receive right lives in this task — an in-process
    /// handler such as Breakpad. The system's own out-of-process handlers don't count.
    private static func inProcessHandlers() -> Int {
        let types: [Int32] = [EXC_BAD_ACCESS, EXC_BAD_INSTRUCTION, EXC_ARITHMETIC, EXC_SOFTWARE, EXC_BREAKPOINT]
        let mask = types.reduce(exception_mask_t(0)) { $0 | exception_mask_t(1) << exception_mask_t($1) }
        let cap = Int(EXC_TYPES_COUNT)
        var masks = [exception_mask_t](repeating: 0, count: cap)
        var ports = [mach_port_t](repeating: 0, count: cap)
        var behaviors = [exception_behavior_t](repeating: 0, count: cap)
        var flavors = [thread_state_flavor_t](repeating: 0, count: cap)
        var count = mach_msg_type_number_t(cap)
        guard task_get_exception_ports(mach_task_self_, mask, &masks, &count, &ports,
                                       &behaviors, &flavors) == KERN_SUCCESS else { return -1 }
        // MACH_PORT_TYPE_RECEIVE is a macro Swift doesn't import: MACH_PORT_TYPE(MACH_PORT_RIGHT_RECEIVE).
        let receiveRight = mach_port_type_t(1) << (mach_port_type_t(MACH_PORT_RIGHT_RECEIVE) + 16)
        var live = 0
        for port in ports[..<Int(count)] where port != 0 {
            var type: mach_port_type_t = 0
            if mach_port_type(mach_task_self_, port, &type) == KERN_SUCCESS,
               type & receiveRight != 0 { live += 1 }
            mach_port_deallocate(mach_task_self_, port)
        }
        return live
    }
}
