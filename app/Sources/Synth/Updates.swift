import Combine
import Sparkle
import SwiftUI

/// Sparkle runs on the stable channel only. dev.sh stamps a `-dev` version and writes no
/// appcast keys into the plist, so a dev build has nothing to compare against and must never
/// replace itself with a release build.
@MainActor
enum Updates {
    /// Held here because `SPUStandardUpdaterController` keeps its delegates weakly.
    static let bridge = UpdateBridge()

    static let controller: SPUStandardUpdaterController? = {
        guard !isDevChannel,
              Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil,
              Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") != nil
        else { return nil }
        return SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: bridge, userDriverDelegate: bridge
        )
    }()
}

/// Sparkle speaks through the notification deck, not through its own window.
///
/// `SUEnableAutomaticChecks` + `SUAutomaticallyUpdate` mean a newer build finds and downloads
/// itself in the background; this bridge is what turns that otherwise silent event into a card,
/// and what hands the card the relaunch it offers. Nothing here starts a download or asks
/// permission to — by the time we speak, the build is already on disk and installs itself on the
/// next quit, which is exactly what makes the card's `Restart` a shortcut rather than a demand.
final class UpdateBridge: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    /// Tells Sparkle we own the reminding, so it holds its own alert back for a scheduled find.
    var supportsGentleScheduledUpdateReminders: Bool { true }

    /// A build Synth went looking for on its own is Synth's news to break. A check the user
    /// asked for from the app menu is not scheduled, so Sparkle still shows its own window there
    /// — they asked a question and deserve an answer in the place they asked it.
    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem,
                                                              andInImmediateFocus immediateFocus: Bool) -> Bool {
        false
    }

    /// The one hook that matters: the build is staged, so from here the only open question is
    /// *when* it lands — and that question belongs to the card. Returning true takes the update
    /// cycle off Sparkle's hands; it installs on quit regardless, so nothing is lost by holding
    /// the handler until someone asks for it sooner.
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        let version = item.displayVersionString
        // The relaunch quits us, and the quit confirm must not fire on top of the answer the user
        // just gave — one restart, one question. It rides with the installer rather than with the
        // caller, so a stub installer can never leave the flag standing (Store.applyUpdate).
        let stage = { @MainActor in
            AppStore.shared?.updateStaged(version: version) {
                AppTermination.forceQuit = true
                immediateInstallHandler()
            }
        }
        // Sparkle calls this on the main thread today; hop rather than assume, because assuming
        // is a fatalError if a future Sparkle ever changes its mind.
        if Thread.isMainThread { MainActor.assumeIsolated { stage() } } else { Task { @MainActor in stage() } }
        return true
    }
}

/// Tracks Sparkle's own readiness — it refuses a second check while one is in flight.
@MainActor
final class CheckForUpdatesModel: ObservableObject {
    @Published var canCheck = false

    init() {
        guard let updater = Updates.controller?.updater else { return }
        updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheck)
    }
}

/// "Check for Updates…" under the app menu. Absent, not disabled, on builds without an
/// updater: a greyed-out item would promise something the dev channel never does.
struct CheckForUpdatesButton: View {
    @StateObject private var model = CheckForUpdatesModel()

    var body: some View {
        if let updater = Updates.controller?.updater {
            Button("Check for Updates…") { updater.checkForUpdates() }
                .disabled(!model.canCheck)
        }
    }
}
