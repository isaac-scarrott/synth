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

Asserted:
  • the shipped `Resources/opencode-theme.json` parses, is complete, and every light ink value in it
    clears its floor on opencode's own least forgiving light surface
  • its **dark** half is identical to opencode's own, extracted from the binary — Synth corrected
    light and nothing else, and this is what proves it rather than claims it
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

# opencode paints its own surfaces and never lets the terminal's show through, so its ink is judged
# against `backgroundElement` — the darkest of its three light surfaces, and so the least forgiving.
REFERENCE_DEF = "lightStep3"

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


def seed(root, theme_bytes):
    """An XDG config dir holding Synth's theme, so nothing touches the developer's own opencode."""
    import shutil
    shutil.rmtree(root, ignore_errors=True)
    os.makedirs(f"{root}/opencode/themes", exist_ok=True)
    open(f"{root}/opencode/themes/synth.json", "wb").write(theme_bytes)
    with open(f"{root}/opencode/tui.json", "w") as fh:
        json.dump({"$schema": "https://opencode.ai/tui.json", "theme": "synth"}, fh)
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


print("=== T25: opencode contrast — the light half Synth installs ===")

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

# Synth corrected light. This is what proves it did not touch anything else.
default = opencode_default_theme(binary)
if default is None:
    print("  NOTE  opencode's own theme could not be read out of its binary — "
          "the dark-half comparison was skipped, not passed", flush=True)
else:
    dark_defs = [k for k in default["defs"] if k.startswith("dark")]
    same_defs = [k for k in dark_defs if theme["defs"].get(k) != default["defs"][k]]
    same_keys = [k for k, v in default["theme"].items()
                 if isinstance(v, dict) and theme["theme"].get(k, {}).get("dark") != v.get("dark")]
    check("the dark half is opencode's own, untouched",
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
