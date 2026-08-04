"""agy contrast gate: a tripwire, because Synth holds no lever here at all.

The third agent, and the one where the answer is "nothing to ship" — but not for the reason it first
appeared. Measured, `agy` 1.1.x:

  • asks the terminal **nothing** — no OSC 11 background query, no OSC 10, no DEC 2031 subscription,
    so it cannot know a light surface from a dark one and does not try
  • paints hard-coded truecolor (61 SGR sequences on the startup frame alone)
  • **does have a colour-scheme setting**, with eight options and a live preview

That last point corrects an earlier reading of this. It is not in `--help`, not a subcommand, and
absent from `settings.json` until it is changed, so it looks like it does not exist — it lives in the
interactive `/config` panel as "Color Scheme" and persists as a plain `colorScheme` string. (The
`GetThemeMode` and `THEME_DEVICE` strings in the binary remain a red herring: those sit among Chrome
DevTools-protocol and protobuf strings from the embedded browser. There is no `AppleInterfaceStyle`
read either.)

So Synth *could* write that key, and deliberately does not, because **no option is accessible and the
default is the best of them.** Measured on a real conversation, 168 runs, on Synth's light surface:

    scheme                      failing   worst overall        worst text
    terminal (default)                2   1.45                 1.45  code-fence ink
    light                             4   1.29  separator      2.80
    colorblind-friendly light         4   1.29  separator      2.80
    solarized light                   5   1.15  separator      2.89

The reason `terminal` wins is the finding worth keeping: in that mode agy draws most of its UI from
the terminal's **ANSI palette**, which is the set `TerminalTheme` already tunes to 7:1 on the light
surface. Synth's palette is simply better than agy's own light theme. Switching schemes throws it
away — it does repair the code fence, and in exchange breaks the separator to 1.29:1 and adds two
more failures in the high 2s. One bad value traded for four.

(`solarized-light` with a hyphen is rejected: the valid string is `solarized light`. agy validates
the key and shows a settings error, so a wrong write is at least loud rather than silent.)

Which leaves two failures on the light surface, and they are different kinds of thing:

  • **`#d0d0d0` at 1.45:1** — the ink inside a fenced code block. Hard-coded truecolor in agy;
    only Google can move it.
  • **`#9296a1` at 2.78:1** — Synth's *own* ANSI slot 7, which agy uses as dim ink (the "Keyboard
    shortcuts" heading, among others). This one is a
    documented dead end rather than an oversight: `TerminalTheme` keeps slots 7 and 15 light because
    a TUI paints them *under* dark ink (selected rows, inverse video, status bars), and `t13`'s
    fixture asserts exactly that. Darkening slot 7 to ~`#767676` would make agy's ink pass at 4.5:1
    and simultaneously drop `t13`'s "slot 7 as a fill under default ink" from 4.5 to 3.64. One
    palette cannot serve both sides, which is the same finding recorded on 2026-07-27 for the
    256-colour ramp.

A third: **`#4285f4` at 3.35:1**, the Google blue of the "Antigravity CLI" banner. Also hard-coded.

Dark is not clean either, for the record — agy's own `#666666` renders the signed-in address at
3.23:1 on the dark card. Synth overrides nothing there either.

Asserted, as a pin rather than a claim — the floor is what agy renders today, so this catches it
getting worse without pretending Synth chose any of it:
  • three screens render (the banner, the shortcuts overlay, the slash-command palette)
  • nothing on them falls below the recorded pin

The screens are the ones agy draws *locally*. A conversation would be richer, and the `#d0d0d0` code
fence above was measured in a real one, but agy keeps conversation content in a per-conversation
SQLite database with a private schema — synthesising one means authoring that schema, which is a
worse foundation for a gate than three screens it renders from nothing. So the code-fence number is
recorded in this docstring rather than asserted.

Recorded, not asserted:
  • that agy still makes no terminal queries. If that ever changes it is *good* news and a reason to
    revisit, which is why it is a note and not a failing check.
  • the Color Scheme row from the settings panel, so the day agy ships an accessible scheme — or
    changes which one is default — shows up in this suite's output rather than going unnoticed.
"""
import os, re, sys

sys.path.insert(0, ".")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import lib
from lib import *

import ccdrive
import ccontrast
import ttygrid

# What agy renders today, just under its worst: slot 7 as ink at 2.78:1 in light, its own `#666666`
# at 3.23:1 in dark. A pin rather than a claim — none of these colours is Synth's to move.
PIN = 2.70
SETTLE = 16.0

# Each screen agy draws with no model call: what to type to get there, and a phrase only that screen
# produces — so a gate cannot quietly measure a trust prompt and call it a pass.
SCREENS = [
    ("banner", [], "Antigravity CLI"),
    ("shortcuts", ["?"], "Insert newline"),
    ("slash-commands", ["\x1b", "/"], "Add a directory to the workspace"),
    # The backspaces matter: escaping the slash palette leaves the `/` it was opened with sitting in
    # the input, so typing straight into it produces `//config` and matches nothing.
    ("settings", ["\x1b", "\x7f\x7f\x7f\x7f", "/config", "\r"], "Color Scheme"),
]


def workspace(tag):
    """A scratch repo agy is allowed into.

    The real HOME, not a seeded one — agy's credentials live there, and without them it renders a
    sign-in screen where `?` and `/` do nothing, which is a measurement of the wrong thing. Trust is
    granted through `lib.agy_trust`, the same way the other agy suites do it, and only ever for a
    path under this run's scratch directory.
    """
    cwd = os.path.join(lib.H, f"t26-{tag}")
    os.makedirs(cwd, exist_ok=True)
    lib.agy_trust(cwd, True)
    return cwd


print("=== T26: agy contrast — measured, because there is nothing to configure ===")

binary = lib.agy_binary()
if not binary:
    skip("no `agy` CLI (brew install --cask antigravity-cli)")
if not lib.agy_signed_in():
    skip("`agy` is not signed in — it renders a sign-in prompt rather than a conversation")

for dark, label in ((False, "light"), (True, "dark")):
    print(f"\n--- {label} ---", flush=True)
    cwd = workspace(label)
    home = os.path.expanduser("~")
    em = ttygrid.Emulator(ccdrive.COLS, ccdrive.ROWS)
    surface = ccontrast.Surface(dark=dark)
    session = ccdrive.Session(home, emulator=em, cwd=cwd, binary=binary, surface=surface)
    session.pump(SETTLE)

    under, worst = {}, None
    for name, keys, marker in SCREENS:
        for key in keys:
            session.send(key.encode().decode("unicode_escape"), 2.5)
        session.pump(1.0)
        screen = em.text()
        runs = [r for r in ccontrast.runs(em, surface) if r.kind in ("text", "chrome")]
        check(f"[{label}] the {name} screen rendered",
              marker in screen and len(runs) >= 20,
              f"{len(runs)} runs, marker {'found' if marker in screen else 'MISSING'}")
        low = min(runs, key=lambda r: r.ratio) if runs else None
        if low and (worst is None or low.ratio < worst.ratio):
            worst = low
        for r in runs:
            if not r.ok:
                under.setdefault(ccontrast.hexof(r.fg), r)
    session.close()

    check(f"[{label}] nothing renders below the recorded pin of {PIN}:1",
          worst is not None and worst.ratio >= PIN, f"worst {worst}" if worst else "no runs")
    scheme = next((l.strip() for l in screen.split("\n") if l.strip().startswith("Color Scheme")), None)
    if scheme:
        print(f"  NOTE  [{label}] agy's settings panel reports: {scheme!r} — Synth writes this key "
              f"deliberately not at all; see the module docstring for the four schemes measured",
              flush=True)
    if under:
        print(f"  NOTE  [{label}] below WCAG, and not Synth's to move: "
              + "; ".join(f"{ccontrast.hexof(r.fg)} on {ccontrast.hexof(r.bg)} {r.ratio:.2f}:1 "
                          f"(needs {r.floor}) {r.text.strip()[:18]!r}"
                          for r in under.values()), flush=True)

# The reason there is no theme to ship. A change here is good news, so it is a note.
print("\n--- recorded, not gated ---", flush=True)
cwd = workspace("probe")
home = os.path.expanduser("~")
em = ttygrid.Emulator(ccdrive.COLS, ccdrive.ROWS)
seen = bytearray()
_feed = em.feed
em.feed = lambda b: (seen.extend(b) if isinstance(b, (bytes, bytearray)) else None, _feed(b))[1]
probe = ccdrive.Session(home, emulator=em, cwd=cwd, binary=binary,
                        surface=ccontrast.Surface(dark=False))
probe.pump(SETTLE)
answered = dict(probe.answered)
probe.close()
probes = {
    "OSC 11 (background)": len(re.findall(rb"\x1b\]11;\?", bytes(seen))),
    "OSC 10 (foreground)": len(re.findall(rb"\x1b\]10;\?", bytes(seen))),
    "DEC 2031 (theme changes)": len(re.findall(rb"\x1b\[\?2031h", bytes(seen))),
}
print(f"  NOTE  agy asked the terminal nothing about its colours: {probes} "
      f"(answered {answered}) — it cannot tell a light surface from a dark one, so any non-zero "
      f"here is a reason to revisit", flush=True)

sys.exit(result())
