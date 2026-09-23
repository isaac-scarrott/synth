import Foundation

// The engine half of Routines: the in-process scheduler, catch-up, the one-deep queue, and a run
// itself (quiet branch cut, headless agent spawn, seeded prompt). Owned by the engine slice.
extension AppStore {
    /// Fire a routine now. Every trigger — the scheduler, catch-up, Run now, Test, and a future
    /// synth-app verb — enters here.
    func fireRoutine(_ id: UUID, trigger: RoutineTrigger, slot: Date? = nil) {
        // Engine slice fills this in.
    }
}
