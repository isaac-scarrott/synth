import AppKit
import CoreText
import SwiftUI

/// The type half of the design tokens (Theme.swift owns colour). Geist ships as a single
/// variable TTF per family, so weight is a continuous `wght` axis rather than nine cut faces —
/// which is the whole reason this file exists. working.html leans on 450/550/570 in places
/// (notification titles, settings rows, dialog buttons), and SwiftUI's `Font.Weight` cannot
/// name those: `.medium` is 500 and `.semibold` is 600, so every one of them used to round to
/// the wrong side and the app read either too light or too heavy against the design.
///
/// Call sites therefore pass the CSS number verbatim — `.sans(14, 550)` is `font-size: 14px;
/// font-weight: 550` — and the axis does the rest.
enum Typography {
    static let sansFamily = "Geist"
    static let monoFamily = "Geist Mono"

    /// OpenType 'wght' as a big-endian four-char code, which is how CoreText keys variation axes.
    private static let wghtAxis = 0x77676874 as CFNumber

    /// Registering process-scoped means the families resolve for CoreText, AppKit and SwiftUI
    /// alike without touching Info.plist — ATSApplicationFontsPath would have to point inside
    /// the nested SwiftPM resource bundle, which is a path we'd rather not depend on.
    ///
    /// Every accessor below reads this, so the first font built performs registration and
    /// nothing has to be sequenced from the app's init. Looked up by hand rather than
    /// `Bundle.module` (which fatalErrors when the dev bundle misses the copy), mirroring
    /// CommentMode's overlay lookup; a miss falls back to the system face rather than trapping,
    /// so a stale bundle costs the app its typeface and not its launch.
    static let available: Bool = {
        var roots: [URL] = []
        if let r = Bundle.main.resourceURL { roots.append(r.appendingPathComponent("Synth_Synth.bundle")) }
        if let e = Bundle.main.executableURL?.deletingLastPathComponent() {
            roots.append(e.appendingPathComponent("Synth_Synth.bundle"))
        }
        for root in roots {
            guard let bundle = Bundle(url: root) else { continue }
            let urls = ["Geist-Variable", "GeistMono-Variable"].compactMap {
                bundle.url(forResource: $0, withExtension: "ttf", subdirectory: "Fonts")
            }
            guard urls.count == 2 else { continue }
            CTFontManagerRegisterFontURLs(urls as CFArray, .process, false, nil)
            // Asserted against the family list rather than a return code: the registration call
            // reports completion through a handler, and what actually matters here is whether
            // CoreText can now resolve both families.
            let families = Set(NSFontManager.shared.availableFontFamilies)
            if families.contains(sansFamily), families.contains(monoFamily) { return true }
        }
        NSLog("Synth: Geist font resources missing — falling back to the system face")
        return false
    }()

    static func nsFont(_ family: String, _ size: CGFloat, _ weight: Double, tabular: Bool = false) -> NSFont {
        guard available else {
            let fallback: NSFont = family == monoFamily
                ? .monospacedSystemFont(ofSize: size, weight: systemWeight(weight))
                : (tabular
                    ? .monospacedDigitSystemFont(ofSize: size, weight: systemWeight(weight))
                    : .systemFont(ofSize: size, weight: systemWeight(weight)))
            return fallback
        }
        var attributes: [CFString: Any] = [
            kCTFontFamilyNameAttribute: family as CFString,
            kCTFontVariationAttribute: [wghtAxis: weight] as CFDictionary,
        ]
        if tabular {
            attributes[kCTFontFeatureSettingsAttribute] = [[
                kCTFontFeatureTypeIdentifierKey: kNumberSpacingType,
                kCTFontFeatureSelectorIdentifierKey: kMonospacedNumbersSelector,
            ]] as CFArray
        }
        let descriptor = CTFontDescriptorCreateWithAttributes(attributes as CFDictionary)
        return CTFontCreateWithFontDescriptor(descriptor, size, nil) as NSFont
    }

    /// Only reached when registration failed, so it trades exactness for the nearest cut the
    /// system face actually has — 550 lands on `.medium` rather than inventing a weight.
    private static func systemWeight(_ weight: Double) -> NSFont.Weight {
        switch weight {
        case ..<250: .ultraLight
        case ..<350: .light
        case ..<450: .regular
        case ..<560: .medium
        case ..<650: .semibold
        case ..<750: .bold
        default: .heavy
        }
    }
}

extension Font {
    /// Geist, the app's UI face — `--font` in working.html.
    ///
    /// `tabular` is not cosmetic: Geist's default figures are proportional, and by a wide margin
    /// ('111' sets barely half the width of '000'), so anything that counts or ticks — session
    /// counts, timestamps, dimensions — jitters without it. It stands in for the design's
    /// `font-variant-numeric: tabular-nums`, and replaces `.monospacedDigit()`, which only knows
    /// how to ask the *system* face for tabular figures.
    static func sans(_ size: CGFloat, _ weight: Double = 400, tabular: Bool = false) -> Font {
        Font(Typography.nsFont(Typography.sansFamily, size, weight, tabular: tabular))
    }

    /// Geist Mono — `--mono`: paths, branches, URLs, key caps, anything you typed.
    /// Already fixed-advance, so it takes no `tabular` knob.
    static func mono(_ size: CGFloat, _ weight: Double = 400) -> Font {
        Font(Typography.nsFont(Typography.monoFamily, size, weight))
    }
}

extension NSFont {
    /// For the AppKit islands (NSTextField/NSTextView) that can't take a SwiftUI `Font`.
    static func sans(_ size: CGFloat, _ weight: Double = 400, tabular: Bool = false) -> NSFont {
        Typography.nsFont(Typography.sansFamily, size, weight, tabular: tabular)
    }

    static func mono(_ size: CGFloat, _ weight: Double = 400) -> NSFont {
        Typography.nsFont(Typography.monoFamily, size, weight)
    }
}
