# Screenshots of the real app

The landing page's product figures, recorded from Synth itself rather than drawn in HTML.

The figures are meta on purpose: the work on screen is the work of building this site. The agent
rows are live `claude` processes reading this repo in a clone of it, and the page in the browser
and on the phone is `site/index.html` itself.

```sh
python3 site/capture/capture.py             # every scene → site/img/<scene>@2x.png
python3 site/capture/capture.py --only hero # re-record one
python3 site/capture/capture.py --build     # rebuild the app bundle first
python3 site/capture/capture.py --invisible # leave the desktop alone; see "Two capture paths"
```

**A run takes the screen** — Synth comes to the front for each shot — **and it spends real Claude
quota.** Don't use the Mac while it runs, and don't re-record scenes that haven't changed.

**Park the pointer at the edge of the screen first.** A pointer resting over the window hovers
whatever row is under it, and that hover lands in the capture: a sidebar row shot with its archive
and add buttons showing reads as mis-selected.

## Changing what the pictures say

Everything curated lives in **`scenes.py`** — which repos, which branches, session titles, what
the agent is asked to do, the comments, the approval card's branch, window sizes, the theme.
`capture.py` knows how to stage a scene, not what is in one.

The agent prompt is the most delicate value in the file. It is **in the picture** — the pane
echoes it above the answer — so it has to read as something a person would really have typed;
an earlier version said "use your question tool to ask me…", which is nobody's sentence and made
a real session look scripted. It also has to produce a turn of the right *shape*: long enough
that Claude's startup banner (which prints the absolute scratch worktree path) scrolls off the
top, and ending in a question compact enough to leave the work visible above it.

Three other things there are not free text:

- **`repo` must be a real repository on this machine.** It is cloned into scratch; the checkout
  is never used, because a live coding agent runs in these.
- **`base` must be the clone's real default branch.** `dev-files` is on `master`, not `main`, and
  a worktree cut from a name that does not exist fails into an empty sidebar.
- **`chip` is an index, not a colour.** Synth has six identity hues and a project wears one.
- **`expect` is the state the figure *is*.** A live agent is not deterministic: asked to stop and
  ask, it sometimes answers in prose instead, which never reaches needs-input — and a hero whose
  agent went idle has no badge on the tab, no roll-up on the branch and no question in the pane.
  When a take misses its `expect`, the run re-takes it (up to three goes) rather than shipping a
  picture of the wrong thing.

## The trust prompt — answered once, up front

The first time a live `claude` runs in a scratch worktree it stops on *"Is this a project you
created or one you trust?"*. Until that is answered the agent never goes live and every agent
figure is a picture of that question.

The rig does not answer it for you — it is a security prompt, and the answer belongs to whoever
owns the machine. It cannot be seeded either: the answer lives in your own `~/.claude.json`, and a
Synth terminal is wrapped in macOS `login`, which resets `HOME` before the shell starts, so a home
of the rig's own never reaches the agent.

So every agent the run will need is brought up **before the first shot**, together, and the run
holds there once — naming the worktree each prompt belongs to and bringing it into view, because
three identical dialogs with nothing to tell them apart is a guessing game. Being interrupted once
before the run beats being interrupted three times during it.

Nothing to answer is the normal case. The worktree paths do not change between runs, so once a
branch is trusted the preflight prints `every worktree is already trusted — nothing to answer` and
returns in the time it takes Claude to boot.

## Two capture paths

| | default | `--invisible` |
| --- | --- | --- |
| window | visible, brought to the front | parked at zero alpha, off the Dock |
| capture | `screencapture -l <windowNumber>` | the app renders its own content view |
| browser page | **renders** | blank |
| simulator screen | **renders** | black |
| everything else | identical | identical |

A CEF page lives in a child view owned by another process, and the simulator's screen is an
`AVSampleBufferDisplayLayer` composited on the GPU. Neither is in the app's own view hierarchy, so
only the window server has that picture — and it only composites what is really on a display.

## Both experiments are on

Every scene runs with **tabs mode** and **simulator sessions** enabled, pinned per-process through
`NSArgumentDomain` (`-synth-tabs "<true/>"` and friends — a property-list literal, not the word
`YES`, which `object(forKey:) as? Bool` reads as nil).

Tabs mode changes the picture: `Sidebar.swift` drops session rows entirely, so **the sidebar shows
projects and branches only**, each branch carrying a session count and its status roll-up, and
sessions become a tab strip above the pane. Per-session state lives in the strip now.

## The scenes

| file | what it shows |
| --- | --- |
| `hero@2x.png` | Claude Code on the left (55%), the live landing page on the right (45%) |
| `browser@2x.png` | a browser session showing this landing page, two comments pinned on it |
| `simulator@2x.png` | this page's mobile layout, in Safari on a booted iPhone |
| `approval@2x.png` | the ⌘K frame an agent's worktree request stops on, cropped to the card |
| `attention@2x.png` | the notification deck, over the page |

Every scene also records a dark twin (`<scene>-dark@2x.png`) — the page is dark and the app's
champagne accent exists only in the dark theme, so both are worth having side by side. Add or
remove `"dark_too": True` in `scenes.py`.

Two things the scenes deliberately avoid: an agent row is never seeded with an agent *kind* and
then left unopened (opening is what spawns it), and no figure leaves a bare shell in the pane —
a shell prompt carries the machine's user and hostname, which is not something to publish.

## Prerequisites

- **Screen Recording permission** for whatever runs the script. Without it `screencapture -l`
  returns an empty frame; the rig checks and fails loudly rather than writing a blank PNG.
- **Claude Code**, signed in. The agent rows are real.
- **Xcode**, for the simulator scene. Without it that scene skips with a stated reason and the
  rest of the run continues.
- **node**, plus a `playwright-core` install — Synth's own MCP install (`~/Library/Application
  Support/Synth/browser-mcp/node_modules`) is the one that is normally there. Without it the
  browser scene captures comment mode with no comments pinned.
- **CEF**, in the bundle. `build.sh` refuses to produce a bundle without it.
- Port **3000** free, so the browser row's address bar says what the fiction says. Taken, the run
  serves on an ephemeral port and says so.

## What runs where

Everything lives in `$TMPDIR/synth-capture`: the clones, the worktrees, the seeded `state.json`,
the app's Application Support sandbox, the logs. Nothing is written to `~/Library/Application
Support/Synth` or `Synth Dev`. The served page is the working checkout's `site/`, read-only.

The bundle is **`Synth Capture.app`**, built to its own path by `build.sh` and launched by nothing
else. Teardown matches on that exact executable, so a capture run cannot take down the Synth its
owner is working in.

## How it fails

- **"claude never came up"** — nearly always the trust prompt above.
- **"Synth never answered"** — the app died during launch. `$TMPDIR/synth-capture/logs/<scene>.log`
  has its stderr.
- **"the hook socket is not answering"** — the app exited part-way through a scene. Same log.
- **"screencapture -l … came back empty"** — the window server had nothing current for that
  window. Almost always Screen Recording permission.
- **"not every comment landed"** — a selector in `scenes.COMMENTS` did not resolve, or its element
  is not in the page's first screen. The run says how many of them the island is holding.
- **The simulator scene skips.** No Xcode, no matching device, or a device that never finished
  booting. It also saves the device's own frame to
  `$TMPDIR/synth-capture/logs/simulator-device.png`, which distinguishes "the device is not
  showing the page" from "the capture missed it".

## Weight

Captures land at 2× (retina backing scale). The ones showing this page are the heavy ones — it has
a photographic background — at 500–780 KB; the rest are 150–290 KB. Run them through
`oxipng`/`pngquant`, or serve WebP, before shipping.
