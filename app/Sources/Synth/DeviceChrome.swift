import AppKit
import SwiftUI

// The device a screen is shown on (working.html `.dev` / `.devui__*`), in two halves that
// the mock already splits: `DeviceFrame` is the hardware around the glass, and what goes
// on the glass is handed in. For an emulated page that content is `BrowserDeviceScreen` —
// the software the device itself draws, status bar, its own browser's bars, home indicator
// — with the live page taking what those leave, which is the point: a page handed the whole
// 393 × 852 passes layouts no iPhone ever gives that room. For a booted simulator it is the
// live framebuffer and nothing else, because iOS paints all of that into the frames itself.
//
// Every metric is a device point multiplied by the stage's fit scale, so the frame draws
// crisp at any fit instead of rasterising through a scaleEffect.

/// The palette the *device* draws in — deliberately fixed in both themes. A phone on the
/// desk doesn't follow the Mac's appearance, and tinting it would claim something about
/// the page that isn't true.
private enum DeviceInk {
    static let frame = Color(hex: 0x08090B)
    static let cutout = Color.black
    static let rail = Color.white.opacity(0.22)
    static let button = Color(hex: 0x32363C)
    static let glass = Color.white
    static let ink = Color(hex: 0x0B0C0E)
    static let bar = Color(hex: 0xF6F6F8)
    static let pill = Color(hex: 0xE4E4E7)
    static let hairline = Color.black.opacity(0.14)
    static let tint = Color(hex: 0x0A84FF)
    static let dim = Color.black.opacity(0.26)
    static let home = Color.black.opacity(0.82)
    static let padBar = Color(hex: 0xF4F4F6)
    static let androidPill = Color(hex: 0xF1F3F4)
    static let androidInk = Color(hex: 0x3C4043)
    static let androidGrey = Color(hex: 0x5F6368)
    static let androidHome = Color(hex: 0x1F1F1F)
}

/// The status bar's cellular / wifi / battery, as whole SVG (they aren't square and
/// Phosphor has no equivalent). Template-tinted, so the drawn opacities survive as alpha.
private enum StatusGlyph {
    static let cellular = "<svg viewBox=\"0 0 20 12\" xmlns=\"http://www.w3.org/2000/svg\" fill=\"#000\"><rect y=\"8\" width=\"3\" height=\"4\" rx=\"1\"/><rect x=\"4.7\" y=\"5.6\" width=\"3\" height=\"6.4\" rx=\"1\"/><rect x=\"9.4\" y=\"3.2\" width=\"3\" height=\"8.8\" rx=\"1\"/><rect x=\"14.1\" y=\"0.8\" width=\"3\" height=\"11.2\" rx=\"1\"/></svg>"
    static let wifi = "<svg viewBox=\"0 0 16 12\" xmlns=\"http://www.w3.org/2000/svg\" fill=\"#000\"><path d=\"M8,11.6,5.5,8.9a3.6,3.6,0,0,1,5,0Zm-3.9-4.2a6.4,6.4,0,0,1,7.8,0l1.5-1.6a8.6,8.6,0,0,0-10.8,0ZM1.1,4.1a10.7,10.7,0,0,1,13.8,0L16,2.5a12.8,12.8,0,0,0-16,0Z\"/></svg>"
    static let battery = "<svg viewBox=\"0 0 27 12\" xmlns=\"http://www.w3.org/2000/svg\" fill=\"none\"><rect x=\"0.6\" y=\"0.6\" width=\"22\" height=\"10.8\" rx=\"3.2\" stroke=\"#000\" stroke-opacity=\"0.38\" stroke-width=\"1.2\"/><rect x=\"2.2\" y=\"2.2\" width=\"18.8\" height=\"7.6\" rx=\"2\" fill=\"#000\"/><path d=\"M24.6,4.3v3.4a2,2,0,0,0,0-3.4Z\" fill=\"#000\" fill-opacity=\"0.38\"/></svg>"
}

/// A non-square glyph given as whole SVG markup, tinted like any template image.
private struct StatusIcon: View {
    let svg: String
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        Image(nsImage: PhosCache.shared.image(svg: svg))
            .resizable()
            .renderingMode(.template)
            .interpolation(.high)
            .frame(width: width, height: height)
    }
}

// MARK: - Frame

/// working.html `deviceHTML(d, land, screenHTML)`: the hardware around the screen — bezel
/// per edge, the cutout the display is punched around, and the side buttons standing proud
/// of the rail — with whatever goes on the glass handed in.
///
/// It draws only what the hardware has and the screen cannot: body, bezel, cutout shape,
/// buttons, radii, shadow. Anything a screen paints for itself belongs in the content, so
/// one frame serves an emulated page (whose device software we draw) and a live simulator
/// (whose iOS draws its own) without either doubling the other's chrome.
struct DeviceFrame<Screen: View>: View {
    let device: HardwareDevice
    let landscape: Bool
    /// The stage's fit scale.
    let s: CGFloat
    /// What sits on the glass, laid out at the screen's full size.
    @ViewBuilder let screen: Screen

    var body: some View {
        let bez = device.bezels(landscape: landscape)
        let glass = device.screenSize(landscape: landscape)
        let frameSize = CGSize(width: (glass.width + bez.leading + bez.trailing) * s,
                               height: (glass.height + bez.top + bez.bottom) * s)
        screen
            .frame(width: glass.width * s, height: glass.height * s)
            .background(DeviceInk.glass)
            .clipShape(RoundedRectangle(cornerRadius: device.screenRadius * s,
                                        style: .continuous))
            .overlay(alignment: landscape ? .leading : .top) { cutout }
            .padding(.top, bez.top * s)
            .padding(.trailing, bez.trailing * s)
            .padding(.bottom, bez.bottom * s)
            .padding(.leading, bez.leading * s)
            .background(RoundedRectangle(cornerRadius: device.frameRadius * s,
                                         style: .continuous).fill(DeviceInk.frame))
            .overlay(RoundedRectangle(cornerRadius: device.frameRadius * s,
                                      style: .continuous)
                .strokeBorder(DeviceInk.rail, lineWidth: 1))
            .overlay { bezelHardware(bez: bez) }
            .overlay { DeviceSideButtons(device: device, landscape: landscape,
                                         s: s, frameSize: frameSize) }
            .shadow(color: .black.opacity(0.30), radius: 22 * s, y: 16 * s)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Cutout

    @ViewBuilder private var cutout: some View {
        switch device.face {
        case .island:
            island.padding(landscape ? .leading : .top, 11 * s)
        case .punch:
            lens(diameter: 12 * s)
                .padding(landscape ? .leading : .top, 13 * s)
        case .homeButton, .cameraTop, .cameraSide:
            EmptyView()
        }
    }

    private var island: some View {
        Capsule()
            .fill(DeviceInk.cutout)
            .frame(width: (landscape ? 37 : 125) * s, height: (landscape ? 125 : 37) * s)
            .overlay(alignment: landscape ? .top : .trailing) {
                lens(diameter: 15 * s).padding(landscape ? .top : .trailing, 9 * s)
            }
    }

    /// A lens is a well with one highlight, never a flat dot.
    private func lens(diameter: CGFloat) -> some View {
        Circle()
            .fill(RadialGradient(colors: [Color(hex: 0x2B4462), Color(hex: 0x05070A)],
                                 center: UnitPoint(x: 0.34, y: 0.30),
                                 startRadius: 0, endRadius: diameter * 0.72))
            .frame(width: diameter, height: diameter)
    }

    // MARK: Bezel hardware

    /// The earpiece, front camera and home button a device carries in the bezel itself.
    @ViewBuilder private func bezelHardware(bez: HardwareDevice.Bezel) -> some View {
        switch device.face {
        case .homeButton:
            ZStack {
                bezelItem(band: landscape ? .leading : .top, bez: bez) { speaker }
                bezelItem(band: landscape ? .leading : .top, bez: bez, along: -52 * s) {
                    lens(diameter: 9 * s)
                }
                bezelItem(band: landscape ? .trailing : .bottom, bez: bez) { homeButton }
            }
        case .cameraTop:
            bezelItem(band: landscape ? .leading : .top, bez: bez) { lens(diameter: 9 * s) }
        case .cameraSide:
            // The landscape camera lives on the long edge — the left one in portrait.
            bezelItem(band: landscape ? .top : .leading, bez: bez) { lens(diameter: 9 * s) }
        case .island, .punch:
            EmptyView()
        }
    }

    private enum BezelBand { case top, bottom, leading, trailing }

    /// Centres a piece of hardware in one bezel band, optionally slid along it.
    @ViewBuilder private func bezelItem<Content: View>(
        band: BezelBand, bez: HardwareDevice.Bezel, along: CGFloat = 0,
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        let thickness: CGFloat = {
            switch band {
            case .top: return bez.top
            case .bottom: return bez.bottom
            case .leading: return bez.leading
            case .trailing: return bez.trailing
            }
        }()
        let vertical = band == .top || band == .bottom
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity,
                   alignment: alignment(for: band))
            .padding(.top, band == .top ? thickness * s / 2 : 0)
            .padding(.bottom, band == .bottom ? thickness * s / 2 : 0)
            .padding(.leading, band == .leading ? thickness * s / 2 : 0)
            .padding(.trailing, band == .trailing ? thickness * s / 2 : 0)
            .offset(x: vertical ? along : 0, y: vertical ? 0 : along)
    }

    private func alignment(for band: BezelBand) -> Alignment {
        switch band {
        case .top: return .top
        case .bottom: return .bottom
        case .leading: return .leading
        case .trailing: return .trailing
        }
    }

    private var speaker: some View {
        Capsule()
            .fill(Color(hex: 0x16181C))
            .frame(width: (landscape ? 6 : 62) * s, height: (landscape ? 62 : 6) * s)
    }

    private var homeButton: some View {
        Circle()
            .fill(Color(hex: 0x0B0D10))
            .frame(width: 46 * s, height: 46 * s)
            .overlay(Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 1.5 * s))
    }
}

// MARK: - Side buttons

/// The rail's own hardware. Positions are fractions of the device's long axis; rotating
/// counter-clockwise walks each button one edge round — the trailing edge (power) becomes
/// the top one, the leading edge (volume) the bottom.
private struct DeviceSideButtons: View {
    let device: HardwareDevice
    let landscape: Bool
    let s: CGFloat
    let frameSize: CGSize

    private enum Edge { case leading, trailing, top, bottom }

    private struct Rail: Identifiable {
        let id: String
        let edge: Edge
        let start: CGFloat
        let length: CGFloat
    }

    private var rails: [Rail] {
        switch device.face {
        case .island:
            return [Rail(id: "act", edge: .leading, start: 0.150, length: 0.030),
                    Rail(id: "vup", edge: .leading, start: 0.205, length: 0.044),
                    Rail(id: "vdn", edge: .leading, start: 0.264, length: 0.044),
                    Rail(id: "pwr", edge: .trailing, start: 0.235, length: 0.080)]
        case .homeButton:
            return [Rail(id: "vup", edge: .leading, start: 0.205, length: 0.044),
                    Rail(id: "vdn", edge: .leading, start: 0.264, length: 0.044),
                    Rail(id: "pwr", edge: .trailing, start: 0.235, length: 0.080)]
        case .punch:
            return [Rail(id: "vup", edge: .trailing, start: 0.210, length: 0.044),
                    Rail(id: "vdn", edge: .trailing, start: 0.270, length: 0.044),
                    Rail(id: "pwr", edge: .trailing, start: 0.335, length: 0.060)]
        case .cameraTop, .cameraSide:
            return [Rail(id: "pwr", edge: .top, start: 0.680, length: 0.090),
                    Rail(id: "vup", edge: .trailing, start: 0.050, length: 0.034),
                    Rail(id: "vdn", edge: .trailing, start: 0.094, length: 0.034)]
        }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            ForEach(rails) { rail in button(rail) }
        }
    }

    @ViewBuilder private func button(_ rail: Rail) -> some View {
        let placed = place(rail)
        let thickness = 3 * s
        let vertical = placed.edge == .leading || placed.edge == .trailing
        let length = placed.length * (vertical ? frameSize.height : frameSize.width)
        let along = placed.start * (vertical ? frameSize.height : frameSize.width)
        RoundedRectangle(cornerRadius: 1.5 * s)
            .fill(DeviceInk.button)
            .frame(width: vertical ? thickness : length,
                   height: vertical ? length : thickness)
            .offset(x: {
                switch placed.edge {
                case .leading: return -thickness * 0.6
                case .trailing: return frameSize.width - thickness * 0.4
                case .top, .bottom: return along
                }
            }(), y: {
                switch placed.edge {
                case .top: return -thickness * 0.6
                case .bottom: return frameSize.height - thickness * 0.4
                case .leading, .trailing: return along
                }
            }())
    }

    /// The same button after the quarter turn: edges walk round, and a button measured
    /// along a horizontal edge flips, since that edge's start becomes the far end.
    private func place(_ rail: Rail) -> (edge: Edge, start: CGFloat, length: CGFloat) {
        guard landscape else { return (rail.edge, rail.start, rail.length) }
        switch rail.edge {
        case .leading: return (.bottom, rail.start, rail.length)
        case .trailing: return (.top, rail.start, rail.length)
        case .top: return (.leading, 1 - rail.start - rail.length, rail.length)
        case .bottom: return (.trailing, 1 - rail.start - rail.length, rail.length)
        }
    }
}

// MARK: - The browser's screen

/// working.html `deviceScreenHTML(d, land, host)`: what the *device's own software* puts on
/// the glass when the screen is showing an emulated page — its status bar, its browser's
/// bars, its home indicator — with the live page taking the room those leave. It is a
/// screen's content, not hardware, which is why it is a separate view from `DeviceFrame`:
/// a simulator's iOS draws all of this itself and must not get ours on top.
struct BrowserDeviceScreen: View {
    let device: HardwareDevice
    let landscape: Bool
    /// What the device's own address bar shows.
    let host: String
    /// The stage's fit scale — the same one the frame is drawn at.
    let s: CGFloat
    let engineView: NSView

    var body: some View {
        let page = device.pageViewport(landscape: landscape)
        VStack(spacing: 0) {
            if showsStatusBar { DeviceStatusBar(device: device, s: s) }
            topBar
            DeviceScreenHost(view: engineView)
                .frame(height: page.height * s)
            bottomBar
            if standaloneHomeIndicator {
                DeviceHomeIndicator(device: device, s: s)
            }
        }
    }

    /// Landscape iPhone drops the status bar — the reason a page gets height back there.
    private var showsStatusBar: Bool {
        !(device.onScreen == .safariPhone && landscape)
    }

    @ViewBuilder private var topBar: some View {
        switch device.onScreen {
        case .safariPad:
            SafariPadBar(host: host, s: s)
        case .chromeAndroid:
            ChromeAndroidBar(host: host, s: s)
        case .safariPhone:
            if landscape { SafariPhoneTopBar(device: device, host: host, s: s) }
        }
    }

    @ViewBuilder private var bottomBar: some View {
        if device.onScreen == .safariPhone, !landscape {
            SafariPhoneBottomBar(device: device, host: host, s: s)
        }
    }

    /// Portrait Safari draws the indicator on its own bar; everywhere else it rides over
    /// the page.
    private var standaloneHomeIndicator: Bool {
        device.homeIndicatorHeight > 0 && !(device.onScreen == .safariPhone && !landscape)
    }
}

/// An AppKit view pinned to fill its slice of the glass — the browser engine on a page, a
/// simulator's framebuffer layer on a live device. The corners are the frame's clip, not a
/// radius here: content rarely reaches them, since the device's own bars usually do.
struct DeviceScreenHost: NSViewRepresentable {
    let view: NSView

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.masksToBounds = true
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - Status bar

/// working.html `.devui__status`: the time, then the cellular / wifi / battery trio,
/// parting around the island rather than running under it.
private struct DeviceStatusBar: View {
    let device: HardwareDevice
    let s: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            Text(verbatim: "9:41")
                .font(.system(size: (device.isTablet ? 13 : 15) * s,
                              weight: device.onScreen == .chromeAndroid ? .medium : .semibold))
            Spacer(minLength: 4 * s)
            HStack(spacing: 5 * s) {
                StatusIcon(svg: StatusGlyph.cellular, width: 11 * s * 20 / 12, height: 11 * s)
                StatusIcon(svg: StatusGlyph.wifi, width: 11 * s * 16 / 12, height: 11 * s)
                StatusIcon(svg: StatusGlyph.battery, width: 12 * s * 27 / 12, height: 12 * s)
            }
        }
        .foregroundStyle(DeviceInk.ink)
        .padding(.top, device.statusBarTopInset * s)
        .padding(.leading, device.statusBarLeading * s)
        .padding(.trailing, device.statusBarTrailing * s)
        .frame(height: device.statusBarHeight * s)
    }
}

/// working.html `.devui__home`: software, so it rides over whatever is beneath it.
private struct DeviceHomeIndicator: View {
    let device: HardwareDevice
    let s: CGFloat

    var body: some View {
        GeometryReader { geo in
            let android = device.onScreen == .chromeAndroid
            Capsule()
                .fill(android ? DeviceInk.androidHome : DeviceInk.home)
                .frame(width: min(geo.size.width * (android ? 0.34 : 0.36), 150 * s),
                       height: (android ? 4 : 5) * s)
                .frame(width: geo.size.width, height: geo.size.height)
                .opacity(device.drawsHomeIndicator ? 1 : 0)
        }
        .frame(height: device.homeIndicatorHeight * s)
    }
}

// MARK: - The device's browser

/// The address pill iOS Safari shows: text size control, the host, reload.
private struct SafariPill: View {
    let host: String
    let s: CGFloat

    var body: some View {
        HStack(spacing: 8 * s) {
            (Text(verbatim: "A").font(.system(size: 12 * s, weight: .semibold))
                + Text(verbatim: "A").font(.system(size: 15 * s, weight: .semibold)))
                .foregroundStyle(Color(hex: 0x5C5C61))
            HStack(spacing: 4 * s) {
                Phos(path: Phosphor.lock, size: 11 * s).foregroundStyle(DeviceInk.ink.opacity(0.45))
                Text(host)
                    .font(.system(size: 15 * s))
                    .foregroundStyle(DeviceInk.ink)
                    .lineLimit(1).truncationMode(.tail)
            }
            .frame(maxWidth: .infinity)
            Phos(path: Phosphor.reset, size: 16 * s).foregroundStyle(DeviceInk.ink.opacity(0.8))
        }
        .padding(.horizontal, 12 * s)
        .frame(height: DeviceBars.safariPillHeight * s)
        .background(RoundedRectangle(cornerRadius: 12 * s, style: .continuous)
            .fill(DeviceInk.pill))
    }
}

/// `.devui__safari`: portrait iPhone Safari — the tab bar at the bottom, the toolbar under
/// it, the home indicator on the same fill.
private struct SafariPhoneBottomBar: View {
    let device: HardwareDevice
    let host: String
    let s: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            SafariPill(host: host, s: s)
                .padding(.top, DeviceBars.safariPillTopPad * s)
                .padding(.horizontal, 12 * s)
            HStack(spacing: 0) {
                tool(Phosphor.caretLeft, dim: true)
                Spacer(minLength: 0)
                tool(Phosphor.caret, dim: true)
                Spacer(minLength: 0)
                tool(Phosphor.export, dim: false)
                Spacer(minLength: 0)
                tool(Phosphor.bookmark, dim: false)
                Spacer(minLength: 0)
                tool(Phosphor.copy, dim: false)
            }
            .padding(.top, DeviceBars.safariToolsTopPad * s)
            .padding(.horizontal, 16 * s)
            .frame(height: (DeviceBars.safariToolsTopPad + DeviceBars.safariToolsHeight) * s,
                   alignment: .top)
            DeviceHomeIndicator(device: device, s: s)
        }
        .frame(height: (DeviceBars.safariBottomBar + device.homeIndicatorHeight) * s,
               alignment: .top)
        .background(DeviceInk.bar)
        .overlay(alignment: .top) { Rectangle().fill(DeviceInk.hairline).frame(height: 0.5) }
    }

    private func tool(_ path: String, dim: Bool) -> some View {
        Phos(path: path, size: DeviceBars.safariToolsHeight * s)
            .foregroundStyle(dim ? DeviceInk.dim : DeviceInk.tint)
    }
}

/// `.devui__safari--top`: landscape iPhone folds every control into one top bar, and the
/// island takes an edge, so the bar insets clear of it.
private struct SafariPhoneTopBar: View {
    let device: HardwareDevice
    let host: String
    let s: CGFloat

    var body: some View {
        HStack(spacing: 14 * s) {
            Phos(path: Phosphor.caretLeft, size: 22 * s).foregroundStyle(DeviceInk.dim)
            Phos(path: Phosphor.caret, size: 22 * s).foregroundStyle(DeviceInk.dim)
            SafariPill(host: host, s: s)
            Phos(path: Phosphor.export, size: 22 * s).foregroundStyle(DeviceInk.tint)
            Phos(path: Phosphor.copy, size: 22 * s).foregroundStyle(DeviceInk.tint)
        }
        .padding(.horizontal, (device.face == .island ? 50 : 12) * s)
        .frame(height: DeviceBars.safariTopBar * s)
        .background(DeviceInk.bar)
        .overlay(alignment: .bottom) { Rectangle().fill(DeviceInk.hairline).frame(height: 0.5) }
    }
}

/// `.devui__ipadbar`: iPad Safari keeps its bar on top, with the tab strip under it.
private struct SafariPadBar: View {
    let host: String
    let s: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16 * s) {
                Phos(path: Phosphor.sidebar, size: 20 * s).foregroundStyle(DeviceInk.tint)
                Phos(path: Phosphor.caretLeft, size: 20 * s).foregroundStyle(DeviceInk.dim)
                Phos(path: Phosphor.caret, size: 20 * s).foregroundStyle(DeviceInk.dim)
                padPill
                Phos(path: Phosphor.export, size: 20 * s).foregroundStyle(DeviceInk.tint)
                Phos(path: Phosphor.plus, size: 20 * s).foregroundStyle(DeviceInk.tint)
                Phos(path: Phosphor.copy, size: 20 * s).foregroundStyle(DeviceInk.tint)
            }
            .padding(.top, 8 * s)
            .frame(height: 42 * s, alignment: .center)
            HStack(spacing: 1 * s) {
                tab(host, active: true)
                tab("New Tab", active: false)
                Spacer(minLength: 0)
            }
            .padding(.top, 8 * s)
            .frame(height: 40 * s, alignment: .bottom)
        }
        .padding(.horizontal, 16 * s)
        .frame(height: DeviceBars.padBar * s, alignment: .top)
        .background(DeviceInk.padBar)
        .overlay(alignment: .bottom) { Rectangle().fill(DeviceInk.hairline).frame(height: 0.5) }
    }

    private var padPill: some View {
        HStack(spacing: 8 * s) {
            (Text(verbatim: "A").font(.system(size: 11 * s, weight: .semibold))
                + Text(verbatim: "A").font(.system(size: 14 * s, weight: .semibold)))
                .foregroundStyle(Color(hex: 0x5C5C61))
            HStack(spacing: 4 * s) {
                Phos(path: Phosphor.lock, size: 10 * s).foregroundStyle(DeviceInk.ink.opacity(0.45))
                Text(host).font(.system(size: 14 * s)).foregroundStyle(DeviceInk.ink)
                    .lineLimit(1).truncationMode(.tail)
            }
            .frame(maxWidth: .infinity)
            Phos(path: Phosphor.reset, size: 14 * s).foregroundStyle(DeviceInk.ink.opacity(0.8))
        }
        .padding(.horizontal, 12 * s)
        .frame(height: 34 * s)
        .background(RoundedRectangle(cornerRadius: 10 * s, style: .continuous)
            .fill(DeviceInk.pill))
    }

    private func tab(_ label: String, active: Bool) -> some View {
        HStack(spacing: 6 * s) {
            if active {
                Phos(path: Phosphor.lock, size: 11 * s).foregroundStyle(DeviceInk.ink.opacity(0.45))
            }
            Text(label)
                .font(.system(size: 12.5 * s))
                .foregroundStyle(active ? DeviceInk.ink : DeviceInk.ink.opacity(0.6))
                .lineLimit(1).truncationMode(.tail)
        }
        .padding(.horizontal, 12 * s)
        .frame(maxWidth: 260 * s)
        .frame(height: 32 * s)
        .background(active
            ? AnyView(UnevenRoundedRectangle(topLeadingRadius: 9 * s, topTrailingRadius: 9 * s,
                                             style: .continuous).fill(DeviceInk.glass))
            : AnyView(Color.clear))
    }
}

/// `.devui__achrome`: Chrome for Android — one top bar, tab count and overflow at its end.
private struct ChromeAndroidBar: View {
    let host: String
    let s: CGFloat

    var body: some View {
        HStack(spacing: 12 * s) {
            HStack(spacing: 8 * s) {
                Phos(path: Phosphor.lock, size: 12 * s)
                    .foregroundStyle(DeviceInk.androidInk.opacity(0.5))
                Text(host)
                    .font(.system(size: 13.5 * s))
                    .foregroundStyle(DeviceInk.androidInk)
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14 * s)
            .frame(height: 36 * s)
            .background(Capsule().fill(DeviceInk.androidPill))
            Text(verbatim: "3")
                .font(.system(size: 11 * s, weight: .bold))
                .foregroundStyle(DeviceInk.androidGrey)
                .frame(width: 20 * s, height: 20 * s)
                .overlay(RoundedRectangle(cornerRadius: 5 * s)
                    .strokeBorder(DeviceInk.androidGrey, lineWidth: 2 * s))
            Phos(path: Phosphor.dotsVertical, size: 18 * s)
                .foregroundStyle(DeviceInk.androidGrey)
        }
        .padding(.top, 2 * s)
        .padding(.horizontal, 12 * s)
        .frame(height: DeviceBars.androidBar * s, alignment: .top)
        .background(DeviceInk.glass)
    }
}
