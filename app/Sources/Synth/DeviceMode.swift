import Foundation
import SwiftUI

// Device mode (working.html `.browser__devicebar` / `.devframe`): the live page rendered
// inside a hardware device frame at a real device viewport. This file carries the fleet
// catalog and the CDP emulation seam; the strip and frame are drawn by BrowserPane.

/// One device the strip can put the page on. Dimensions are CSS-viewport points —
/// the numbers a media query actually sees — not hardware pixels; `deviceScaleFactor`
/// is the DPR the override reports. Everything else here is the hardware's own
/// measurement (bezel per edge, body and screen corner radii, status-bar height and
/// insets, home indicator), because the frame lays out at true points and only then
/// scales to fit the pane: real numbers keep the bezel-to-screen ratio right at every
/// pane width, where a single tuned constant is only right at one.
struct BrowserDevice: Identifiable, Equatable {
    /// The cutout the display is punched around, and what else the front carries.
    enum Face { case island, punch, homeButton, cameraTop, cameraSide }

    /// The browser the device runs. Its bars are part of how a page renders there, so
    /// they take their space off the page rather than floating over it.
    enum OnScreen { case safariPhone, safariPad, chromeAndroid }

    /// Bezel thickness per edge, portrait, in device points. Per edge because rotating
    /// walks each one place round — an SE's tall forehead ends up on the left, not
    /// still on top.
    struct Bezel: Equatable {
        let top: CGFloat, trailing: CGFloat, bottom: CGFloat, leading: CGFloat

        static func uniform(_ v: CGFloat) -> Bezel {
            Bezel(top: v, trailing: v, bottom: v, leading: v)
        }

        /// Turned counter-clockwise: the top edge becomes the leading one.
        var rotated: Bezel {
            Bezel(top: trailing, trailing: bottom, bottom: leading, leading: top)
        }
    }

    let id: String
    let name: String
    let width: CGFloat
    let height: CGFloat
    let deviceScaleFactor: Double
    let face: Face
    let onScreen: OnScreen
    let bezel: Bezel
    let frameRadius: CGFloat
    let screenRadius: CGFloat
    let statusBarHeight: CGFloat
    /// iOS drops the status-bar row against the island rather than centring in the gap.
    let statusBarTopInset: CGFloat
    let statusBarLeading: CGFloat
    let statusBarTrailing: CGFloat
    /// The strip iOS/Android reserves at the bottom. A home-button device reserves the
    /// room the browser's bar sits in and draws nothing.
    let homeIndicatorHeight: CGFloat

    var isTablet: Bool { onScreen == .safariPad }
    var drawsHomeIndicator: Bool { face != .homeButton }

    /// The popular current devices, smallest viewport to biggest, so a page is checked
    /// at both extremes rather than one convenient middle (working.html DEVICES).
    static let fleet: [BrowserDevice] = [
        BrowserDevice(id: "iphone-se", name: "iPhone SE",
                      width: 375, height: 667, deviceScaleFactor: 2,
                      face: .homeButton, onScreen: .safariPhone,
                      bezel: Bezel(top: 96, trailing: 28, bottom: 118, leading: 28),
                      frameRadius: 42, screenRadius: 3,
                      statusBarHeight: 20, statusBarTopInset: 0,
                      statusBarLeading: 16, statusBarTrailing: 16,
                      homeIndicatorHeight: 10),
        BrowserDevice(id: "iphone-16", name: "iPhone 16",
                      width: 393, height: 852, deviceScaleFactor: 3,
                      face: .island, onScreen: .safariPhone,
                      bezel: .uniform(12), frameRadius: 62, screenRadius: 50,
                      statusBarHeight: 54, statusBarTopInset: 6,
                      statusBarLeading: 30, statusBarTrailing: 22,
                      homeIndicatorHeight: 21),
        BrowserDevice(id: "iphone-16-pm", name: "iPhone 16 Pro Max",
                      width: 440, height: 956, deviceScaleFactor: 3,
                      face: .island, onScreen: .safariPhone,
                      bezel: .uniform(12), frameRadius: 66, screenRadius: 54,
                      statusBarHeight: 56, statusBarTopInset: 6,
                      statusBarLeading: 34, statusBarTrailing: 24,
                      homeIndicatorHeight: 21),
        BrowserDevice(id: "galaxy-s25u", name: "Galaxy S25 Ultra",
                      width: 412, height: 952, deviceScaleFactor: 3,
                      face: .punch, onScreen: .chromeAndroid,
                      bezel: .uniform(8), frameRadius: 32, screenRadius: 24,
                      statusBarHeight: 30, statusBarTopInset: 0,
                      statusBarLeading: 18, statusBarTrailing: 16,
                      homeIndicatorHeight: 24),
        BrowserDevice(id: "ipad-mini", name: "iPad mini",
                      width: 744, height: 1133, deviceScaleFactor: 2,
                      face: .cameraTop, onScreen: .safariPad,
                      bezel: .uniform(52), frameRadius: 74, screenRadius: 22,
                      statusBarHeight: 24, statusBarTopInset: 0,
                      statusBarLeading: 26, statusBarTrailing: 26,
                      homeIndicatorHeight: 20),
        BrowserDevice(id: "ipad-pro-13", name: "iPad Pro 13″",
                      width: 1032, height: 1376, deviceScaleFactor: 2,
                      face: .cameraSide, onScreen: .safariPad,
                      bezel: .uniform(44), frameRadius: 64, screenRadius: 22,
                      statusBarHeight: 24, statusBarTopInset: 0,
                      statusBarLeading: 28, statusBarTrailing: 28,
                      homeIndicatorHeight: 20),
    ]

    /// iPhone 16 — the mainstream middle of the fleet, the mode's default.
    static let initial = fleet[1]
}

/// The bars the device's own browser draws, in device points (working.html `.devui__*`).
enum DeviceBars {
    static let safariPillHeight: CGFloat = 40
    static let safariPillTopPad: CGFloat = 9
    static let safariToolsTopPad: CGFloat = 12
    static let safariToolsHeight: CGFloat = 22
    /// Landscape folds the lot into one top bar: 6 + pill + 8.
    static let safariTopBar: CGFloat = 54
    /// iPad Safari: 8 + row 34 + 8 + tab strip 32.
    static let padBar: CGFloat = 82
    /// Chrome for Android: 2 + omnibox 36 + 10.
    static let androidBar: CGFloat = 48

    static var safariBottomBar: CGFloat {
        safariPillTopPad + safariPillHeight + safariToolsTopPad + safariToolsHeight
    }
}

extension BrowserDevice {
    func bezels(landscape: Bool) -> Bezel { landscape ? bezel.rotated : bezel }

    func screenSize(landscape: Bool) -> CGSize {
        CGSize(width: landscape ? height : width, height: landscape ? width : height)
    }

    /// What the device's browser takes off the page, top and bottom.
    func browserChrome(landscape: Bool) -> (top: CGFloat, bottom: CGFloat) {
        switch onScreen {
        case .safariPad:
            return (statusBarHeight + DeviceBars.padBar, homeIndicatorHeight)
        case .chromeAndroid:
            return (statusBarHeight + DeviceBars.androidBar, homeIndicatorHeight)
        case .safariPhone:
            // Landscape iPhone hides the status bar and folds every control into one top bar.
            if landscape { return (DeviceBars.safariTopBar, homeIndicatorHeight) }
            return (statusBarHeight, DeviceBars.safariBottomBar + homeIndicatorHeight)
        }
    }

    /// The viewport the page actually gets: the screen minus the browser's own bars.
    /// This is what the CDP override emulates and what the strip reads out — handing a
    /// page the full 393 × 852 passes `100vh` layouts no iPhone ever gives that room.
    func pageViewport(landscape: Bool) -> CGSize {
        let screen = screenSize(landscape: landscape)
        let chrome = browserChrome(landscape: landscape)
        return CGSize(width: screen.width,
                      height: max(1, screen.height - chrome.top - chrome.bottom))
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
