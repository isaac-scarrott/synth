import Combine
import Sparkle
import SwiftUI

/// Sparkle runs on the stable channel only. dev.sh stamps a `-dev` version and writes no
/// appcast keys into the plist, so a dev build has nothing to compare against and must never
/// replace itself with a release build.
@MainActor
enum Updates {
    static let controller: SPUStandardUpdaterController? = {
        guard !isDevChannel,
              Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil,
              Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") != nil
        else { return nil }
        return SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil
        )
    }()
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
