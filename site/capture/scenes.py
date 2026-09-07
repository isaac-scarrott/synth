"""Everything curated about the landing page's screenshots.

This is the file to edit. `capture.py` holds none of it: it clones repos, boots the app, drives
a real agent and presses the shutter, and it reads everything it is *about* from here.

The figures are meta on purpose — the work on screen is the work of building this site. The
agent rows are live `claude` processes doing real reading in a real clone of this repo, and the
page in the browser and on the phone is `site/index.html` itself. Nothing here is a mock-up of
the product; the only authored parts are which repos, which branches, and what the agent is
asked to do.

Why Python and not TOML: half of what follows is prose about the other half — why this branch,
why this prompt, what a field does to the picture. TOML can carry the values but not the
explanation, and a module needs no parser and no dependency.
"""

import os

# ─────────────────────────────────────────────────────────────────────────────
# The frame
# ─────────────────────────────────────────────────────────────────────────────

# Window size in points; captures come back at 2× this on a retina display. Wider than tall,
# because every figure sits in a page column narrower than it is.
#
# Height is set by the sidebar, which is the taller of the two columns. AppKit will not go below
# 480 (the window's own minimum), so this is nearly the tightest frame the app has.
WINDOW = (1180, 490)

# "light" or "dark". The page is dark; the app's champagne accent exists only in its dark theme.
# Scenes marked `dark_too` below record both so the choice can be made by looking.
THEME = "light"

# Extra flags handed to every spawned `claude`, as the app's own Settings → agent defaults would.
# Empty on purpose: the agent is only asked to read and to ask a question, so it needs no
# permission it does not already have, and a live agent in a clone should still be a normal one.
CLAUDE_FLAGS = ""


# ─────────────────────────────────────────────────────────────────────────────
# The tree — three real repos, cloned
# ─────────────────────────────────────────────────────────────────────────────
#
# Every project is a real repository on this machine, cloned into a scratch directory. Never the
# working checkout: a live coding agent is turned loose in these, and the one thing that must
# not be at risk is the repo the owner is actually working in.
#
# `base` is the clone's own default branch — `dev-files` is on `master`, not `main`, and a
# worktree cut from the wrong name fails silently into an empty sidebar.
#
# `chip` is AN INDEX, NOT A COLOUR. Synth has exactly six identity hues (Theme.chipColors) and a
# project wears one of them; there is nowhere to put a hex, and a hex here would be a colour the
# product cannot wear. They are, in order:
#     0 violet #7569B5   1 teal-blue #477B90   2 olive #7B773D
#     3 green  #3E7E74   4 rose      #AD587F   5 magenta #A158AD
# Projects side by side want indices that read apart at chip size.
#
# Per session:
#   key      a name for this rig only: it seeds the session's UUID and is how a scene says "open
#            this one". Never appears on screen.
#   kind     "terminal", "browser", "simulator", or an agent id ("claudeCode", "opencode",
#            "antigravity"). An agent row spawns that agent for real when its tab is opened.
#   title    the row's label. Curated rather than left to the agent's own auto-title, so the
#            owner names the rows and only the *content* varies between runs.
#   prompt   delivered to a live agent once it is up. One turn per row: real output costs real
#            quota and varies run to run, so the prompt has to reach the state the figure needs
#            in a single pass.
#   signals  hook signals applied in order, staging a row that is not a live agent. One of
#            working / needsInput / error / idle / term-run / term-idle / term-error.
#            `idle` also marks the row unread.
#   url      a browser row's page. `{site}` becomes the local server's origin.

REPOS = {
    "synth":     "~/git/synth",
    "lilo":      "~/git/lilo",
    "dev-files": "~/git/dev-files",
}

PROJECTS = [
    {
        "name": "synth",
        "repo": "~/git/synth",
        "base": "main",
        # Paths copied from the checkout into the clone after cloning, for work that is not
        # committed yet. The landing page is exactly that — a clone without it makes the agent
        # answer, correctly and uselessly, that there is no such directory.
        "copy_in": ["site"],
        "chip": 1,
        "branches": [
            {"name": "main", "sessions": []},

            # The branch the hero is about, and the meta: an agent reading this site's own source
            # while the picture of it is being taken. Its Claude row is what puts the `?` on the
            # branch, since in tabs mode a branch's roll-up is the only place session state shows.
            {
                "name": "site/landing-page",
                "expanded": True,
                "sessions": [
                    {"key": "claude", "kind": "claudeCode", "title": "landing page",
                      # Arrow-key selection asks for an interactive question: prose options end
                      # idle, losing the needs-input badge. Short options fit the narrower pane.
                     "prompt":
                         "Read site/index.html and check how the hero adapts to a narrow "
                         "browser pane. Summarise what you find in three short bullets. "
                         "Before changing anything, give me a multiple-choice question "
                         "with three layout options I can select using the arrow keys. "
                         "Keep each option to one line and wait for my selection."},
                    {"key": "devserver", "kind": "terminal", "title": "dev server",
                     "signals": ["term-run"]},
                    {"key": "web", "kind": "browser", "title": "localhost:3000",
                     # "/" and not "/index.html": the address bar is in the picture, and the
                     # extension is the tell of a static file server rather than a dev server.
                     "url": "{site}/", "signals": ["idle"]},
                ],
            },
        ],
    },
    {
        # A pnpm monorepo: apps/agent-inspector in front of services/agent-service. The branch is
        # named after the service, and its session is the one that failed.
        "name": "lilo",
        "repo": "~/git/lilo",
        "base": "main",
        "chip": 4,
        "branches": [
            {
                "name": "fix/agent-service-retry",
                "sessions": [
                    {"key": "tests", "kind": "terminal", "title": "pnpm test",
                     "signals": ["term-error"]},
                ],
            },
        ],
    },
    {
        # Dotfiles and machine setup — bin/, scripts/, and the MCP manifest the install script
        # generates. Nothing is happening here, which is the point: the badges elsewhere mean
        # something because most of the tree is quiet.
        "name": "dev-files",
        "repo": "~/git/dev-files",
        "base": "master",
        "chip": 2,
        "branches": [
            {
                "name": "chore/mcp-manifest",
                "sessions": [
                    {"key": "shell", "kind": "terminal", "title": "shell", "signals": []},
                ],
            },
        ],
    },
]


# ─────────────────────────────────────────────────────────────────────────────
# The page the browser and the phone show
# ─────────────────────────────────────────────────────────────────────────────
#
# This site, served from the working checkout, read-only. Not an invented product page: the
# figures are about building this, so the page in the picture may as well be the page.

SITE_ROOT = os.path.expanduser("~/git/synth/site")
# The path the browser row opens. "/" rather than "/index.html", because the address bar is in
# the picture and `localhost:3000/index.html` is the tell of a static file server — a person
# running a dev server sees `localhost:3000`.
PAGE = "/"


# ─────────────────────────────────────────────────────────────────────────────
# The comments pinned on it
# ─────────────────────────────────────────────────────────────────────────────
#
# `at` is a CSS selector that must resolve on the served page; `text` is what the person leaving
# the comment says. The rig clicks each element with comment mode on, so the pins, the composer
# and the island are the product's own.
#
# Both must be in the page's FIRST screen: a pin left further down scrolls the page to reach it,
# and the figure then shows the middle of the page rather than the top of it.
#
# Both are things somebody would really say about this page — the second one is the note that
# started this whole rig.

COMMENTS = [
    {"at": "h1",
     "text": "This headline is doing two jobs. The second half is the whole pitch."},
    {"at": ".hero__stage",
     "text": "This figure is drawn in HTML. It should be a screenshot of the app it describes."},
]


# ─────────────────────────────────────────────────────────────────────────────
# The worktree an agent asks for — the ⌘K approval frame
# ─────────────────────────────────────────────────────────────────────────────
#
# `asked_by` names a session key above; the frame quotes that row's title as the requester.
# The branch is the next piece of this same work, so the card is about the site too.

APPROVAL = {
    "asked_by": "claude",
    "branch": "site/capture-rig",
    "base": "main",
    "handoff": "Record the landing page's figures from the real app instead of drawing them.",
}


# ─────────────────────────────────────────────────────────────────────────────
# The simulator
# ─────────────────────────────────────────────────────────────────────────────
#
# Mobile Safari on the same page, so the figure is this site's own responsive layout rather than
# a mock-up of somebody's checkout. `device` is matched by name against the installed fleet; if
# nothing matches, or there is no Xcode, the scene skips and says so.

SIMULATOR = {"device": "iPhone 16 Pro", "page": PAGE}


# ─────────────────────────────────────────────────────────────────────────────
# The scenes
# ─────────────────────────────────────────────────────────────────────────────
#
#   what       one line, printed by the run and repeated in the README.
#   open       the session key whose pane fills the window. None leaves the pane empty.
#   split      right-hand session key and the left pane's fraction of the content width.
#   window     overrides WINDOW for this scene.
#   palette    True captures the floating ⌘K panel instead of the app window.
#   dark_too   also record the scene in the dark theme, as `<scene>-dark@2x.png`.

SCENES = {
    "hero": {
        "what": "the whole window: Claude Code beside the live landing page",
        "open": "claude",
        "split": {"right": "web", "fraction": 0.55},
        # Taller than the rest. This figure has to show a whole turn — what the agent read, what
        # it found, and the question it stopped on — and the question alone fills the shared
        # height. The sidebar runs out before the pane does, which is the right way round here:
        # the transcript is the subject.
        "window": (1180, 660),
        # The state this figure IS. A turn that ends idle has no badge on the tab, no roll-up on
        # the branch and no question in the pane — a different picture wearing the same name — so
        # the run re-takes it rather than shipping it.
        "expect": "needsInput",
        "dark_too": True,
    },
    "browser": {
        "what": "a browser session showing this landing page, with two comments pinned on it",
        "open": "web",
        # Tall enough that the page's own first screen fits: at the shared height the page
        # scrolls to reach the second pin and the headline leaves the picture.
        "window": (1180, 780),
        # The page is dark and the app is light, so this figure is a dark rectangle inside a
        # light window. Worth seeing against the all-dark version before choosing.
        "dark_too": True,
    },
    "simulator": {
        "what": "this landing page's mobile layout, in Safari on a booted iPhone",
        "open": None,
        "window": (1180, 760),           # a phone is tall; the pane needs the room
        "dark_too": True,
    },
    "approval": {
        "what": "the ⌘K frame an agent's request for a worktree stops on",
        "open": "claude",
        # The window is cropped away, so the row only has to BE a live agent — it is the
        # requester the card names. No turn is spent on it.
        "drive": False,
        "palette": True,
        "window": (1520, 700),           # room for the panel to float in, whatever width it takes
        "dark_too": True,
    },
    "attention": {
        "what": "the notification deck: what is waiting, what failed, what finished",
        "open": "claude",
        # Brought up live, but not prompted: the deck's card is raised by a status transition,
        # and the transcript behind it is not in the picture. A turn here would buy nothing.
        "drive": False,
        "dark_too": True,
    },
}
