import { SyntaxStyle, type StyleDefinitionInput } from "@opentui/core"

/// The palette synth-md draws with, and how it arrives.
///
/// The app hands the whole thing over as one JSON blob in `SYNTH_MD_PALETTE`, built from
/// Theme.swift, plus `SYNTH_MD_APPEARANCE` for light/dark — the same launch-env mechanism
/// agent sessions already use for their flags. Everything here also has a built-in default
/// for both appearances, because `synth <file>` runs this TUI in ANY terminal, with no Synth
/// app on the other end to describe itself.
///
/// Nothing paints an opaque page background. The ghostty surface underneath is already
/// painting Synth's translucent card (TerminalTheme's `background-opacity`), so a filled
/// backdrop here would be a second coat and the window would stop reading as one surface.

export interface Palette {
  fg: string
  muted: string
  faint: string
  accent: string
  heading: string
  link: string
  code: string
  codeBg: string
  quote: string
  rule: string
  selection: string
  cursor: string
  match: string
  matchCurrent: string
  /// The revealed block's own tint — the one place the editor admits it is an editor.
  revealBg: string
  /// Solid fill for the outline overlay. Must be OPAQUE: every other surface here is
  /// deliberately transparent so ghostty's translucent card shows through, but a floating
  /// palette that lets the document through composites the two into unreadable soup.
  overlayBg: string
  danger: string
}

/// Light is not dark-with-swapped-ends. Its greys are pulled well down (a mid grey reads far
/// nearer white than black), and its accent is the copper Theme.swift falls back to because
/// the champagne mark fails contrast on a near-white panel.
const DEFAULTS: Record<"light" | "dark", Palette> = {
  dark: {
    fg: "#E6E8ED",
    muted: "#8D9099",
    faint: "#666A72",
    accent: "#EEE0CD",
    heading: "#F2F4F8",
    link: "#8AB4F8",
    code: "#D8DEE9",
    codeBg: "#FFFFFF0D",
    quote: "#A9ADB6",
    rule: "#3A3D45",
    selection: "#33507A",
    cursor: "#EEE0CD",
    match: "#5B4A2A",
    matchCurrent: "#A86038",
    revealBg: "#FFFFFF08",
    overlayBg: "#22252B",
    danger: "#E5534B",
  },
  light: {
    fg: "#1C1E23",
    muted: "#5B5E66",
    faint: "#8A8D95",
    accent: "#A86038",
    heading: "#12141A",
    link: "#194EB7",
    code: "#2B2D34",
    codeBg: "#0000000A",
    quote: "#54565E",
    rule: "#C9CCD3",
    selection: "#D0D9E6",
    cursor: "#1C1E23",
    match: "#F3E2B8",
    matchCurrent: "#E8B45E",
    revealBg: "#00000008",
    overlayBg: "#FFFFFF",
    danger: "#A2241A",
  },
}

/// The two scope names search highlighting paints with. Highlights address a style by id
/// rather than by colour, so the search styles have to be part of the same table as
/// everything else and their ids resolved once at build time.
export const MATCH_SCOPE = "synth.search.match"
export const MATCH_CURRENT_SCOPE = "synth.search.current"

export interface Theme {
  appearance: "light" | "dark"
  palette: Palette
  /// Styles for markdown structure and for tree-sitter scopes inside fences. One
  /// SyntaxStyle serves both because MarkdownRenderable resolves markup and code scopes
  /// against the same table.
  syntax: SyntaxStyle
  /// Resolved ids for the two search scopes, ready to hand to `addHighlightByCharRange`.
  matchStyleId: number
  matchCurrentStyleId: number
}

/// Build the theme for one appearance.
///
/// Both appearances are read, not just the current one: ghostty announces a light/dark flip to
/// the running program (DEC 2031) and OpenTUI surfaces it as `theme_mode`, so the TUI re-themes
/// in place when Synth's appearance changes. The env carries a palette for each — a launch-time
/// snapshot of one of them would leave a document that survived the flip painted in the other
/// scheme's ink.
export function readTheme(
  env: NodeJS.ProcessEnv = process.env,
  appearanceOverride?: "light" | "dark",
): Theme {
  const appearance = appearanceOverride ?? (env.SYNTH_MD_APPEARANCE === "light" ? "light" : "dark")
  const palette = { ...DEFAULTS[appearance] }
  for (const [key, value] of Object.entries(overrides(env.SYNTH_MD_PALETTE, appearance))) {
    // Only known keys, and only strings: the blob crosses a process boundary, and a malformed
    // one must degrade to the defaults rather than paint with `undefined`.
    if (key in palette && typeof value === "string") (palette as any)[key] = value
  }
  const syntax = buildSyntax(palette)
  return {
    appearance,
    palette,
    syntax,
    matchStyleId: syntax.registerStyle(MATCH_SCOPE, { fg: palette.fg, bg: palette.match }),
    matchCurrentStyleId: syntax.registerStyle(MATCH_CURRENT_SCOPE, {
      fg: appearance === "dark" ? palette.fg : palette.heading,
      bg: palette.matchCurrent,
      bold: true,
    }),
  }
}

/// The app's palette overrides for one appearance. Accepts either a flat object (one
/// appearance's worth) or `{light: {...}, dark: {...}}`; anything else yields nothing, because
/// a corrupt blob is not worth failing a document open over.
function overrides(raw: string | undefined, appearance: "light" | "dark"): Record<string, unknown> {
  if (!raw) return {}
  try {
    const parsed = JSON.parse(raw)
    if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) return {}
    const perAppearance = parsed[appearance]
    if (perAppearance && typeof perAppearance === "object" && !Array.isArray(perAppearance)) {
      return perAppearance as Record<string, unknown>
    }
    return "light" in parsed || "dark" in parsed ? {} : (parsed as Record<string, unknown>)
  } catch {
    return {}
  }
}

function buildSyntax(p: Palette): SyntaxStyle {
  const styles: Record<string, StyleDefinitionInput> = {
    default: { fg: p.fg },

    // Markdown structure. `conceal` hides the markers themselves, so these style what
    // survives concealment — the text the reader actually sees.
    "markup.heading": { fg: p.heading, bold: true },
    "markup.heading.1": { fg: p.heading, bold: true },
    "markup.heading.2": { fg: p.heading, bold: true },
    "markup.heading.3": { fg: p.accent, bold: true },
    "markup.heading.4": { fg: p.accent, bold: true },
    "markup.heading.5": { fg: p.muted, bold: true },
    "markup.heading.6": { fg: p.muted, bold: true },
    "markup.bold": { fg: p.fg, bold: true },
    "markup.italic": { fg: p.fg, italic: true },
    "markup.strikethrough": { fg: p.faint, dim: true },
    "markup.underline": { underline: true },
    "markup.link": { fg: p.link, underline: true },
    "markup.link.url": { fg: p.link, underline: true },
    "markup.link.label": { fg: p.link },
    "markup.quote": { fg: p.quote, italic: true },
    "markup.list": { fg: p.accent },
    "markup.list.checked": { fg: p.accent },
    "markup.list.unchecked": { fg: p.muted },
    "markup.raw": { fg: p.code, bg: p.codeBg },
    "markup.raw.block": { fg: p.code },
    "markup.raw.inline": { fg: p.code, bg: p.codeBg },
    // The markers `conceal` removes. Styled anyway: a revealed block turns concealment off,
    // and these are what tells the writer they are looking at source.
    conceal: { fg: p.faint, dim: true },
    punctuation: { fg: p.faint },
    "punctuation.special": { fg: p.faint },
    "punctuation.delimiter": { fg: p.faint },
    "punctuation.bracket": { fg: p.muted },

    // Code, for tree-sitter scopes inside fences.
    comment: { fg: p.faint, italic: true },
    keyword: { fg: p.accent, bold: true },
    "keyword.control": { fg: p.accent, bold: true },
    string: { fg: p.link },
    "string.special": { fg: p.link },
    number: { fg: p.quote },
    boolean: { fg: p.quote },
    constant: { fg: p.quote },
    "constant.builtin": { fg: p.quote },
    function: { fg: p.heading },
    "function.call": { fg: p.heading },
    "function.method": { fg: p.heading },
    type: { fg: p.accent },
    "type.builtin": { fg: p.accent },
    variable: { fg: p.fg },
    "variable.parameter": { fg: p.fg },
    "variable.builtin": { fg: p.muted },
    property: { fg: p.fg },
    operator: { fg: p.muted },
    label: { fg: p.muted },
    tag: { fg: p.accent },
    attribute: { fg: p.muted },
  }
  return SyntaxStyle.fromStyles(styles)
}
