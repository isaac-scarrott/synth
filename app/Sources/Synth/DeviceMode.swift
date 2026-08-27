import Foundation
import SwiftUI

// Conditions (working.html `.browser__condbar`): the three axes a worst case is made of —
// the screen the live page is rendered at (inside a hardware frame, when the screen is one
// you hold), the network and the CPU. This file carries the fleet catalog, the two machine
// axes and the CDP emulation seam; the bar and frame are drawn by BrowserPane.
//
// The device model here serves two surfaces, not one (ADR-0015): the browser's device mode, whose
// viewport it emulates over CDP, and the simulator pane, which draws the same hardware around a
// real device's framebuffer. Hence `HardwareDevice` rather than a browser-specific name — the
// browser's own software chrome lives in `BrowserDeviceScreen`, which a simulator never uses.

/// One device the frame can be drawn as. Dimensions are CSS-viewport points —
/// the numbers a media query actually sees — not hardware pixels; `deviceScaleFactor`
/// is the DPR the override reports. Everything else here is the hardware's own
/// measurement (bezel per edge, body and screen corner radii, status-bar height and
/// insets, home indicator), because the frame lays out at true points and only then
/// scales to fit the pane: real numbers keep the bezel-to-screen ratio right at every
/// pane width, where a single tuned constant is only right at one.
struct HardwareDevice: Identifiable, Equatable {
    /// The cutout the display is punched around, and what else the front carries.
    /// `plain` is a screen with nothing punched into it — a monitor, which has no front
    /// worth drawing.
    enum Face { case island, punch, homeButton, cameraTop, cameraSide, plain }

    /// The browser the device runs. Its bars are part of how a page renders there, so
    /// they take their space off the page rather than floating over it. `desktop` runs
    /// whatever browser the person has: we don't know its chrome, so we draw none and
    /// hand the page the whole screen.
    enum OnScreen { case safariPhone, safariPad, chromeAndroid, desktop }

    /// How the fleet is grouped where it is offered.
    enum Tier: String, CaseIterable {
        case phone = "Phones", tablet = "Tablets", desktop = "Desktops"
    }

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
    /// Who is on it and why it is worth checking — the picker's tooltip.
    let note: String
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
    /// A screen rather than hardware you hold: no bezel, no cutout, no software of its own.
    var isDesktopScreen: Bool { onScreen == .desktop }
    var tier: Tier { isDesktopScreen ? .desktop : (isTablet ? .tablet : .phone) }

    /// The popular current devices, smallest viewport to biggest, so a page is checked
    /// at both extremes rather than one convenient middle (working.html DEVICES).
    static let fleet: [HardwareDevice] = [
        HardwareDevice(id: "iphone-se", name: "iPhone SE",
                      note: "The small phone that is still in pockets.",
                      width: 375, height: 667, deviceScaleFactor: 2,
                      face: .homeButton, onScreen: .safariPhone,
                      bezel: Bezel(top: 96, trailing: 28, bottom: 118, leading: 28),
                      frameRadius: 42, screenRadius: 3,
                      statusBarHeight: 20, statusBarTopInset: 0,
                      statusBarLeading: 16, statusBarTrailing: 16,
                      homeIndicatorHeight: 10),
        HardwareDevice(id: "iphone-16", name: "iPhone 16",
                      note: "The current mid-size iPhone.",
                      width: 393, height: 852, deviceScaleFactor: 3,
                      face: .island, onScreen: .safariPhone,
                      bezel: .uniform(12), frameRadius: 62, screenRadius: 50,
                      statusBarHeight: 54, statusBarTopInset: 6,
                      statusBarLeading: 30, statusBarTrailing: 22,
                      homeIndicatorHeight: 21),
        HardwareDevice(id: "iphone-16-pm", name: "iPhone 16 Pro Max",
                      note: "The biggest phone viewport worth checking.",
                      width: 440, height: 956, deviceScaleFactor: 3,
                      face: .island, onScreen: .safariPhone,
                      bezel: .uniform(12), frameRadius: 66, screenRadius: 54,
                      statusBarHeight: 56, statusBarTopInset: 6,
                      statusBarLeading: 34, statusBarTrailing: 24,
                      homeIndicatorHeight: 21),
        HardwareDevice(id: "galaxy-s25u", name: "Galaxy S25 Ultra",
                      note: "Android’s flagship, and Chrome’s own chrome around the page.",
                      width: 412, height: 952, deviceScaleFactor: 3,
                      face: .punch, onScreen: .chromeAndroid,
                      bezel: .uniform(8), frameRadius: 32, screenRadius: 24,
                      statusBarHeight: 30, statusBarTopInset: 0,
                      statusBarLeading: 18, statusBarTrailing: 16,
                      homeIndicatorHeight: 24),
        HardwareDevice(id: "ipad-mini", name: "iPad mini",
                      note: "The tablet breakpoint most layouts get wrong.",
                      width: 744, height: 1133, deviceScaleFactor: 2,
                      face: .cameraTop, onScreen: .safariPad,
                      bezel: .uniform(52), frameRadius: 74, screenRadius: 22,
                      statusBarHeight: 24, statusBarTopInset: 0,
                      statusBarLeading: 26, statusBarTrailing: 26,
                      homeIndicatorHeight: 20),
        HardwareDevice(id: "ipad-pro-13", name: "iPad Pro 13″",
                      note: "A desktop-width page on a touch device.",
                      width: 1032, height: 1376, deviceScaleFactor: 2,
                      face: .cameraSide, onScreen: .safariPad,
                      bezel: .uniform(44), frameRadius: 64, screenRadius: 22,
                      statusBarHeight: 24, statusBarTopInset: 0,
                      statusBarLeading: 28, statusBarTrailing: 28,
                      homeIndicatorHeight: 20),
        // Desktops (working.html DEVICES, kind: 'screen'): named like every other row —
        // the machine on the left, the viewport on the right — because a bare resolution
        // is a number you have to decode and "Budget laptop" is the thing you were asked
        // to check. The point of the tier is the bottom of the range rather than the top:
        // shares are Statcounter's worldwide desktop resolutions for July 2026 (1920×1080
        // 22%, 1536×864 7%, 1366×768 5%, 1280×720 5%), so a page that holds together on
        // the last of them holds for all but a sliver of the people who visit it. All at
        // 1×, where the hairlines and half-pixel borders a Retina Mac rounds away come back.
        HardwareDevice(id: "mon-1080p", name: "1080p monitor",
                      note: "The modal desktop — about 22% of desktop visitors, and the one screen here that needs no excuses made for it.",
                      width: 1920, height: 1080, deviceScaleFactor: 1,
                      face: .plain, onScreen: .desktop,
                      bezel: .uniform(0), frameRadius: 6, screenRadius: 6,
                      statusBarHeight: 0, statusBarTopInset: 0,
                      statusBarLeading: 0, statusBarTrailing: 0,
                      homeIndicatorHeight: 0),
        HardwareDevice(id: "mon-1536", name: "Windows laptop",
                      note: "A 1080p laptop at 125% scaling — about 7%, and the most common screen that is smaller than it looks.",
                      width: 1536, height: 864, deviceScaleFactor: 1,
                      face: .plain, onScreen: .desktop,
                      bezel: .uniform(0), frameRadius: 6, screenRadius: 6,
                      statusBarHeight: 0, statusBarTopInset: 0,
                      statusBarLeading: 0, statusBarTrailing: 0,
                      homeIndicatorHeight: 0),
        HardwareDevice(id: "mon-1366", name: "Budget laptop",
                      note: "Roughly 1 in 10 desktop visitors are on this screen or a smaller one.",
                      width: 1366, height: 768, deviceScaleFactor: 1,
                      face: .plain, onScreen: .desktop,
                      bezel: .uniform(0), frameRadius: 6, screenRadius: 6,
                      statusBarHeight: 0, statusBarTopInset: 0,
                      statusBarLeading: 0, statusBarTrailing: 0,
                      homeIndicatorHeight: 0),
        HardwareDevice(id: "mon-1280", name: "Older laptop",
                      note: "The worst screen worth designing for: hold together here and about 95% of desktop visitors are covered.",
                      width: 1280, height: 720, deviceScaleFactor: 1,
                      face: .plain, onScreen: .desktop,
                      bezel: .uniform(0), frameRadius: 6, screenRadius: 6,
                      statusBarHeight: 0, statusBarTopInset: 0,
                      statusBarLeading: 0, statusBarTrailing: 0,
                      homeIndicatorHeight: 0),
    ]

    /// iPhone 16 — the mainstream middle of the fleet, the mode's default.
    static let initial = fleet[1]

    static func fleetMember(_ id: String) -> HardwareDevice {
        fleet.first { $0.id == id } ?? initial
    }
}

// MARK: - A booted simulator's device

// Device mode picks from the fleet, so its geometry is always measured. A simulator session
// doesn't pick: it attaches to whatever device is booted, which can be any of the hundred-odd
// device types Xcode ships. So for the simulator the fleet stops being a menu and becomes a
// source of measured hardware — the nearest body — while the display the device itself reports
// supplies the screen.

extension HardwareDevice {
    /// The iPhones and iPods the simulator can boot that still have a home button and the
    /// forehead and chin to hold it. Every other one is notch or island and wears the island
    /// body: iOS blacks that region out itself, so a pill drawn inside a notch disappears
    /// into it. Keyed on `SimDeviceType.modelIdentifier`, because a generation is not a
    /// prefix — `iPhone14,6` is an SE where `iPhone14,5` is an island phone.
    private static let homeButtonModels: Set<String> = [
        "iPhone8,1", "iPhone8,2", "iPhone8,4",                   // 6s, 6s Plus, SE
        "iPhone9,1", "iPhone9,2", "iPhone9,3", "iPhone9,4",      // 7, 7 Plus
        "iPhone10,1", "iPhone10,2", "iPhone10,4", "iPhone10,5",  // 8, 8 Plus
        "iPhone12,8",                                            // SE, 2nd generation
        "iPhone14,6",                                            // SE, 3rd generation
        "iPod9,1",
    ]

    /// The hardware to draw around a booted simulator's screen.
    ///
    /// Resolved from what CoreSimulator says the device *is*, never from the session's name:
    /// a device's name is user-editable (and `simctl` spells the fleet's own devices
    /// "iPhone SE (3rd generation)" anyway), so the name only labels and breaks ties the
    /// model identifier can't. **The reported display always wins over the template's own
    /// screen** — an iPhone 16's frame around an iPhone 16 Pro's framebuffer would stretch
    /// the live stream — so a device the fleet doesn't carry gets its real screen in the
    /// nearest real body, rather than someone else's screen under its name.
    ///
    /// - Parameters:
    ///   - modelIdentifier: `SimDeviceType.modelIdentifier`, e.g. `iPhone17,3`.
    ///   - name: the device's `simctl` name. Labels the result, and stands in for what is
    ///     missing: the body when there is no model identifier, the size class when there
    ///     is no display to measure.
    ///   - pixelSize: the display's own size in pixels — the framebuffer's `displaySize`.
    ///   - scale: the display's scale (`mainScreenScale`). Without it the points can only be
    ///     inferred from the family's usual DPR, which is wrong for a Plus-era home-button
    ///     phone, so pass it whenever the device type is in hand.
    static func forSimulator(modelIdentifier: String? = nil,
                             name: String = "",
                             pixelSize: CGSize? = nil,
                             scale: Double? = nil) -> HardwareDevice {
        let model = (modelIdentifier ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let label = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = label.lowercased()
        // A display reports itself portrait and the fleet is measured portrait; rotation is
        // the frame's business, not the device's.
        let pixels = pixelSize.flatMap { px -> CGSize? in
            guard px.width > 0, px.height > 0 else { return nil }
            return CGSize(width: min(px.width, px.height), height: max(px.width, px.height))
        }
        // Aspect survives not knowing the scale, so it can name the body before the points do.
        let aspect = pixels.map { $0.height / $0.width }

        let isPad = model.hasPrefix("iPad")
            || (model.isEmpty && (key.contains("ipad") || (aspect ?? 2) < 1.6))
        let hasHomeButton = !isPad && (homeButtonModels.contains(model)
            || (model.isEmpty && (key.contains("iphone se") || key.contains("ipod")
                                  || (aspect ?? 2.1) < 1.9)))

        let dpr = scale.flatMap { $0 >= 1 ? $0 : nil } ?? (isPad || hasHomeButton ? 2 : 3)
        let points = pixels.map { CGSize(width: ($0.width / dpr).rounded(),
                                        height: ($0.height / dpr).rounded()) }

        // Which end of the family. A `simctl` listing has no screen in it, so a device
        // picked before it ever renders a frame has only its name to say how big it is.
        let bigByName = ["max", "plus", "12.9", "13-inch", "13″"].contains { key.contains($0) }

        let template: HardwareDevice
        if isPad {
            // The two iPads split at the 11″ class: a mini's 52pt bezel on a 13″ body is a
            // slab, and the Pro's camera sits on the long edge where the mini's is on top.
            template = fleetMember(points.map { $0.height >= 1250 } ?? bigByName
                ? "ipad-pro-13" : "ipad-mini")
        } else if hasHomeButton {
            template = fleetMember("iphone-se")
        } else {
            template = fleetMember(points.map { $0.width >= 420 } ?? bigByName
                ? "iphone-16-pm" : "iphone-16")
        }

        // Without a display size the template's screen is the only one there is: the sole
        // case where the geometry is a guess, and it lasts until the first frame lands.
        let screen = points ?? CGSize(width: template.width, height: template.height)
        // A device whose screen its template already measures *is* that fleet member.
        if screen.width == template.width, screen.height == template.height,
           dpr == template.deviceScaleFactor, label.isEmpty || label == template.name {
            return template
        }
        return template.hosting(
            screen: screen, scale: dpr,
            id: model.isEmpty ? "sim-\(Int(screen.width))x\(Int(screen.height))" : model,
            name: label.isEmpty ? template.name : label)
    }

    /// The same measured body around a different screen. The bezel, radii and face are the
    /// template's because they are the hardware's; the screen is the device's own.
    private func hosting(screen: CGSize, scale: Double, id: String,
                         name: String) -> HardwareDevice {
        HardwareDevice(id: id, name: name, note: note,
                      width: screen.width, height: screen.height,
                      deviceScaleFactor: scale, face: face, onScreen: onScreen, bezel: bezel,
                      frameRadius: frameRadius, screenRadius: screenRadius,
                      statusBarHeight: statusBarHeight, statusBarTopInset: statusBarTopInset,
                      statusBarLeading: statusBarLeading, statusBarTrailing: statusBarTrailing,
                      homeIndicatorHeight: homeIndicatorHeight)
    }
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

extension HardwareDevice {
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
        case .desktop:
            // Someone else's browser draws its own chrome outside the page, exactly as
            // ours does — so the screen is the viewport.
            return (0, 0)
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

// MARK: - The two axes that aren't the screen

// A worst case is three separate things and they fail apart: a page can hold together at
// 1280 and fall over on a slow processor, or the other way round. So the screen, the wire and
// the processor are set apart, and every one of them rests at "Normal" — the same word in all
// three, because we don't know what the wire is or how fast this Mac is, only that we have
// left it alone. What normal means for each axis is the caption's job, not the name's.

/// The wire, in Chromium's own presets, so the label is what the engine does.
enum NetworkCondition: String, CaseIterable, Identifiable {
    case normal, fast4g, slow4g, threeG = "3g", offline

    var id: String { rawValue }

    var name: String {
        switch self {
        case .normal:  return "Normal"
        case .fast4g:  return "Fast 4G"
        case .slow4g:  return "Slow 4G"
        case .threeG:  return "3G"
        case .offline: return "Offline"
        }
    }

    /// What it costs you, shown beside the name.
    var detail: String {
        switch self {
        case .normal:  return "no throttle"
        case .fast4g:  return "9 Mb/s · 165 ms"
        case .slow4g:  return "1.44 Mb/s · 562 ms"
        case .threeG:  return "400 kb/s · 2 s"
        case .offline: return "nothing resolves"
        }
    }

    /// Network.emulateNetworkConditions' own units: bytes per second and milliseconds.
    var cdp: (offline: Bool, latency: Double, down: Double, up: Double)? {
        switch self {
        case .normal:  return nil
        case .fast4g:  return (false, 165, 9_000_000 / 8, 1_500_000 / 8)
        case .slow4g:  return (false, 562.5, 1_440_000 / 8, 675_000 / 8)
        case .threeG:  return (false, 2_000, 400_000 / 8, 400_000 / 8)
        case .offline: return (true, 0, 0, 0)
        }
    }
}

/// The processor, as a slowdown against *this* Mac — the only honest way to say it, since
/// 4× on a 16-inch is a mid-tier machine and the same 4× on a lesser one is not.
enum CPUThrottle: Int, CaseIterable, Identifiable {
    case normal = 1, x2 = 2, x4 = 4, x6 = 6

    var id: Int { rawValue }

    var name: String { self == .normal ? "Normal" : "\(rawValue)× slower" }

    var detail: String {
        switch self {
        case .normal: return "this Mac"
        case .x2:     return "a current phone"
        case .x4:     return "mid-tier"
        case .x6:     return "low-end"
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
/// un-emulated page.
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
               mobile: Bool, urlHint: URL?) {
        enqueue { [weak self] in
            guard let client = await self?.connect(urlHint: urlHint) else { return }
            _ = try? await client.send("Emulation.setDeviceMetricsOverride", [
                "width": width, "height": height,
                "deviceScaleFactor": deviceScaleFactor,
                // A monitor is a desktop browser: touch and a mobile user agent would be a
                // claim about the machine that the resolution never made.
                "mobile": mobile, "scale": scale,
            ])
        }
    }

    /// The screen back to the pane's own, with the wire and the processor left as they are —
    /// three axes, three switches.
    func clearMetrics() {
        enqueue { [weak self] in
            guard let client = self?.client else { return }
            _ = try? await client.send("Emulation.clearDeviceMetricsOverride", [:], timeout: 5)
        }
    }

    func applyNetwork(_ condition: NetworkCondition, urlHint: URL?) {
        enqueue { [weak self] in
            guard let client = await self?.connect(urlHint: urlHint) else { return }
            _ = try? await client.send("Network.enable", [:])
            let c = condition.cdp ?? (offline: false, latency: 0, down: -1, up: -1)
            _ = try? await client.send("Network.emulateNetworkConditions", [
                "offline": c.offline, "latency": c.latency,
                "downloadThroughput": c.down, "uploadThroughput": c.up,
            ])
        }
    }

    func applyCPU(_ throttle: CPUThrottle, urlHint: URL?) {
        enqueue { [weak self] in
            guard let client = await self?.connect(urlHint: urlHint) else { return }
            _ = try? await client.send("Emulation.setCPUThrottlingRate",
                                       ["rate": Double(throttle.rawValue)])
        }
    }

    /// Everything back to this Mac's own, and the socket closed — the bar has been shut.
    func clear() {
        enqueue { [weak self] in
            guard let self, let client = self.client else { return }
            _ = try? await client.send("Emulation.clearDeviceMetricsOverride", [:], timeout: 5)
            _ = try? await client.send("Emulation.setCPUThrottlingRate", ["rate": 1.0], timeout: 5)
            _ = try? await client.send("Network.emulateNetworkConditions", [
                "offline": false, "latency": 0,
                "downloadThroughput": -1, "uploadThroughput": -1,
            ], timeout: 5)
            client.close()
            self.client = nil
        }
    }

    /// One socket serves all three axes; the first of them to be set opens it.
    private func connect(urlHint: URL?) async -> CDPClient? {
        if client == nil {
            client = try? await CDPClient.attach(port: cdpPort,
                                                 synthSessionID: sessionID,
                                                 urlHint: urlHint)
            if client == nil {
                NSLog("Synth: conditions CDP attach failed for %@ — frame only",
                      sessionID.uuidString)
            }
        }
        return client
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
