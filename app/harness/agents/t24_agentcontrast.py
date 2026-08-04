"""Agent contrast gate: what Claude Code itself paints, decoded from the bytes it emits.

`t13_termcontrast` gates the sixteen palette slots a terminal owns. Claude Code does not use them —
it paints with a truecolor theme of its own, roughly seventy tokens deep — so everything a reader
actually looks at inside a session is invisible to that suite. This one measures those.

It replays a real session through `ttygrid` (a terminal just complete enough to resolve a cell's
colour) and reads out every run of ink with the background it sits on. Replaying rather than reading
the theme file is the point: a TUI sets a foreground once and moves the cursor around for a dozen
lines, paints a background a later erase reverts, and redraws a row three times before the frame
settles. Only the settled grid is what a reader sees.

The two halves are held to different standards, and it is the same split `t13` makes:

  • **Light is Synth's claim.** `AgentTheme.lightOverrides` exists because Claude Code's light theme
    was measured on Synth's surface and found wanting — `subtle`, the grey every hint and timestamp
    is written in, sat at 2.06:1. So light is gated at WCAG 2.1: 4.5:1 for text (1.4.3), 3:1 for
    box drawing and bars (1.4.11).
  • **Dark is Claude Code's own**, ridden untouched, because dark is what all of these colours were
    chosen against. Gating it at 4.5 would fail on shipped, accepted behaviour, so dark is pinned
    just under what it actually renders today — not a claim, a tripwire for it getting worse.

Asserted:
  • every light override clears the floor for its role, read out of the Swift rather than restated
    here, so the gate cannot pass a table Synth does not ship
  • every text and chrome run in a real light session clears its floor
  • dark renders no worse than the numbers recorded below
  • a *running* session re-themes when the theme file changes — the whole fix rests on Claude Code
    watching `~/.claude/themes`, and nothing else in the product would notice if that stopped

Recorded but not asserted, because neither is a lever Synth holds:
  • the syntax highlighter, which is a separate palette selected wholesale (GitHub / Monokai / ansi)
    from the resolved base — the asserted passes run with `CLAUDE_CODE_SYNTAX_HIGHLIGHT=0` so the
    theme's own colours are measured in isolation rather than blamed for it
  • `theme: "auto"`, which does not match the terminal — the reason `AgentTheme` adopts it
"""
import os, re, sys, time

sys.path.insert(0, ".")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import lib
from lib import *

import ccdrive
import ccontrast
import ttygrid

HERE = os.path.dirname(os.path.abspath(__file__))
AGENT_THEME = os.path.normpath(os.path.join(HERE, "../../Sources/Synth/Ghostty/AgentTheme.swift"))

# Roles that are not text, and so answer to 3:1 rather than 4.5:1. Kept in step with the same split
# in AgentTheme, and named here so a reader can see there are only three of them.
NON_TEXT = {"promptBorder", "bashBorder", "rate_limit_fill"}

# Tokens Claude Code hands to its badge component as a *background*, which then paints `inverseText`
# — white — on them unless a caller says otherwise. So each of these has to clear the floor twice:
# as ink on the surface, and as a fill under white.
#
# This is the check that would have caught `diffAddedWord`, where deepening a value as ink drove the
# ink *on* it from ~17:1 to 4.28:1. It cuts the other way here, which is the point of measuring
# rather than assuming: the subagent hues are a badge fill, and deepening them lifted white-on-them
# from 2.93–3.76 (all failing) to 4.89–4.93.
WHITE = (0xff, 0xff, 0xff)
BADGE_FILLS = {k for k in ("red", "blue", "green", "yellow", "purple", "orange", "pink", "cyan")}
BADGE_FILLS = {f"{k}_FOR_SUBAGENTS_ONLY" for k in BADGE_FILLS} | {"professionalBlue", "permission"}

# One colour on screen belongs to no theme at all. Forcing *every* token in the theme to magenta and
# re-rendering left this one untouched, which is the proof: it is hard-coded in Claude Code, reaches
# the file path in a `Bash(...)` header, and no override can move it. Recorded so the gate does not
# fail on something Synth cannot fix, and so the day it changes is visible.
NOT_THEMEABLE = {"#5769f7"}

# What Claude Code's dark theme renders today, on the dark card. Both are its own colours, and both
# are why dark is pinned instead of gated: the `❯` prompt marker on the composer fill, and white on
# the word-level highlight inside a diff line.
DARK_PIN = {"text": 3.0, "chrome": 1.4}

SETTLE = 15.0


def light_overrides():
    """The table Synth actually ships, parsed out of the Swift.

    Restating the values here would let the gate pass a theme the app does not write, which is the
    one failure a colour gate must not have.
    """
    src = open(AGENT_THEME).read()
    body = src.split("lightOverrides: [String: String] = [", 1)[1].split("\n    ]", 1)[0]
    return dict(re.findall(r'"([A-Za-z_0-9]+)":\s*"(#[0-9a-fA-F]{6})"', body))


def render(base, overrides, tag, highlight=False):
    """A real session, resumed from the fixture transcript, replayed onto a grid."""
    cwd = os.path.join(lib.H, f"t24-{tag}")
    os.makedirs(cwd, exist_ok=True)
    home = ccdrive.seed_home(os.path.join(lib.H, f"t24-home-{tag}"), "custom:synth", cwd)
    ccdrive.write_theme(home, base, overrides)
    em = ttygrid.Emulator(ccdrive.COLS, ccdrive.ROWS)
    env = {} if highlight else {"CLAUDE_CODE_SYNTAX_HIGHLIGHT": "0"}
    s = ccdrive.Session(home, args=[*ccdrive.CLAUDE_ISOLATION, "--resume", ccdrive.SESSION_ID],
                        emulator=em, env_extra=env, cwd=cwd)
    s.pump(SETTLE)
    return em, s, home


# A line only the fixture transcript can put on screen. Without this the suite happily measures
# whatever Claude Code opened on instead — a trust prompt has four colours and passes everything.
FIXTURE_MARK = "the reorder guard"


def gate(base, dark, floors, label):
    em, s, _ = render(base, {} if dark else light_overrides(), label)
    surface = ccontrast.Surface(dark=dark)
    runs = ccontrast.runs(em, surface)
    s.close()

    check(f"[{label}] the fixture session rendered, not some other screen",
          FIXTURE_MARK in em.text() and len(runs) >= 60,
          f"{len(runs)} runs, marker {'found' if FIXTURE_MARK in em.text() else 'MISSING'}")

    exempt = [r for r in runs if ccontrast.hexof(r.fg) in NOT_THEMEABLE]
    for kind, floor in floors.items():
        pool = [r for r in runs
                if r.kind == kind and ccontrast.hexof(r.fg) not in NOT_THEMEABLE]
        worst = min(pool, key=lambda r: r.ratio) if pool else None
        check(f"[{label}] every {kind} run clears {floor}:1",
              worst is not None and worst.ratio >= floor,
              f"worst {worst}" if worst else "no runs of this kind")

    for r in {ccontrast.hexof(x.fg): x for x in exempt}.values():
        print(f"  NOTE  [{label}] not reachable by any theme, so not gated "
              f"(would need {r.floor}): {r}", flush=True)


print("=== T24: agent contrast — the colours Claude Code paints ===")

if not ccdrive.claude_binary():
    skip("no `claude` CLI on PATH (only Synth's shim resolves)")

print("\n--- the light overrides Synth ships ---", flush=True)
ov = light_overrides()
check("AgentTheme.lightOverrides was parsed", len(ov) >= 15, f"{len(ov)} tokens")
worst = None
for token, value in sorted(ov.items()):
    floor = ccontrast.CHROME_FLOOR if token in NON_TEXT else ccontrast.TEXT_FLOOR
    ratio = ccontrast.contrast(ccontrast._hex(value.lstrip("#")), ccontrast.LIGHT_BG)
    if worst is None or ratio - floor < worst[0]:
        worst = (ratio - floor, token, value, ratio, floor)
check("every light override clears the floor for its role on #f7f8fa",
      worst is not None and worst[0] >= 0,
      f"tightest {worst[1]} {worst[2]} = {worst[3]:.2f}:1 (needs {worst[4]})" if worst else "none")

tight = None
for token in sorted(BADGE_FILLS):
    value = ov.get(token)
    if value is None:
        continue          # not overridden: Claude Code's own value, not Synth's claim to make
    ratio = ccontrast.contrast(WHITE, ccontrast._hex(value.lstrip("#")))
    if tight is None or ratio < tight[1]:
        tight = (token, ratio, value)
check("every overridden badge fill also carries white text at 4.5:1",
      tight is not None and tight[1] >= ccontrast.TEXT_FLOOR,
      f"tightest white on {tight[0]} {tight[2]} = {tight[1]:.2f}:1" if tight else "none overridden")

print("\n--- light: Synth's claim, gated at WCAG ---", flush=True)
gate("light", False, {"text": ccontrast.TEXT_FLOOR, "chrome": ccontrast.CHROME_FLOOR}, "light")

print("\n--- dark: Claude Code's own, pinned where it ships ---", flush=True)
gate("dark", True, DARK_PIN, "dark")

# The mechanism the fix rests on. `theme` in ~/.claude.json is read once at startup, so re-theming a
# session already on screen is only possible because Claude Code watches the custom-theme directory.
# If that ever stops, light mode silently goes back to whatever each session launched with.
print("\n--- the live lever: does a running session follow the theme file? ---", flush=True)
em, s, home = render("dark", {}, "live")
surface = ccontrast.Surface(dark=True)
before = {ccontrast.hexof(r.fg) for r in ccontrast.runs(em, surface)}
check("the live-lever session started on the dark theme",
      FIXTURE_MARK in em.text() and len(before) >= 5, f"{len(before)} foregrounds")
ccdrive.write_theme(home, "light", light_overrides())
time.sleep(3.0)
s.repaint()
after = {ccontrast.hexof(r.fg) for r in ccontrast.runs(em, ccontrast.Surface(dark=False))}
s.close()
# The light and dark halves of Claude Code's theme share almost no values, so a frame that re-themed
# looks nothing like the one before it. Comparing colour *sets* keeps this off any single token, and
# a majority is the threshold because a few neutrals (and the hard-coded colour above) never move.
gone = before - after
check("a running session re-themes when the theme file changes",
      len(gone) > len(before) / 2,
      f"{len(gone)} of {len(before)} dark foregrounds were gone after the rewrite")

# Recorded, not gated. `AgentTheme` adopts `auto` because it does not do what its name says; if that
# is ever fixed, this note stops matching and the adoption can be reconsidered.
print("\n--- recorded, not gated ---", flush=True)
em, s, _ = render("light", light_overrides(), "syntax", highlight=True)
syntax = [r for r in ccontrast.audit(em, ccontrast.Surface(dark=False))
          if ccontrast.hexof(r.fg) not in NOT_THEMEABLE]
s.close()
print("  NOTE  [light] the syntax highlighter is a separate palette Synth does not select: "
      + (", ".join(f"{ccontrast.hexof(r.fg)} on {ccontrast.hexof(r.bg)} {r.ratio:.2f}:1"
                   for r in syntax) or "nothing under floor"), flush=True)

sys.exit(result())
