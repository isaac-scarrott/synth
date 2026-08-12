import SwiftUI
import AppKit

/// Colours and metrics lifted from working.html's CSS variables. Every colour is
/// appearance-adaptive: a dynamic NSColor resolves to the light or dark value against
/// the view's effective appearance (driven by `.preferredColorScheme`, see RootView).
/// Call sites are unchanged — the whole app themes by editing this one file, exactly
/// like working.html's `:root` / `:root[data-theme="dark"]`.
enum Theme {
    // Surfaces + structure. The ramp is the app icon's own squircle gradient, read in the same
    // direction: `raised` is its top stop (#282B30), `sidebar` its middle, `panel` its bottom.
    // The charcoal is not neutral — it holds hue ~223° at ~10% saturation. The step past that
    // bottom used to be `canvas`, an opaque fill behind the whole shell; the window's material
    // stands where it did, so the desktop itself is now the last stop on the ramp.
    static let panel       = dyn(0xFAFBFC, 0x191B1F)   // content surface
    static let sidebar     = dyn(0xF0F1F4, 0x1D1F24)   // rails in ⌘? + changelog (the sidebar itself is bare coat)

    /// Translucency. The window's one translucent coat, over `WindowBlur`'s blurred desktop
    /// (`--panel` on working.html's `.app`). The blur only samples what sits behind the *window*, so
    /// this is the only translucent surface in the shell: everything that differs from it is a tint
    /// *on* it, never a second coat. Two coats compound to near-opaque, so the desktop would show
    /// through the pane but not the sidebar, and the sidebar's rounded corners would cut a hole
    /// clean through to the wallpaper.
    ///
    /// The 0.11 between the themes is not a rounding choice, it is the point. The same amount of
    /// wallpaper light lands completely differently depending on what it lands on: against light's
    /// 250 it is a ~3% change and nearly invisible, against dark's 25 it is a ~28% *lift* and the
    /// surface goes milky. Equal effect, wildly unequal alpha — and the earlier near-equal pair read
    /// as too transparent in dark and too flat in light at the same time.
    ///
    /// Solid when `WindowBlur` can't blur the desktop: translucency is an enhancement, and a
    /// translucent shell over a *sharp* wallpaper is worse than an opaque one.
    static let windowCoat = WindowBlur.isAvailable ? dyn(0xFAFBFC, 0.86, 0x191B1F, 0.97)
                                                  : dyn(0xFAFBFC, 0x191B1F)
    static let raised      = dyn(0xFFFFFF, 0x282B30)   // raised fills: menus, pills, fields
    static let border      = mono(0.07, 0.09)          // hairline (black→white overlay)
    static let borderStrong = mono(0.10, 0.13)
    static let rowHover    = mono(0.035, 0.05)
    static let rowSelected = mono(0.05, 0.08)
    static let line        = mono(0.10, 0.12)           // control border
    static let selRing     = accent.opacity(0.5)

    // Text tiers
    static let ink          = dyn(0x1C1E23, 0xE6E8ED)   // tier-1 text (unified with repoName primary)
    static let inkMuted     = dyn(0x7E808A, 0x8D9099)
    static let inkFaint     = dyn(0xA6A8B0, 0x666A72)

    // Secondary ink tiers (used inline across menus, palette, settings, shortcuts)
    static let ink2         = dyn(0x44464E, 0xC4C7CF)   // crumbs, shortcut labels, kebab-hover glyph
    static let ink3         = dyn(0x54565E, 0xADB0B9)   // tertiary label (add-bar, About button)
    static let ink4         = dyn(0x666971, 0x979AA3)   // menu confirm label, palette icon
    static let ink5         = dyn(0x787B84, 0x83868F)   // branch / mono label
    static let inkOpen      = dyn(0x2B2D34, 0xDCDEE4)   // open session name
    /// One tier for every faint meta grey. The eight it replaced sat within 5% lightness of each
    /// other — a hierarchy nobody could see — and several failed contrast.
    ///
    /// Light darkened 16 levels when the shell went translucent. At #6B6E76 this tier cleared 4.5
    /// with no margin at all (4.52:1 on the opaque sidebar), so *any* coat put it under — 3.56:1 over
    /// the wallpaper's dark end. Raising the coat could not fix it: the sidebar only clears 4.5 again
    /// at a fully opaque 1.00. So the ink moved instead, which also lifts it to 6.26:1 on the opaque
    /// dialogs and rails that use it. Dark needed nothing: it holds 5.04:1 at the 0.97 coat.
    static let inkMeta      = dyn(0x5B5E66, 0x8D9099)
    static let menuIcon     = dyn(0x7A7A80, 0x979AA3)   // popover item icons
    static let termBg       = dyn(0x191B1F, 0x121317)   // code editor surface (Settings)
    static let chrome       = dyn(0xF2F3F6, 0x22252B)   // browser toolbar (--chrome)
    /// The terminal card's own fill has no token here on purpose: ghostty paints it, colour *and*
    /// alpha, from `TerminalTheme` — see `TermSurface`. A SwiftUI fill behind the cells was a second
    /// coat over the same card, and a pair of numbers that had to be kept in step by hand.
    ///
    /// This one is the surface where the terminal has to read as raised rather than as window: the
    /// scratch terminal is a card floating over a dimmed app, and a translucent one dissolves into
    /// whatever it is covering.
    static let tuiSolid     = dyn(0xF7F8FA, 0x121317)
    static let tuiHair      = mono(0.13, 0.06)          // terminal card inset hairline
    /// The scratch terminal's scrim — deeper than a dialog's 0.16, because that surface is a
    /// detour out of the app rather than a step within it. Not one number in both themes: the
    /// same 0.5 that reads as a firm shade over a near-black app crushes a light one to flat
    /// grey, taking the sidebar's legibility with it. Equal *effect*, not equal alpha.
    static let scratchScrim = shade(0.34, 0.5)
    static let paletteActive = accent                   // ⌘K active-row label
    /// Frosted popover fill layered over `.ultraThinMaterial` (⌘K / menus).
    static let glass = Color(nsColor: NSColor(name: nil) {
        $0.isDarkAqua ? NSColor(hex: 0x1F2228).withAlphaComponent(0.86)
                      : NSColor(hex: 0xFAFBFD).withAlphaComponent(0.84)
    })

    // Exact per-element greys from working.html
    static let repoName     = dyn(0x1C1E23, 0xE6E8ED)
    static let repoCount    = inkMeta
    static let navLabel     = inkMeta
    static let chevron      = inkMeta
    static let branchName   = ink2                      // inactive branch (parent tier above sessions)
    static let branchMeta   = inkMeta
    static let sessionName  = inkMeta
    static let sessionNameUnread = dyn(0x34363D, 0xECEEF2)
    static let sessionIcon  = inkMeta                   // non-AI

    // State + accent.
    /// The brand accent: the icon's champagne mark in dark. Light can't use it — at 87% lightness
    /// it fails contrast on white — so light takes a copper of the same warm family (4.78:1).
    /// Spent only on focus, selection, the ⌘K active row and the open-session tint.
    static let accent      = dyn(0xA86038, 0xEEE0CD)
    /// The mark's own pair — charcoal on light, champagne on dark (--focus).
    static let focus       = dyn(0x1E2126, 0xEEE0CD)
    /// The app icon's champagne, worn only by the waiting-build foot button — which is why it is
    /// not an accent: the accents mean states, this means Synth itself. Like `accent` it flips per
    /// theme rather than holding one hex — the mark on dark, and on light the same hue taken down
    /// far enough to read on a near-white panel (5.2:1), because a pale champagne tint over a pale
    /// panel is no tint at all and light's bronze goes olive on the dark sidebar (--update-ink).
    static let updateInk   = dyn(0x7F6130, 0xEEE0CD)
    /// The wash and its hairline both take their opacities off this (--update-rgb). Dark restores
    /// the mark's chroma to do it: #EEE0CD's own low saturation reads grey at 13% alpha. The glyph
    /// above stays the mark itself, which is why these two are not one token.
    static let updateWash  = dyn(0x7F6130, 0xECCE9B)
    static let run         = Color(hex: 0x34C759)   // green liveness
    static let working     = Color(hex: 0xF5A623)   // amber (working) — 4° off champagne, so it
                                                    // stays put and the accent keeps clear of it
    /// Liveness (running / working), working.html `--live-lift` → `--live-deep`: the two ends of
    /// the sphere's ramp, near face to rim. Violet is the one hue no other right-side indicator
    /// claims — the needs-input ? is slate-blue and the error ! is red, and the old cyan sat
    /// close enough to that blue to be mistaken for it at 14px.
    static let liveLift    = dyn(0xC4B5FD, 0xEDE9FE)
    static let liveDeep    = dyn(0x4C1D95, 0x6D28D9)
    /// Needs-input state only: a desaturated sibling of the charcoal's own 223° hue. Never brand.
    static let input       = dyn(0x3A6DB3, 0x7EA6DC)
    static let danger      = Color(hex: 0xFF3B30)   // error (!)
    static let copper      = dyn(0xA05633, 0xC2724C)   // the AI mark (session__icon--ai, ind--owned)

    /// PR states — GitHub's own hues, tuned per theme (working.html `--pr-*`). Identity, not
    /// brand: they only ever colour a branch's pull-request glyph and header chip.
    static let prOpen      = dyn(0x1A7F37, 0x57AB5A)
    static let prMerged    = dyn(0x8250DF, 0xB083F0)
    static let prClosed    = dyn(0xCF222E, 0xE5534B)
    static let prQueued    = dyn(0x0969DA, 0x4493F8)   // in the merge queue — waiting, not yet merged

    /// Identity, not brand: six hues at 34% saturation, each ≥15° from every reserved colour and
    /// ≥27° from each other, all clearing 4.6:1 for their white letter.
    static let chipColors: [Color] = [
        Color(hex: 0x7569B5), Color(hex: 0x477B90), Color(hex: 0x7B773D),
        Color(hex: 0x3E7E74), Color(hex: 0xAD587F), Color(hex: 0xA158AD),
    ]

    static let sidebarWidth: CGFloat = 260
    static let sidebarMinWidth: CGFloat = 200
    static let sidebarMaxWidth: CGFloat = 460
    /// The titlebar band — working.html's `--titlebar-h`. The sidebar's top strip and every
    /// pane header are exactly this tall, so the traffic lights, the sidebar toggle, the pane
    /// title and the DEV tag all share one centre line across the sidebar/content boundary.
    static let titlebarHeight: CGFloat = 50
    /// Tabs mode's top row — working.html `.tabstrip { height: 36px }`: the 32pt split tray
    /// plus 2pt. In tabs mode the whole top row (toggle band, traffic lights, DEV tag) drops
    /// to this height so everything shares the strip's centre line.
    static let tabStripHeight: CGFloat = 36
    /// Traffic lights (working.html `.traffic`): 12pt circles, 20pt from the leading edge,
    /// 20pt pitch, centred in the band. WindowChrome puts AppKit's real buttons here.
    static let trafficLightInset: CGFloat = 20
    static let trafficLightPitch: CGFloat = 20
    /// Where a collapsed pane header starts: the lights end at 72pt, then the mock's 10pt gap.
    static let trafficLightsClearance: CGFloat = 82
    static let radiusApp: CGFloat = 14
    static let radiusPanel: CGFloat = 20
    static let cardInset: CGFloat = 12

    /// A colour that resolves light/dark against the effective appearance.
    static func dyn(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { $0.isDarkAqua ? NSColor(hex: dark) : NSColor(hex: light) })
    }
    /// The same, each theme carrying its own alpha — for the translucent surfaces, where the two
    /// appearances disagree about how much wallpaper they can afford.
    static func dyn(_ light: UInt32, _ lightAlpha: Double, _ dark: UInt32, _ darkAlpha: Double) -> Color {
        Color(nsColor: NSColor(name: nil) {
            $0.isDarkAqua ? NSColor(hex: dark).withAlphaComponent(darkAlpha)
                          : NSColor(hex: light).withAlphaComponent(lightAlpha)
        })
    }
    /// A black overlay in both themes, at its own alpha in each — for scrims, where inverting to
    /// white (as `mono` does) would lighten rather than dim.
    static func shade(_ lightAlpha: Double, _ darkAlpha: Double) -> Color {
        Color(nsColor: NSColor(name: nil) {
            NSColor(white: 0, alpha: $0.isDarkAqua ? darkAlpha : lightAlpha)
        })
    }
    /// A black overlay in light, inverted to a white overlay in dark (hovers, borders, dividers).
    static func mono(_ lightAlpha: Double, _ darkAlpha: Double) -> Color {
        Color(nsColor: NSColor(name: nil) {
            $0.isDarkAqua ? NSColor(white: 1, alpha: darkAlpha) : NSColor(white: 0, alpha: lightAlpha)
        })
    }
}

extension NSAppearance {
    var isDarkAqua: Bool { bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red:   Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue:  Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: Double((hex >> 16) & 0xFF) / 255,
            green:   Double((hex >> 8) & 0xFF) / 255,
            blue:    Double(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

extension PRState {
    /// The state's colour (working.html `.pr--open/merged/closed`).
    var tint: Color {
        switch self {
        case .open: return Theme.prOpen
        case .merged: return Theme.prMerged
        case .closed: return Theme.prClosed
        case .queued: return Theme.prQueued
        }
    }
    /// A merged PR wears the merge glyph; open, closed and queued all wear pull-request (the
    /// colour tells them apart), matching working.html.
    var glyph: String { self == .merged ? Phosphor.gitMerge : Phosphor.gitPullRequest }
}

extension SessionKind {
    /// The monochrome glyph a kind falls back to. Agents normally render their own mark
    /// (`SessionIcon` / AgentMarks.swift); the sparkle stands in for one Synth has no artwork
    /// for, so a third agent looks reasonable before anyone draws it.
    var iconPath: String {
        switch self {
        case .terminal: return Phosphor.terminal
        case .agent:    return Phosphor.sparkle
        case .browser:  return Phosphor.globe
        case .simulator: return Phosphor.deviceMobile
        case .markdown: return Phosphor.fileText
        }
    }
    var tint: Color {
        switch self {
        case .agent: return Theme.copper
        // A document is content the user owns, not a live thing Synth is running, so it wears
        // the same quiet ink as a terminal rather than the agent's copper.
        case .terminal, .browser, .simulator, .markdown: return Theme.sessionIcon
        }
    }
}
