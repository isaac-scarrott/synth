import Foundation

extension Process {
    /// `run()`, handing back the exit to wait on. Wait on that, never on `waitUntilExit()`:
    /// Foundation's wait spins the calling thread's run loop and only notices the child has gone
    /// about 70ms after it has, on any thread. A `git config` that is done in 3ms cost its caller
    /// 70, every git and simctl call in the app paid the same, and two of them sat on main
    /// before the first frame. The termination handler fires as soon as the child is reaped.
    func start() throws -> Exit {
        let exited = DispatchSemaphore(value: 0)
        terminationHandler = { _ in exited.signal() }
        try run()
        return Exit(exited: exited)
    }

    struct Exit {
        fileprivate let exited: DispatchSemaphore

        /// Blocks until the process has exited; `terminationStatus` is valid once it returns.
        func wait() { exited.wait() }
    }
}
