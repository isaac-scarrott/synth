import Darwin
import Foundation

/// The task's Mach exception ports, captured before libghostty's statically linked Breakpad claims
/// them in `ghostty_init` and put back straight after — so PostHog's PLCrashReporter, installed
/// later, is the only Mach-level crash handler the process has.
///
/// Two stacked handlers do not chain. PLCrash catches the fault first and forwards it to the
/// previous handler (Breakpad) with a synchronous `exception_raise`; Breakpad's server thread never
/// answers, so the forward blocks forever with the crashing thread suspended. The process sits in
/// state U, writes no `.ips`, and looks like a hang (21 Aug 2026: a ⌘Z into a dead undo target).
/// With the ports restored, PLCrash forwards to whatever was there before Ghostty — normally
/// nothing at task level — the kernel falls through to the host's ReportCrash, and the crash is a
/// crash: PLCrash's report on disk for the next launch, the OS's `.ips`, a dead process.
///
/// GhosttyKit is a pinned third-party prebuilt (vendor/fetch-ghostty.sh), so Breakpad cannot be
/// built out; Ghostty's own crash dumps were never uploaded anyway. Breakpad's thread stays parked
/// on a port nothing routes to.
enum MachExceptionPorts {
    struct Snapshot {
        var masks: [exception_mask_t]
        var ports: [mach_port_t]
        var behaviors: [exception_behavior_t]
        var flavors: [thread_state_flavor_t]
        var count: Int { masks.count }
        /// Entries with a real port. The kernel reports a cleared class as an entry with
        /// MACH_PORT_NULL, so `count` alone can't tell "a handler" from "none".
        var live: Int { ports.filter { $0 != 0 }.count }
    }

    /// The fault classes Breakpad registers for (plus SOFTWARE, which PLCrash also uses). Anything
    /// outside this set — EXC_CRASH, EXC_GUARD, EXC_RESOURCE — is never touched.
    private static let mask: exception_mask_t = {
        let types: [Int32] = [EXC_BAD_ACCESS, EXC_BAD_INSTRUCTION, EXC_ARITHMETIC, EXC_SOFTWARE, EXC_BREAKPOINT]
        return types.reduce(exception_mask_t(0)) { $0 | exception_mask_t(1) << exception_mask_t($1) }
    }()

    static func capture() -> Snapshot? {
        let cap = Int(EXC_TYPES_COUNT)
        var masks = [exception_mask_t](repeating: 0, count: cap)
        var ports = [mach_port_t](repeating: 0, count: cap)
        var behaviors = [exception_behavior_t](repeating: 0, count: cap)
        var flavors = [thread_state_flavor_t](repeating: 0, count: cap)
        var count = mach_msg_type_number_t(cap)
        let kr = task_get_exception_ports(mach_task_self_, mask, &masks, &count, &ports, &behaviors, &flavors)
        guard kr == KERN_SUCCESS else {
            NSLog("Synth: task_get_exception_ports failed (%d)", kr)
            return nil
        }
        let n = Int(count)
        return Snapshot(masks: Array(masks[..<n]), ports: Array(ports[..<n]),
                        behaviors: Array(behaviors[..<n]), flavors: Array(flavors[..<n]))
    }

    /// Put `snapshot` back as the task's handlers for every class in `mask`. Entries the snapshot
    /// lacks (no handler at capture time) go back to none — `task_get_exception_ports` only reports
    /// classes that have a port, so clearing first is what restores "nothing" faithfully.
    static func restore(_ snapshot: Snapshot) {
        let task = mach_task_self_
        let claimed = capture()?.live ?? -1
        var kr = task_set_exception_ports(task, mask, 0, EXCEPTION_DEFAULT, THREAD_STATE_NONE)
        if kr != KERN_SUCCESS { NSLog("Synth: clearing Mach exception ports failed (%d)", kr) }
        for i in 0..<snapshot.count {
            kr = task_set_exception_ports(task, snapshot.masks[i], snapshot.ports[i],
                                          snapshot.behaviors[i], snapshot.flavors[i])
            if kr != KERN_SUCCESS { NSLog("Synth: restoring a Mach exception port failed (%d)", kr) }
            // The get handed us a send right per entry; the set took its own reference.
            mach_port_deallocate(task, snapshot.ports[i])
        }
        let after = capture()?.live ?? -1
        NSLog("Synth: Mach exception handlers — %d before ghostty_init, %d after, %d once restored",
              snapshot.live, claimed, after)
    }
}
