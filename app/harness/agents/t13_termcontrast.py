"""Terminal contrast gate: what the light-mode terminal actually renders, in pixels.

The light palette is the one part of the theme that cannot be checked by reading it. Its job is to
carry colour a *tool* chose — and every tool chose against a dark terminal — so the only honest
question is what a real ghostty surface puts on screen. This suite paints a fixture through the
scratch terminal of a real build, screenshots it, and measures each row's strongest ink against
that row's own background.

The fixture puts exactly one styled thing on each line. That is the whole trick: a row's
strongest ink is then unambiguously the thing under test, where a mixed line would be dominated by
whichever token was darkest (the bug that hid faint's real ratio during the original sweep).

The two themes are held to different floors, and the difference is not sloppiness. Light's palette
is Synth's own work and 4.5:1 is a claim about it. Dark's is ghostty's default set, which Synth
deliberately does not override (see TerminalTheme) — and whose red renders at 4.31:1 on the dark
card. Gating dark at 4.5 would fail on shipped, accepted behaviour, so dark is pinned just under
what it actually ships: not a claim, a tripwire for it getting worse.

Asserted in both themes:
  • every row clears the theme's floor — the palette's hues, the bright set, and slots 7/15 used
    the way they are meant to be (as a fill under the surface's own ink)
  • faint (SGR 2) renders dimmer than body text but still clears the floor — it is what hints and
    spinners are written in, and ghostty's half-and-half blend lands at 3.2:1 on a light surface
    without `faint-opacity` to correct it

The 256-colour ramp is measured but *not* asserted. Re-basing it is a known dead end (mirroring it
fixes foreground use and breaks any status bar that pins its own ink — see 2026-07-27), so those
numbers are recorded to make a future change visible rather than to gate one.
"""
import os, struct, sys, time, uuid, zlib
sys.path.insert(0, ".")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import lib
from lib import *

from collections import Counter


class PNG:
    """The screenshot, decoded with the standard library alone — every other suite here runs on a
    bare python3 and this one has no business being the reason that stops being true."""

    def __init__(self, path):
        data = open(path, "rb").read()
        assert data[:8] == b"\x89PNG\r\n\x1a\n", "not a png"
        idat, pos = bytearray(), 8
        while pos < len(data):
            (length,), kind = struct.unpack(">I", data[pos:pos + 4]), data[pos + 4:pos + 8]
            body = data[pos + 8:pos + 8 + length]
            if kind == b"IHDR":
                self.w, self.h, depth, colour = struct.unpack(">IIBB", body[:10])
                assert depth == 8 and colour in (2, 6), f"unsupported png {depth}/{colour}"
                assert body[12] == 0, "interlaced png"
                self.stride = 3 if colour == 2 else 4
            elif kind == b"IDAT":
                idat += body
            elif kind == b"IEND":
                break
            pos += 12 + length
        self._unfilter(zlib.decompress(bytes(idat)))

    def _unfilter(self, raw):
        bpp, w, h = self.stride, self.w, self.h
        line = w * bpp
        out = bytearray(line * h)
        prev = bytearray(line)
        pos = 0
        for y in range(h):
            f = raw[pos]; pos += 1
            cur = bytearray(raw[pos:pos + line]); pos += line
            if f == 1:
                for i in range(bpp, line):
                    cur[i] = (cur[i] + cur[i - bpp]) & 0xFF
            elif f == 2:
                for i in range(line):
                    cur[i] = (cur[i] + prev[i]) & 0xFF
            elif f == 3:
                for i in range(line):
                    left = cur[i - bpp] if i >= bpp else 0
                    cur[i] = (cur[i] + ((left + prev[i]) >> 1)) & 0xFF
            elif f == 4:
                for i in range(line):
                    a = cur[i - bpp] if i >= bpp else 0
                    b = prev[i]
                    c = prev[i - bpp] if i >= bpp else 0
                    p = a + b - c
                    pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                    cur[i] = (cur[i] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 0xFF
            out[y * line:(y + 1) * line] = cur
            prev = cur
        self._px, self._line = out, line

    def pixel(self, x, y):
        i = y * self._line + x * self.stride
        return (self._px[i], self._px[i + 1], self._px[i + 2])

# Light's floor is a claim about Synth's own palette. Dark's pins ghostty's default set just under
# where it ships — its red is 4.31:1 on the dark card — so the gate catches regression without
# asserting a quality Synth never chose.
FLOOR = {"light": 4.5, "dark": 4.2}

# One styled token per line. Order is irrelevant — every row is held to the same floor — which
# keeps the suite immune to how many lines the user's prompt happens to occupy.
FIXTURE = r"""
printf 'default ink on the surface\n'
printf '\e[1mbold\e[0m\n'
printf '\e[2mfaint FAINT faint\e[0m\n'
printf '\e[4munderline\e[0m\n'
printf '\e[7mreverse video\e[0m\n'
printf '\e[31mnormal slot 1\e[0m\n'
printf '\e[32mnormal slot 2\e[0m\n'
printf '\e[33mnormal slot 3\e[0m\n'
printf '\e[34mnormal slot 4\e[0m\n'
printf '\e[35mnormal slot 5\e[0m\n'
printf '\e[36mnormal slot 6\e[0m\n'
printf '\e[91mbright slot 1\e[0m\n'
printf '\e[92mbright slot 2\e[0m\n'
printf '\e[93mbright slot 3\e[0m\n'
printf '\e[94mbright slot 4\e[0m\n'
printf '\e[95mbright slot 5\e[0m\n'
printf '\e[96mbright slot 6\e[0m\n'
printf '\e[47m  slot 7 as a fill under default ink  \e[0m\n'
printf '\e[107m  slot 15 as a fill under default ink  \e[0m\n'
"""

# Faint gets its own screen, repeated. On a mixed line the row's strongest ink is whatever token
# was darkest, which is what hid faint's true ratio when this was first measured by hand. The
# repetition is what separates it from the shell prompt, which is always on screen too and is
# itself coloured: four identical rows agree on a ratio, a prompt cannot.
FAINT_ALONE = r"""
printf '\e[2mfaint text measured on its own\e[0m\n'
printf '\e[2mfaint text measured on its own\e[0m\n'
printf '\e[2mfaint text measured on its own\e[0m\n'
printf '\e[2mfaint text measured on its own\e[0m\n'
"""

RAMP = r"""
printf '\e[38;5;232mramp 232\e[0m\n'
printf '\e[38;5;240mramp 240\e[0m\n'
printf '\e[38;5;246mramp 246\e[0m\n'
printf '\e[38;5;250mramp 250\e[0m\n'
printf '\e[38;5;254mramp 254\e[0m\n'
"""


def lum(c):
    def ch(v):
        v /= 255
        return v / 12.92 if v <= 0.03928 else ((v + 0.055) / 1.055) ** 2.4
    return 0.2126 * ch(c[0]) + 0.7152 * ch(c[1]) + 0.0722 * ch(c[2])


def contrast(a, b):
    la, lb = lum(a), lum(b)
    hi, lo = max(la, lb), min(la, lb)
    return (hi + 0.05) / (lo + 0.05)


def rows_with_ink(path, box):
    """Every text row inside `box`, as (bg, strongest-ink, ratio). Rows are found rather than
    assumed, so a differently-scrolled terminal measures the same."""
    im = PNG(path)
    x0, y0, x1, y1 = box
    spans, run = [], None
    for y in range(y0, y1):
        counts = Counter(im.pixel(x, y) for x in range(x0, x1))
        bg = counts.most_common(1)[0][0]
        if sum(n for c, n in counts.items() if contrast(c, bg) > 1.25) >= 25:
            run = (y, y) if run is None else (run[0], y)
        elif run is not None:
            spans.append(run)
            run = None
    if run is not None:
        spans.append(run)
    out = []
    for a, b in spans:
        if b - a < 4:            # antialias fringe, not a line of text
            continue
        counts = Counter()
        for y in range(a, b + 1):
            counts.update(im.pixel(x, y) for x in range(x0, x1))
        bg = counts.most_common(1)[0][0]
        # Antialiasing smears each glyph over many near-shades; the core is the extreme one, and
        # a shade needs real coverage to count as ink at all.
        inks = [c for c, n in counts.items() if n >= 20 and contrast(c, bg) > 1.25]
        if not inks:
            continue
        core = max(inks, key=lambda c: contrast(c, bg))
        out.append((bg, core, contrast(core, bg)))
    return out


def hexof(c):
    return f"#{c[0]:02x}{c[1]:02x}{c[2]:02x}"


def run_theme(theme):
    print(f"\n--- {theme} ---", flush=True)
    kill_all()
    repo = fresh_repo(f"termcontrast-{theme}")
    sd = seed_state(repo, sessions=[
        {"id": str(uuid.uuid4()), "kind": "terminal", "title": "t", "titleIsCustom": True}])
    p, sock = launch(sd, f"{lib.H}/t13-{theme}.log", theme=theme,
                     extra_args=["-synth-mcp-app", "<false/>", "-synth-mcp-browser", "<false/>"])
    ctl = Ctl(sock, repo)
    time.sleep(2)
    # The scratch terminal is the cheapest real surface: a shell in this build, no session to seed.
    ctl("automation.key", keyCode=17, mods=["cmd", "shift"], chars="t")
    time.sleep(5)

    def paint(script, name):
        ctl("automation.scratch", action="run", text="clear; " + script.strip().replace("\n", "; "))
        time.sleep(3)
        png = f"{lib.H}/t13-{theme}-{name}.png"
        ctl("automation.screenshot", path=png)
        return png

    floor = FLOOR[theme]
    png = paint(FIXTURE, "fixture")
    # The scratch card, generously bounded — rows_with_ink finds the text inside it.
    im = PNG(png)
    box = (int(im.w * 0.32), int(im.h * 0.30), int(im.w * 0.68), int(im.h * 0.72))
    rows = rows_with_ink(png, box)

    check(f"[{theme}] the fixture rendered — rows were found to measure",
          len(rows) >= 15, f"{len(rows)} rows")

    worst = min(rows, key=lambda r: r[2]) if rows else None
    check(f"[{theme}] every row clears {floor}:1",
          worst is not None and worst[2] >= floor,
          f"worst {hexof(worst[1])} on {hexof(worst[0])} = {worst[2]:.2f}:1" if worst else "no rows")

    faint_rows = rows_with_ink(paint(FAINT_ALONE, "faint"), box)
    agreed = Counter(round(r[2], 2) for r in faint_rows).most_common(1)
    faint = next((r for r in faint_rows if agreed and round(r[2], 2) == agreed[0][0]), None)
    check(f"[{theme}] the four faint rows agree on one ratio",
          bool(agreed) and agreed[0][1] >= 3, f"{agreed[0][1] if agreed else 0}/4 agree")
    if faint:
        bg, ink, ratio = faint
        check(f"[{theme}] faint clears {floor}:1",
              ratio >= floor, f"{hexof(ink)} on {hexof(bg)} = {ratio:.2f}:1")
        # Faint that reads exactly like body text is faint that stopped working — the failure a
        # floor alone would wave through.
        body = max(rows, key=lambda r: r[2])[2]
        check(f"[{theme}] and is still visibly dimmer than body text",
              ratio < body * 0.75, f"faint {ratio:.2f}:1 vs body {body:.2f}:1")

    # Recorded, not gated: the 256-colour ramp is a fixed standard this theme deliberately leaves
    # alone. Printed so a change to that decision shows up as a diff in the suite's output.
    # The ramp's colours are pure greys; the shell prompt sharing the screen is not. Neutrality
    # is what tells the rows under test from the ones that just happen to be there.
    ramp = [r for r in rows_with_ink(paint(RAMP, "ramp"), box)
            if max(r[1]) - min(r[1]) <= 2]
    print(f"  NOTE  [{theme}] 256-colour ramp 232→254, as the standard defines it (not gated): "
          + ", ".join(f"{hexof(r[1])} {r[2]:.2f}:1" for r in ramp), flush=True)

    sh(f"kill {p.pid}")
    time.sleep(1)


print("=== T13: terminal contrast — what the surface actually renders ===")
for theme in ("light", "dark"):
    run_theme(theme)
sys.exit(result())
