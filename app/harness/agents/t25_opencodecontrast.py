"""opencode contrast gate: the light half of the theme Synth installs for it.

Same machinery as `t24_agentcontrast` — replay a real session, resolve every cell, measure each run
of ink against what is behind it — but a different question, because opencode's problem was never the
one Claude Code had.

opencode's theme *machinery* works. It asks the terminal what colour it is (OSC 10/11), enables DEC
2031, and re-themes a **running** session when the appearance changes. So there is nothing for Synth
to keep in step; there is only the light half's values, which on the surfaces opencode paints for
itself left `textMuted` at 3.17:1 and `accent`/`warning` at 2.52:1.

**This suite must answer the colour queries.** With nothing replying, opencode falls back to its dark
theme and paints `#0a0a0a` over everything — which measures fine against itself and tells you
nothing. That is the same artefact recorded for Claude Code on 2026-07-27, and it is the easiest way
to conclude the opposite of the truth here. `ccdrive.Session(surface=…)` is what answers, and the
count is asserted rather than assumed.

The other half of what Synth's theme does is not a contrast question at all: opencode paints its own
field where Claude Code lets the terminal's through, so a pane drew its own rectangle inside ghostty's
padding band. The theme hands `background` back by writing `TerminalTheme`'s surface at **zero alpha**
— painting nothing, while still telling opencode what it is sitting on, which it needs because it
derives the splash mark's shadow from that anchor. Two things have to hold for that to keep working
and neither is visible in the file alone: the pair must still match `TerminalTheme`, and a real
opencode must actually leave its cells unpainted. Both are asserted here, against v1 and v2 — they
share the theme file and differ only in which config names it.

Asserted:
  • the shipped `Resources/opencode-theme.json` parses, is complete, and every light ink value in it
    clears its floor on opencode's own least forgiving light surface
  • its `background` is `TerminalTheme`'s own surface at zero alpha, in both halves
  • the rest of its **dark** half is identical to opencode's own, extracted from the binary — Synth
    corrected light and handed back the background, and this is what proves it rather than claims it
  • a real opencode — v1 and v2 — leaves the field to the terminal, in both appearances
  • a real opencode rendered on a light surface has no failing text or chrome run
  • the same on a dark surface is no worse than opencode ships

Recorded, not asserted:
  • block-element fills, which are surfaces rather than controls (see `ccontrast`)
  • that opencode re-themes live, which is why Synth installs a file and then leaves it alone
"""
import json, os, re, sys

sys.path.insert(0, ".")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import lib
from lib import *

import ccdrive
import ccontrast
import ttygrid

HERE = os.path.dirname(os.path.abspath(__file__))
THEME = os.path.normpath(os.path.join(HERE, "../../Sources/Synth/Resources/opencode-theme.json"))
TERMINAL_THEME = os.path.normpath(os.path.join(HERE, "../../Sources/Synth/Ghostty/TerminalTheme.swift"))

# opencode still paints `backgroundElement` — the prompt box — so its ink is judged against that
# rather than against the terminal surface the rest of the field is now left to. It is the darker of
# the two in light, and so the least forgiving.
REFERENCE_DEF = "lightStep3"

# The `background` value is not opencode's to choose any more, so it is not compared against theirs.
HANDED_BACK = {"background"}

# How much of the screen a rendered opencode must leave to the terminal. The remainder is its own
# prompt box, which it is entitled to paint: measured at 6.7% of an 100x44 splash.
FIELD_FLOOR = 0.85

# Which light defs carry ink a reader parses, and which one indicates focus. Named rather than
# derived: "is this value used as ink or as a fill" is not something the file says.
INK_DEFS = ["lightStep9", "lightStep10", "lightStep11", "lightStep12", "lightSecondary",
            "lightAccent", "lightRed", "lightOrange", "lightGreen", "lightCyan", "lightYellow"]
FOCUS_DEFS = ["lightStep8"]                 # borderActive — the focus ring
INK_KEYS = ["diffContext", "diffHunkHeader", "diffLineNumber", "diffAdded", "diffRemoved"]

SETTLE = 14.0


def rgb(value):
    v = value.lstrip("#")
    return (int(v[0:2], 16), int(v[2:4], 16), int(v[4:6], 16))


def opencode_default_theme(binary):
    """opencode's own theme, lifted out of its binary.

    The values are a JS object literal in the bundle, not a resource, so this quotes the bare keys
    and parses it. Returns None if opencode has changed shape — the drift check then skips rather
    than failing, because "we can no longer read their theme" is not "Synth's theme is wrong".
    """
    try:
        data = open(binary, "rb").read()
    except OSError:
        return None
    # Anchor on a pair that identifies the *default* theme. `lightStep11:"#8a8a8a"` alone matches
    # 31 of the 33 built-ins, and picking the wrong one makes this compare Synth's fork against a
    # theme it was never based on.
    anchor = data.find(b'lightStep9:"#3b7dd8"')
    if anchor < 0 or data.find(b'lightAccent:"#d68c27"', anchor, anchor + 4000) < 0:
        return None
    start = data.rfind(b'{$schema:"https://opencode.ai/theme.json"', 0, anchor)
    if start < 0:
        return None
    depth, i = 0, start
    while i < len(data):
        if data[i:i + 1] == b"{":
            depth += 1
        elif data[i:i + 1] == b"}":
            depth -= 1
            if depth == 0:
                break
        i += 1
    raw = data[start:i + 1].decode("utf8", "replace")
    quoted = re.sub(r'([{,])([A-Za-z_$][A-Za-z0-9_$]*):', r'\1"\2":', raw)
    try:
        return json.loads(quoted)
    except ValueError:
        return None


def terminal_surfaces():
    """`TerminalTheme`'s two background colours, read out of the Swift.

    Parsed rather than duplicated because a copy is exactly what this check exists to catch: the
    theme file quotes these values, and nothing but this would notice if the terminal's moved and
    opencode's did not. Returns None if the Swift has changed shape, which skips the comparison
    rather than failing it — "we can no longer read TerminalTheme" is not "the pair has drifted".
    """
    try:
        src = open(TERMINAL_THEME).read()
    except OSError:
        return None
    light = re.search(r'bg:\s*"([0-9a-fA-F]{6})"', src)
    dark = re.search(r'background = ([0-9a-fA-F]{6})', src)
    if not light or not dark:
        return None
    return {"light": light.group(1).lower(), "dark": dark.group(1).lower()}


def seed(root, theme_bytes):
    """An XDG config dir holding Synth's theme, so nothing touches the developer's own opencode."""
    import shutil
    shutil.rmtree(root, ignore_errors=True)
    os.makedirs(f"{root}/opencode/themes", exist_ok=True)
    open(f"{root}/opencode/themes/synth.json", "wb").write(theme_bytes)
    # Both files: v1 reads `tui.json` and v2 reads `cli.json`, in the same directory and off the
    # same `themes/`. Writing v2's rather than letting it migrate v1's keeps the run deterministic
    # and puts the shape `OpencodeTheme.adoptCLI` writes under the same test.
    with open(f"{root}/opencode/tui.json", "w") as fh:
        json.dump({"$schema": "https://opencode.ai/tui.json", "theme": "synth"}, fh)
    with open(f"{root}/opencode/cli.json", "w") as fh:
        json.dump({"$schema": "https://opencode.ai/v2/cli.json",
                   "theme": {"name": "synth", "mode": "system"}}, fh)
    return root


def render(binary, theme_bytes, dark, tag):
    cwd = os.path.join(lib.H, f"t25-{tag}")
    os.makedirs(cwd, exist_ok=True)
    xdg = seed(os.path.join(lib.H, f"t25-xdg-{tag}"), theme_bytes)
    em = ttygrid.Emulator(ccdrive.COLS, ccdrive.ROWS)
    surface = ccontrast.Surface(dark=dark)
    s = ccdrive.Session(os.path.expanduser("~"), emulator=em, cwd=cwd, binary=binary,
                        surface=surface, env_extra={"XDG_CONFIG_HOME": xdg})
    s.pump(SETTLE)
    return em, s, surface


def field(em):
    """The share of the screen opencode left to the terminal — cells it painted no background on."""
    cells = list(em.cells())
    unpainted = sum(1 for _y, _x, c in cells if c.bg is None)
    return unpainted / len(cells) if cells else 0.0


print("=== T25: opencode — the light half Synth installs, and the field it hands back ===")

binary = ccdrive.opencode_binary()
if not binary:
    skip("no `opencode` CLI on PATH (only Synth's shim resolves)")

print("\n--- the theme Synth ships ---", flush=True)
try:
    theme_bytes = open(THEME, "rb").read()
    theme = json.loads(theme_bytes)
except (OSError, ValueError) as exc:
    check("Resources/opencode-theme.json parses", False, str(exc))
    sys.exit(result())

check("Resources/opencode-theme.json parses",
      isinstance(theme.get("defs"), dict) and isinstance(theme.get("theme"), dict),
      f"{len(theme.get('defs', {}))} defs, {len(theme.get('theme', {}))} keys")

reference = rgb(theme["defs"][REFERENCE_DEF])
worst = None
for name in INK_DEFS + FOCUS_DEFS + INK_KEYS:
    if name in theme["defs"]:
        value = theme["defs"][name]
    else:
        value = theme["theme"][name]["light"]
        if not value.startswith("#"):
            value = theme["defs"][value]
    floor = ccontrast.CHROME_FLOOR if name in FOCUS_DEFS else ccontrast.TEXT_FLOOR
    ratio = ccontrast.contrast(rgb(value), reference)
    if worst is None or ratio - floor < worst[0]:
        worst = (ratio - floor, name, value, ratio, floor)
check(f"every light ink value clears its floor on {theme['defs'][REFERENCE_DEF]}",
      worst is not None and worst[0] >= 0,
      f"tightest {worst[1]} {worst[2]} = {worst[3]:.2f}:1 (needs {worst[4]})" if worst else "none")

surfaces = terminal_surfaces()
if surfaces is None:
    print("  NOTE  TerminalTheme.swift could not be read — the surface pair was not compared",
          flush=True)
else:
    installed = {half: theme["defs"].get(theme["theme"]["background"][half], "").lower()
                 for half in ("light", "dark")}
    check("`background` is TerminalTheme's surface at zero alpha, in both halves",
          all(installed[h] == f"#{surfaces[h]}00" for h in ("light", "dark")),
          f"theme {installed} vs terminal {surfaces}")

# Synth corrected light. This is what proves it did not touch anything else.
default = opencode_default_theme(binary)
if default is None:
    print("  NOTE  opencode's own theme could not be read out of its binary — "
          "the dark-half comparison was skipped, not passed", flush=True)
else:
    dark_defs = [k for k in default["defs"] if k.startswith("dark")]
    same_defs = [k for k in dark_defs if theme["defs"].get(k) != default["defs"][k]]
    same_keys = [k for k, v in default["theme"].items()
                 if k not in HANDED_BACK
                 and isinstance(v, dict) and theme["theme"].get(k, {}).get("dark") != v.get("dark")]
    check(f"the dark half is opencode's own, untouched but for {sorted(HANDED_BACK)}",
          not same_defs and not same_keys,
          f"differs: defs={same_defs[:4]} keys={same_keys[:4]}")
    # Equality, not containment. Synth's theme is a fork of this one, so its shape should match
    # exactly — a key opencode has added is one Synth is now silently not theming, and a key only
    # Synth has is a typo that opencode drops on the floor. (`backgroundMenu` and
    # `selectedListItemText` are absent from both: opencode's own default omits them, so they carry
    # a built-in fallback and leaving them out is exactly as safe as shipping the default.)
    missing = sorted(set(default["theme"]) - set(theme["theme"]))
    extra = sorted(set(theme["theme"]) - set(default["theme"]))
    check("the theme has exactly the keys opencode's default has",
          not missing and not extra, f"missing={missing[:5]} extra={extra[:5]}")

for dark, label, floors in ((False, "light", {"text": ccontrast.TEXT_FLOOR,
                                              "chrome": ccontrast.CHROME_FLOOR}),
                            (True, "dark", {"text": 4.2, "chrome": 3.0})):
    print(f"\n--- {label} ---", flush=True)
    em, s, surface = render(binary, theme_bytes, dark, label)
    runs = ccontrast.runs(em, surface)
    answered = dict(s.answered)
    s.close()

    # Without a reply opencode paints its dark theme regardless of the surface, and every ratio below
    # would be measured against a screen no user sees.
    check(f"[{label}] the surface colour was actually asked for and answered",
          answered["bg"] >= 1, f"answered {answered}")
    check(f"[{label}] opencode rendered — runs were found to measure",
          len(runs) >= 30, f"{len(runs)} runs")
    share = field(em)
    check(f"[{label}] the field is the terminal's — opencode painted no background on it",
          share >= FIELD_FLOOR, f"{share:.1%} unpainted (needs {FIELD_FLOOR:.0%})")

    for kind, floor in floors.items():
        pool = [r for r in runs if r.kind == kind]
        low = min(pool, key=lambda r: r.ratio) if pool else None
        check(f"[{label}] every {kind} run clears {floor}:1",
              low is not None and low.ratio >= floor,
              f"worst {low}" if low else "no runs of this kind")

    fills = {ccontrast.hexof(r.fg) + ccontrast.hexof(r.bg): r
             for r in runs if r.kind == "fill" and r.ratio < 3.0}
    if fills:
        print(f"  NOTE  [{label}] block-element fills, surfaces rather than controls, not gated: "
              + ", ".join(f"{ccontrast.hexof(r.fg)} on {ccontrast.hexof(r.bg)} {r.ratio:.2f}:1"
                          for r in fills.values()), flush=True)

# v2 reads the same theme out of the same directory, named by `cli.json` instead of `tui.json`, and
# renders it through a different TUI. Contrast is not re-measured here — the values are the same file
# and v1 already answered for them — but the seam is, because "renders the theme" and "leaves the
# field alone" are separate claims and only one of them is in the file.
print("\n--- opencode2 ---", flush=True)
binary2 = ccdrive.opencode2_binary()
if not binary2:
    print("  NOTE  no `opencode2` CLI installed — v2's field was not measured, not passed",
          flush=True)
else:
    for dark, label in ((False, "light"), (True, "dark")):
        em, s, surface = render(binary2, theme_bytes, dark, f"v2-{label}")
        runs = ccontrast.runs(em, surface)
        answered = dict(s.answered)
        s.close()
        check(f"[v2 {label}] the surface colour was actually asked for and answered",
              answered["bg"] >= 1, f"answered {answered}")
        check(f"[v2 {label}] opencode2 rendered — runs were found to measure",
              len(runs) >= 30, f"{len(runs)} runs")
        share = field(em)
        check(f"[v2 {label}] the field is the terminal's — opencode2 painted no background on it",
              share >= FIELD_FLOOR, f"{share:.1%} unpainted (needs {FIELD_FLOOR:.0%})")

# Why Synth installs the file and then leaves it alone: opencode does the following itself.
print("\n--- recorded, not gated ---", flush=True)
em = ttygrid.Emulator(ccdrive.COLS, ccdrive.ROWS)
cwd = os.path.join(lib.H, "t25-live")
os.makedirs(cwd, exist_ok=True)
xdg = seed(os.path.join(lib.H, "t25-xdg-live"), theme_bytes)
light, dark_s = ccontrast.Surface(dark=False), ccontrast.Surface(dark=True)
s = ccdrive.Session(os.path.expanduser("~"), emulator=em, cwd=cwd, binary=binary,
                    surface=light, env_extra={"XDG_CONFIG_HOME": xdg})
s.pump(SETTLE)
before = {ccontrast.hexof(r.bg) for r in ccontrast.runs(em, light)}
s.surface = dark_s
s.notify_theme(dark=True)
s.pump(3.0)
s.repaint()
after = {ccontrast.hexof(r.bg) for r in ccontrast.runs(em, dark_s)}
s.close()
print(f"  NOTE  opencode re-themes a running session on a DEC 2031 notification: "
      f"{len(before - after)} of {len(before)} backgrounds changed "
      f"(this is why Synth writes the theme once and does not track the appearance)", flush=True)

sys.exit(result())
