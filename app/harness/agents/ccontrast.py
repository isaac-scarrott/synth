"""Resolve a replayed screen into coloured runs and measure each against what is behind it.

`ttygrid` says which colour token each cell carries; this says what that token *is* on a Synth
surface, and whether a reader can see it. The two halves are split because the resolution rules are
the interesting part and they are all Synth's:

  • a cell with no colour of its own takes `TerminalTheme`'s light `foreground` / `background`
  • slots 0–15 come from Synth's light palette, 16–255 from the xterm standard the palette
    deliberately leaves alone (see TerminalTheme's note on why re-basing it is a dead end)
  • faint is not a colour but a blend, and ghostty performs it with `faint-opacity` — so faint text
    resolves to ink mixed toward its own background, which is the only way its real ratio shows up
  • reverse swaps the pair *after* everything above, the way a terminal does

Measured against the opaque `#f7f8fa` token rather than the translucent composite that actually
reaches the glass. That is the deliberate choice: this suite's job is to gate the colours a *tool*
emits, deterministically, from bytes — and `t13_termcontrast` already measures the real composite in
pixels. Two suites, two questions; this one would lose its determinism the moment it depended on
the wallpaper.

Thresholds follow WCAG 2.1 by role, because holding a box-drawing border to the same floor as body
text would fail every panel Claude Code draws and teach everyone to ignore the gate:
  • text — 4.5:1 (1.4.3, normal-size)
  • chrome (box drawing, blocks, separators, spinner frames) — 3:1 (1.4.11, non-text contrast)
"""

# Synth's light terminal surface, from TerminalTheme.swift. Kept as literals rather than parsed out
# of the Swift: this is a second opinion on those numbers, and a copy that has to be updated by hand
# is exactly the tripwire wanted if someone changes one and not the other.
LIGHT_FG = (0x1c, 0x1e, 0x23)
LIGHT_BG = (0xf7, 0xf8, 0xfa)
LIGHT_FAINT_OPACITY = 0.65

LIGHT_ANSI = [
    "1c1e23", "a2241a", "106236", "754d09", "194eb7", "86289e", "075d6f", "9296a1",
    "5b5e68", "851d16", "0d4f2c", "5f3e07", "143f96", "6e2082", "064c5b", "ffffff",
]

# ghostty's built-in dark palette and surface, for the dark half of the gate. Synth overrides only
# the background there (TerminalTheme), so these are ghostty's defaults, not Synth's choices.
DARK_FG = (0xff, 0xff, 0xff)
DARK_BG = (0x12, 0x13, 0x17)
DARK_FAINT_OPACITY = 0.5
DARK_ANSI = [
    "1d1f21", "cc6666", "b5bd68", "f0c674", "81a2be", "b294bb", "8abeb7", "c5c8c6",
    "666666", "d54e53", "b9ca4a", "e7c547", "7aa6da", "c397d8", "70c0b1", "eaeaea",
]

TEXT_FLOOR = 4.5
CHROME_FLOOR = 3.0


def _hex(s):
    return (int(s[0:2], 16), int(s[2:4], 16), int(s[4:6], 16))


def xterm256(n):
    """The standard 256-colour cube and greyscale ramp — a fixed standard, not a theme."""
    if n < 16:
        raise ValueError("slots 0-15 are the theme's, not the standard's")
    if n < 232:
        n -= 16
        lv = [0, 95, 135, 175, 215, 255]
        return (lv[n // 36], lv[(n % 36) // 6], lv[n % 6])
    v = 8 + 10 * (n - 232)
    return (v, v, v)


class Surface:
    """One appearance's resolution rules."""

    def __init__(self, dark):
        self.dark = dark
        self.fg = DARK_FG if dark else LIGHT_FG
        self.bg = DARK_BG if dark else LIGHT_BG
        self.ansi = [_hex(h) for h in (DARK_ANSI if dark else LIGHT_ANSI)]
        self.faint_opacity = DARK_FAINT_OPACITY if dark else LIGHT_FAINT_OPACITY

    def _token(self, tok, fallback):
        if tok is None:
            return fallback
        kind, val = tok
        if kind == "rgb":
            return tuple(val)
        return self.ansi[val] if val < 16 else xterm256(val)

    def resolve(self, cell):
        """The (fg, bg) a reader actually sees for this cell."""
        fg = self._token(cell.fg, self.fg)
        bg = self._token(cell.bg, self.bg)
        if cell.reverse:
            fg, bg = bg, fg
        if cell.faint:
            k = self.faint_opacity
            fg = tuple(round(b + (f - b) * k) for f, b in zip(fg, bg))
        return fg, bg


def luminance(c):
    def ch(v):
        v /= 255
        return v / 12.92 if v <= 0.03928 else ((v + 0.055) / 1.055) ** 2.4
    return 0.2126 * ch(c[0]) + 0.7152 * ch(c[1]) + 0.0722 * ch(c[2])


def contrast(a, b):
    la, lb = luminance(a), luminance(b)
    hi, lo = max(la, lb), min(la, lb)
    return (hi + 0.05) / (lo + 0.05)


# Glyphs that draw the interface rather than say anything: box drawing, block elements, geometric
# shapes, braille spinners, and the arrows and bullets Claude Code uses as markers.
_CHROME_RANGES = [
    (0x2190, 0x21FF),   # arrows
    (0x2500, 0x257F),   # box drawing
    (0x2580, 0x259F),   # block elements
    (0x25A0, 0x25FF),   # geometric shapes
    (0x2800, 0x28FF),   # braille (spinners)
    (0x2b00, 0x2bff),   # misc symbols and arrows
]
_CHROME_EXTRA = set("─│┌┐└┘├┤┬┴┼╭╮╯╰╌╍┄┅━┃▔▁▏▕·•◦※⎿⏵⏸⧉✔✗✳❯❮…")


def is_chrome(ch):
    o = ord(ch)
    if ch in _CHROME_EXTRA:
        return True
    return any(a <= o <= b for a, b in _CHROME_RANGES)


class Run:
    __slots__ = ("y", "x", "text", "fg", "bg", "ratio", "kind")

    def __init__(self, y, x, text, fg, bg, ratio, kind):
        self.y, self.x, self.text = y, x, text
        self.fg, self.bg, self.ratio, self.kind = fg, bg, ratio, kind

    @property
    def floor(self):
        return CHROME_FLOOR if self.kind == "chrome" else TEXT_FLOOR

    @property
    def ok(self):
        return self.ratio >= self.floor

    def __str__(self):
        """Deliberately without the floor: the caller states which floor it is applying, and dark is
        pinned below WCAG on purpose — printing `self.floor` there contradicts the check's own name."""
        return (f"{hexof(self.fg)} on {hexof(self.bg)} = {self.ratio:.2f}:1 "
                f"{self.kind} r{self.y}c{self.x} {self.text.strip()[:44]!r}")


def hexof(c):
    return f"#{c[0]:02x}{c[1]:02x}{c[2]:02x}"


def runs(emulator, surface):
    """Every maximal run of same-colour, same-role, non-blank cells on the settled screen.

    Blank cells are skipped rather than measured: a space carries no ink, and a row of them under a
    coloured background would otherwise report the background against itself.
    """
    result = []
    for y, row in enumerate(emulator.screen.grid):
        cur = None
        for x, cell in enumerate(row):
            if cell.ch in (" ", "\xa0", ""):
                if cur:
                    result.append(_mk(y, cur, surface))
                    cur = None
                continue
            fg, bg = surface.resolve(cell)
            kind = "chrome" if is_chrome(cell.ch) else "text"
            key = (fg, bg, kind)
            if cur and cur[0] == key and cur[1] + len(cur[2]) == x:
                cur[2].append(cell.ch)
            else:
                if cur:
                    result.append(_mk(y, cur, surface))
                cur = [key, x, [cell.ch]]
        if cur:
            result.append(_mk(y, cur, surface))
    return result


def _mk(y, cur, surface):
    (fg, bg, kind), x, chars = cur
    return Run(y, x, "".join(chars), fg, bg, contrast(fg, bg), kind)


def audit(emulator, surface, ignore_ratio_above=None):
    """Failing runs, worst first, deduplicated by (fg, bg, kind) so one bad token reports once."""
    seen, bad = {}, []
    for r in runs(emulator, surface):
        if r.ok:
            continue
        key = (r.fg, r.bg, r.kind)
        if key not in seen:
            seen[key] = r
            bad.append(r)
    bad.sort(key=lambda r: r.ratio)
    return bad
