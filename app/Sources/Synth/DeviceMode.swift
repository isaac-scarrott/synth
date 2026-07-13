import Foundation
import SwiftUI

// Device mode (working.html `.browser__devicebar` / `.devframe`): the live page rendered
// inside a hardware device frame at a real device viewport. This file carries the fleet
// catalog and the CDP emulation seam; the strip and frame are drawn by BrowserPane.

/// One device the strip can put the page on. Dimensions are CSS-viewport points —
/// the numbers a media query actually sees — not hardware pixels; `deviceScaleFactor`
/// is the DPR the override reports.
struct BrowserDevice: Identifiable, Equatable {
    /// How the hardware around the screen is drawn.
    enum Chrome {
        case bezel    // thick top/bottom bezel (iPhone SE)
        case island   // dynamic island + home indicator
        case punch    // punch-hole camera + home indicator
        case pad      // uniform tablet border
    }

    let id: String
    let name: String
    let width: CGFloat
    let height: CGFloat
    let deviceScaleFactor: Double
    let chrome: Chrome

    /// The popular current devices, smallest viewport to biggest, so a page is checked
    /// at both extremes rather than one convenient middle (working.html DEVICES).
    static let fleet: [BrowserDevice] = [
        BrowserDevice(id: "iphone-se", name: "iPhone SE",
                      width: 375, height: 667, deviceScaleFactor: 2, chrome: .bezel),
        BrowserDevice(id: "iphone-16", name: "iPhone 16",
                      width: 393, height: 852, deviceScaleFactor: 3, chrome: .island),
        BrowserDevice(id: "iphone-16-pm", name: "iPhone 16 Pro Max",
                      width: 440, height: 956, deviceScaleFactor: 3, chrome: .island),
        BrowserDevice(id: "galaxy-s25u", name: "Galaxy S25 Ultra",
                      width: 412, height: 952, deviceScaleFactor: 3, chrome: .punch),
        BrowserDevice(id: "ipad-mini", name: "iPad mini",
                      width: 744, height: 1133, deviceScaleFactor: 2, chrome: .pad),
        BrowserDevice(id: "ipad-pro-13", name: "iPad Pro 13″",
                      width: 1032, height: 1376, deviceScaleFactor: 2, chrome: .pad),
    ]

    /// iPhone 16 — the mainstream middle of the fleet, the mode's default.
    static let initial = fleet[1]
}

extension BrowserDevice.Chrome {
    /// Bezel thickness around the screen, in device points (the mock's frame padding).
    var padding: (h: CGFloat, v: CGFloat) {
        switch self {
        case .bezel:          return (16, 52)
        case .island, .punch: return (14, 14)
        case .pad:            return (22, 22)
        }
    }

    var frameRadius: CGFloat {
        switch self {
        case .bezel:          return 40
        case .island, .punch: return 44
        case .pad:            return 34
        }
    }

    var screenRadius: CGFloat {
        switch self {
        case .bezel:          return 3
        case .island, .punch: return 32
        case .pad:            return 14
        }
    }
}

/// True viewport emulation over CDP — Chrome DevTools' own device toolbar, driven from
/// the controller. The engine view is laid out at (w·s)×(h·s) points inside the frame's
/// screen; the override's `scale: s` renders the full w×h viewport into it, so
/// `window.innerWidth` is the device width and clicks land where they look like they do.
/// Ops are chained so a rapid device/rotate/fit burst never interleaves sends on the
/// socket; the client stays attached across navigations (CDP metrics overrides persist
/// per target). Failures degrade gracefully — the frame still draws around an
/// un-emulated page. `cdpPort == 0` (the WKWebView hedge) skips emulation entirely.
@MainActor final class DeviceEmulator {
    private let sessionID: UUID
    private let cdpPort: UInt16
    private var client: CDPClient?
    private var chain: Task<Void, Never>?

    init(sessionID: UUID, cdpPort: UInt16) {
        self.sessionID = sessionID
        self.cdpPort = cdpPort
    }

    func apply(width: Int, height: Int, deviceScaleFactor: Double, scale: Double,
               urlHint: URL?) {
        guard cdpPort != 0 else { return }
        enqueue { [weak self] in
            guard let self else { return }
            if self.client == nil {
                self.client = try? await CDPClient.attach(port: self.cdpPort,
                                                          synthSessionID: self.sessionID,
                                                          urlHint: urlHint)
                guard self.client != nil else {
                    NSLog("Synth: device mode CDP attach failed for %@ — frame only",
                          self.sessionID.uuidString)
                    return
                }
            }
            guard let client = self.client else { return }
            _ = try? await client.send("Emulation.setDeviceMetricsOverride", [
                "width": width, "height": height,
                "deviceScaleFactor": deviceScaleFactor,
                "mobile": true, "scale": scale,
            ])
        }
    }

    func clear() {
        enqueue { [weak self] in
            guard let self, let client = self.client else { return }
            _ = try? await client.send("Emulation.clearDeviceMetricsOverride", [:],
                                       timeout: 5)
            client.close()
            self.client = nil
        }
    }

    /// Synchronous cleanup — session close / app quit (no CDP goodbyes).
    func teardown() {
        client?.close()
        client = nil
    }

    private func enqueue(_ op: @escaping @MainActor () async -> Void) {
        let prev = chain
        chain = Task { await prev?.value; await op() }
    }
}
