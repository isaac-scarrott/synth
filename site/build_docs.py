#!/usr/bin/env python3
"""Build site/docs/ from site/docs-src/.

Three things this exists to guarantee, none of which a hand-written set of pages can:

1. **One stylesheet.** Every docs page carries `index.html`'s own `<style>` block verbatim,
   read at build time, plus `docs.css` on top. The landing page stays the single source of
   truth for tokens and components. Two hand-synced copies of a palette is how `landing/`
   drifted before it was deleted.
2. **A reference that cannot lie.** The keyboard page is read out of `Shortcuts.swift` and the
   tool catalogue out of the three MCP servers. Both are the same source the app ships, so a
   binding renamed in Swift is a binding renamed on the page or a build that fails loudly.
3. **One shell.** Nav, sidebar, contents rail and footer are written once here.

    python3 site/build_docs.py [--check]

`--check` builds into memory and fails if the tree on disk differs, which is what a
pre-deploy guard wants.
"""
import html
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(ROOT)
SRC = os.path.join(ROOT, "docs-src")
OUT = os.path.join(ROOT, "docs")
LANDING = os.path.join(ROOT, "index.html")
DOCS_CSS = os.path.join(ROOT, "docs.css")

SWIFT_SHORTCUTS = os.path.join(REPO, "app/Sources/Synth/Shortcuts.swift")
MCP_SERVERS = [
    ("browser", "synth-browser", os.path.join(REPO, "mcp/server.mjs")),
    ("simulator", "synth-simulator", os.path.join(REPO, "mcp/simulator-server.mjs")),
    ("app", "synth-app", os.path.join(REPO, "mcp/app-server.mjs")),
]

# The order is the reading order, and it is also the sidebar. A page absent from here is
# not built, so adding one is a deliberate act rather than a side effect of a stray file.
NAV = [
    ("Start", [
        ("index", "Start here"),
        ("concepts", "How Synth is organised"),
    ]),
    ("Working in Synth", [
        ("branches", "Branches and worktrees"),
        ("sessions", "Sessions"),
        ("agents", "Agents"),
        ("attention", "Knowing who needs you"),
        ("configuration", "Configuration"),
    ]),
    ("Reference", [
        ("keyboard", "Keyboard reference"),
        ("tools", "Agent tools"),
        ("troubleshooting", "Troubleshooting"),
    ]),
]

PAGES = [slug for _, group in NAV for slug, _ in group]
TITLES = {slug: title for _, group in NAV for slug, title in group}


class BuildError(Exception):
    pass


# ─────────────────────────── the landing page's own CSS ───────────────────────────

URL_RE = re.compile(r"""url\(\s*(['"]?)(?!(?:https?:|data:|//|/|\#))([^'")]+)\1\s*\)""")


def relocate_urls(css, prefix="../"):
    """Point the borrowed stylesheet's relative URLs back at the directory it came from.

    An inlined `@font-face` resolves its `url()` against the *document*, not against the file
    the CSS was written in, so `url("fonts/Geist-Variable.woff2")` asks for
    `/docs/fonts/...` and 404s. Every docs page rendered in the system fallback instead of
    Geist until this existed, and nothing on the page said so: a missing font is invisible
    unless you go looking for it.
    """
    return URL_RE.sub(lambda m: 'url("%s%s")' % (prefix, m.group(2).strip()), css)


def landing_nav():
    """index.html's own header, so the bar is one component rather than two that resemble
    each other.

    Borrowed the same way the stylesheet is, and for the same reason: a nav written twice is a
    nav that drifts, and the docs copy had already drifted into a different shape with a
    different link in it. Only the relative URLs move, because a docs page sits one directory
    down; `#top` becomes the landing page itself, since from here that anchor is a page.
    """
    with open(LANDING, encoding="utf-8") as f:
        src = f.read()
    opens = src.count("<header")
    if opens != 1 or src.count("</header>") != 1:
        raise BuildError("index.html has %d <header>; this build assumes exactly one" % opens)
    nav = src[src.index("<header"):src.index("</header>") + len("</header>")]

    def relocate(m):
        attr, ref = m.group(1), m.group(2)
        if ref.startswith(("http", "mailto", "data:", "/")):
            return m.group(0)
        if ref == "#top":
            # The one anchor that is a page from here, not a place on this one.
            ref = "../"
        elif ref.startswith("#"):
            return m.group(0)
        elif ref == "docs/":
            ref = "./"
        else:
            ref = "../" + ref
        return '%s="%s"' % (attr, ref)

    return re.sub(r'\b(href|src)="([^"]*)"', relocate, nav)


def landing_css():
    """The whole of index.html's style block, so docs inherits tokens and components.

    Located by exact tag, never by a regex across the file: index.html contains prose
    about HTML, and a lazy `<style>.*?</style>` would happily match through it.
    """
    with open(LANDING, encoding="utf-8") as f:
        src = f.read()
    opens, closes = src.count("<style>"), src.count("</style>")
    if opens != 1 or closes != 1:
        raise BuildError(
            "index.html has %d <style> and %d </style>; this build assumes exactly one of each"
            % (opens, closes))
    start = src.index("<style>") + len("<style>")
    css = src[start:src.index("</style>")].strip("\n")

    # Every asset the borrowed CSS names has to exist one level up, or the page silently
    # degrades. Checked here so a renamed font is a failed build rather than a flat page.
    css = relocate_urls(css)
    for ref in re.findall(r'url\("\.\./([^"]+)"\)', css):
        if not os.path.exists(os.path.join(ROOT, ref)):
            raise BuildError("index.html's CSS references %s, which is not in site/" % ref)
    return css


# ─────────────────────────── generated: keyboard reference ───────────────────────────

CATEGORY_RE = re.compile(r'ShortcutCategory\(name:\s*"([^"]+)"')
SHORTCUT_START_RE = re.compile(r"Shortcut\(keys:\s*")
LABEL_RE = re.compile(r'\s*,\s*label:\s*"([^"]+)"', re.S)
ALT_RE = re.compile(r"\s*,\s*alt:\s*")


def _keys(literal):
    """The strings inside a Swift array literal, read as literals rather than split on commas.

    `["⌘", "]"]` is why: a `[^\\]]*` capture stops at the bracket inside the string and drops
    the whole binding without a word. Forward was missing from this page for exactly that
    reason before the scan replaced the match.
    """
    return re.findall(r'"((?:[^"\\]|\\.)*)"', literal)


def parse_shortcuts():
    """Every binding the ⌘? sheet lists, read out of the Swift that renders it.

    The file also builds a tabs-mode variant of the same list; that is a different view of
    these rows, so only the base categories plus the Tabs group are taken, and the tabs-mode
    substitutions are described in prose on the page instead of duplicated as a second table.

    Rows are assigned to the category they follow by file position, so the two patterns are
    matched over the whole source once rather than line by line.
    """
    with open(SWIFT_SHORTCUTS, encoding="utf-8") as f:
        src = f.read()

    marks = [(m.start(), "cat", m.group(1)) for m in CATEGORY_RE.finditer(src)]
    for m in SHORTCUT_START_RE.finditer(src):
        i = m.end()
        if i >= len(src) or src[i] != "[":
            continue
        keys, i = _balanced(src, i, "[", "]")
        label = LABEL_RE.match(src, i)
        if not label:
            raise BuildError("Shortcut at offset %d has no label" % m.start())
        i = label.end()
        alt = ALT_RE.match(src, i)
        alt_keys = []
        if alt and src[alt.end()] == "[":
            raw, i = _balanced(src, alt.end(), "[", "]")
            alt_keys = _keys(raw)
        marks.append((m.start(), "row", {
            "keys": _keys(keys), "label": label.group(1), "alt": alt_keys,
        }))
    marks.sort(key=lambda m: m[0])

    cats, current = [], None
    for _, kind, payload in marks:
        if kind == "cat":
            current = (payload, [])
            cats.append(current)
        elif current is not None:
            current[1].append(payload)

    cats = [(name, rows) for name, rows in cats if rows]
    if not cats:
        raise BuildError("no shortcut categories parsed from %s" % SWIFT_SHORTCUTS)
    return cats


def render_shortcuts():
    cats = parse_shortcuts()
    total = sum(len(rows) for _, rows in cats)
    out = ['<p class="gen">%d bindings in %d groups, read from <code>Shortcuts.swift</code> '
           'when this page was built. The same list is in the app under <kbd>⌘</kbd><kbd>?</kbd>.</p>'
           % (total, len(cats))]
    for name, rows in cats:
        out.append('<h2 id="%s">%s</h2>' % (slugify(name), html.escape(name)))
        out.append('<table class="ref"><tbody>')
        for row in rows:
            keys = "".join("<kbd>%s</kbd>" % html.escape(k) for k in row["keys"])
            if row["alt"]:
                keys += '<span class="ref__or">or</span>' + "".join(
                    "<kbd>%s</kbd>" % html.escape(k) for k in row["alt"])
            out.append('<tr><td class="ref__k">%s</td><td>%s</td></tr>'
                       % (keys, html.escape(row["label"])))
        out.append("</tbody></table>")
    return "\n".join(out)


# ─────────────────────────── generated: agent tool catalogue ───────────────────────────

def _string_literal_run(src, i):
    """Read one or more adjacent double-quoted literals joined by `+`, returning the text.

    Tool descriptions are written as concatenated lines in the servers, so the literal run
    is the unit, not the single string.
    """
    parts = []
    while True:
        while i < len(src) and src[i] in " \t\r\n+":
            i += 1
        if i >= len(src) or src[i] != '"':
            break
        i += 1
        buf = []
        while i < len(src) and src[i] != '"':
            if src[i] == "\\":
                buf.append(src[i:i + 2])
                i += 2
                continue
            buf.append(src[i])
            i += 1
        i += 1
        parts.append("".join(buf))
    text = "".join(parts)
    text = text.replace('\\"', '"').replace("\\n", " ").replace("\\\\", "\\")
    return re.sub(r"\s+", " ", text).strip(), i


def _balanced(src, i, open_ch, close_ch):
    """Span of a braced/bracketed region starting at src[i] == open_ch, quotes respected."""
    depth, start, in_str = 0, i, None
    while i < len(src):
        c = src[i]
        if in_str:
            if c == "\\":
                i += 2
                continue
            if c == in_str:
                in_str = None
        elif c in "\"'`":
            in_str = c
        elif c == open_ch:
            depth += 1
        elif c == close_ch:
            depth -= 1
            if depth == 0:
                return src[start:i + 1], i + 1
        i += 1
    raise BuildError("unbalanced %s at offset %d" % (open_ch, start))


IDENT_RE = re.compile(r"([A-Za-z_$][\w$]*)\s*:")


CONST_RE = re.compile(r"^const\s+(\w+)\s*=\s*(z\.[\s\S]*?);\s*$", re.M)


def shared_params(src):
    """`const refParam = z.string().optional()...` — a value written once and reused by name.

    Without resolving these, every tool taking `ref: refParam` reads as requiring a ref, when
    ref and selector are alternatives and both optional.
    """
    return {m.group(1): m.group(2) for m in CONST_RE.finditer(src)}


def schema_params(schema, consts=None):
    """The top-level keys of a zod schema object, and whether each is optional.

    Scanned rather than matched: `{ sessionId: sessionIdParam }` on one line and a key
    indented four spaces are the same thing, and an indentation-based regex only sees the
    second. Depth and quoting are tracked so a nested `z.object({...})` or a `.describe("a:b")`
    cannot contribute a key of its own.
    """
    params, depth, i, in_str = [], 0, 0, None
    key, value_start = None, None

    def close_value(end):
        if key is None:
            return
        text = schema[value_start:end].strip()
        resolved = (consts or {}).get(text.rstrip(","), text)
        params.append({"name": key, "required": ".optional()" not in resolved})

    while i < len(schema):
        c = schema[i]
        if in_str:
            if c == "\\":
                i += 2
                continue
            if c == in_str:
                in_str = None
        elif c in "\"'`":
            in_str = c
        elif c in "{[(":
            depth += 1
            if depth == 1:
                key, value_start = None, None
        elif c in "}])":
            if depth == 1:
                close_value(i)
                key = None
            depth -= 1
        elif depth == 1 and c == ",":
            close_value(i)
            key, value_start = None, None
        elif depth == 1 and key is None:
            m = IDENT_RE.match(schema, i)
            if m:
                key, value_start = m.group(1), m.end()
                i = m.end()
                continue
        i += 1
    return params


def parse_tools(path):
    """Each `tool("name", "description", schema, handler)` registration in a server."""
    with open(path, encoding="utf-8") as f:
        src = f.read()

    consts = shared_params(src)
    tools = []
    for m in re.finditer(r'(?<![\w.])tool\(\s*"([a-z_]+)"\s*,', src):
        name = m.group(1)
        desc, i = _string_literal_run(src, m.end())
        while i < len(src) and src[i] in " \t\r\n,":
            i += 1
        params = []
        if i < len(src) and src[i] == "{":
            schema, _ = _balanced(src, i, "{", "}")
            params = schema_params(schema, consts)
        tools.append({"name": name, "description": desc, "params": params})
    if not tools:
        raise BuildError("no tools parsed from %s" % path)
    return tools


def first_sentence(text):
    """The lead sentence of an agent-facing description, which is the part a person wants."""
    cut = re.split(r"(?<=[.!?])\s+", text.strip())
    lead = cut[0] if cut else text
    return lead if lead.endswith((".", "!", "?")) else lead + "."


def render_tools():
    groups = [(label, server, parse_tools(path)) for label, server, path in MCP_SERVERS]
    total = sum(len(t) for _, _, t in groups)
    out = ['<p class="gen">%d tools across %d servers, read from the servers themselves when '
           'this page was built. Every one of them ships with Synth: there is nothing to '
           'install and nothing to register.</p>' % (total, len(groups))]
    for label, server, tools in groups:
        out.append('<h2 id="%s">%s</h2>' % (slugify(server), html.escape(server)))
        out.append('<table class="ref ref--tools"><tbody>')
        for t in tools:
            req = [p["name"] for p in t["params"] if p["required"]]
            opt = [p["name"] for p in t["params"] if not p["required"]]
            args = ", ".join(req + ["%s?" % p for p in opt])
            out.append(
                '<tr><td class="ref__t"><code>%s</code>%s</td><td>%s</td></tr>'
                % (html.escape(t["name"]),
                   '<div class="ref__args">%s</div>' % html.escape(args) if args else "",
                   html.escape(first_sentence(t["description"]))))
        out.append("</tbody></table>")
    return "\n".join(out)


GENERATORS = {"keyboard": render_shortcuts, "tools": render_tools}


# ─────────────────────────── the shell ───────────────────────────

def slugify(text):
    return re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")


HEADING_RE = re.compile(r'<h([23])(?![^>]*\bdata-notoc\b)[^>]*>(.*?)</h\1>', re.S)
TAG_RE = re.compile(r"<[^>]+>")


def headings(body):
    """The h2s and h3s a page offers the contents rail, with ids added where absent."""
    found = []
    for m in HEADING_RE.finditer(body):
        text = html.unescape(TAG_RE.sub("", m.group(2))).strip()
        ident = re.search(r'id="([^"]+)"', m.group(0))
        found.append({"level": int(m.group(1)),
                      "id": ident.group(1) if ident else slugify(text),
                      "text": text})
    return found


def add_ids(body):
    """Give every h2/h3 an anchor so a heading can be linked to, without hand-writing ids."""
    def sub(m):
        if 'id="' in m.group(0):
            return m.group(0)
        text = html.unescape(TAG_RE.sub("", m.group(2))).strip()
        return '<h%s id="%s">%s</h%s>' % (m.group(1), slugify(text), m.group(2), m.group(1))
    return HEADING_RE.sub(sub, body)


def sidebar(current):
    out = ['<nav class="dnav" aria-label="Documentation">']
    for group, pages in NAV:
        out.append('<div class="dnav__g">%s</div>' % html.escape(group))
        out.append("<ul>")
        for slug, title in pages:
            here = ' aria-current="page"' if slug == current else ""
            out.append('<li><a href="%s"%s>%s</a></li>' % (href(slug), here, html.escape(title)))
        out.append("</ul>")
    out.append("</nav>")
    return "\n".join(out)


def href(slug):
    return "./" if slug == "index" else "%s.html" % slug


def contents(items):
    if len(items) < 2:
        return ""
    out = ['<nav class="dtoc" aria-label="On this page"><div class="dtoc__t">On this page</div><ul>']
    for h in items:
        out.append('<li class="dtoc--%d"><a href="#%s">%s</a></li>'
                   % (h["level"], h["id"], html.escape(h["text"])))
    out.append("</ul></nav>")
    return "\n".join(out)


def walk(current):
    i = PAGES.index(current)
    prev = PAGES[i - 1] if i > 0 else None
    nxt = PAGES[i + 1] if i < len(PAGES) - 1 else None
    if not prev and not nxt:
        return ""
    out = ['<nav class="dwalk">']
    out.append('<a class="dwalk__p" href="%s"><span>Previous</span>%s</a>'
               % (href(prev), html.escape(TITLES[prev])) if prev else "<span></span>")
    if nxt:
        out.append('<a class="dwalk__n" href="%s"><span>Next</span>%s</a>'
                   % (href(nxt), html.escape(TITLES[nxt])))
    out.append("</nav>")
    return "\n".join(out)


SHELL = """<!DOCTYPE html>
<html lang="en-GB">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>{title} - Synth docs</title>
<meta name="description" content="{summary}" />
<link rel="canonical" href="{canonical}" />
<link rel="icon" href="../img/mark.png" />
<link rel="icon" href="../img/mark-light.png" media="(prefers-color-scheme: dark)" />
<link rel="apple-touch-icon" href="/apple-touch-icon.png" />
{social}
<script>
  // The charcoal mark reads on light browser chrome, the cream one on dark. Safari ignores
  // `media` on an icon link, so drive the swap here too; the links above cover the rest.
  (function () {{
    var dark = matchMedia('(prefers-color-scheme: dark)');
    var icon = document.querySelector('link[rel=icon]:not([media])');
    var paint = function () {{ icon.href = '../img/' + (dark.matches ? 'mark-light.png' : 'mark.png'); }};
    dark.addEventListener('change', paint);
    paint();
  }})();
</script>
<meta name="theme-color" content="#0d0f13" />
<meta name="color-scheme" content="dark" />
<link rel="preload" as="font" type="font/woff2" href="../fonts/Geist-Variable.woff2" crossorigin />
<link rel="preload" as="font" type="font/woff2" href="../fonts/GeistMono-Variable.woff2" crossorigin />
<!-- Built by site/build_docs.py. Edit site/docs-src/{slug}.html, not this file. -->
<style>
{css}
</style>
</head>

<body class="docs">
{nav}

<div class="wrap dwrap dshell">
  {sidebar}
  <main class="dmain" id="main">
    <article class="dbody">
      <h1>{title}</h1>
      <p class="lede dsum">{summary}</p>
{body}
    </article>
    {walk}
  </main>
  {contents}
</div>

<footer>
  <div class="wrap dwrap foot">
    <span class="brand brand--foot"><img src="../img/mark-light.png" alt="" />Synth</span>
    <nav class="foot__links">
      <a href="../">Home</a>
      <a href="https://github.com/isaac-scarrott/synth">GitHub</a>
      <a href="{dmg}">Download</a>
    </nav>
  </div>
</footer>
</body>
</html>
"""

DMG = "https://synth-releases.fly.storage.tigris.dev/Synth.dmg"

SUMMARY_RE = re.compile(r"<!--\s*summary:\s*(.*?)\s*-->", re.S)


def build_page(slug, css):
    path = os.path.join(SRC, "%s.html" % slug)
    if not os.path.exists(path):
        raise BuildError("missing source page %s" % path)
    with open(path, encoding="utf-8") as f:
        raw = f.read()

    summary = SUMMARY_RE.search(raw)
    if not summary:
        raise BuildError("%s has no `<!-- summary: ... -->` line" % path)
    body = SUMMARY_RE.sub("", raw, count=1).strip("\n")

    if slug in GENERATORS:
        marker = "<!-- generated -->"
        if marker not in body:
            raise BuildError("%s must contain %s" % (path, marker))
        body = body.replace(marker, GENERATORS[slug](), 1)

    summary_text = re.sub(r"\s+", " ", summary.group(1))
    body = add_ids(body)
    page = SHELL.format(
        title=html.escape(TITLES[slug]),
        summary=html.escape(summary_text),
        slug=slug,
        canonical=canonical(slug),
        social=social(slug, TITLES[slug], summary_text),
        css=css,
        dmg=DMG,
        nav=landing_nav(),
        sidebar=sidebar(slug),
        contents=contents(headings(body)),
        walk=walk(slug),
        body=body,
    )
    return {
        "html": page,
        "markdown": markdown_page(slug, TITLES[slug], summary_text, body),
        "summary": summary_text,
    }


# ─────────────────────────── the same pages, as markdown ───────────────────────────
# Synth hosts coding agents, so its own documentation should be legible to one. These are
# built from the same fragments as the HTML rather than written again, which is the only
# version of this that stays true.

from html.parser import HTMLParser

VOID = {"img", "br", "hr", "meta", "input"}


class Node:
    def __init__(self, tag, attrs=None):
        self.tag, self.attrs, self.kids = tag, dict(attrs or []), []

    def text(self):
        return "".join(k if isinstance(k, str) else k.text() for k in self.kids)


class Tree(HTMLParser):
    """A small DOM for a closed, well-formed tag set. Not a general parser, and it does not
    need to be: the only input is this repository's own fragments."""

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.root = Node("#root")
        self.stack = [self.root]

    def handle_starttag(self, tag, attrs):
        node = Node(tag, attrs)
        self.stack[-1].kids.append(node)
        if tag not in VOID:
            self.stack.append(node)

    def handle_endtag(self, tag):
        for i in range(len(self.stack) - 1, 0, -1):
            if self.stack[i].tag == tag:
                del self.stack[i:]
                return

    def handle_data(self, data):
        self.stack[-1].kids.append(data)


def code_span(text):
    """A code span that survives its own content.

    Two of Synth's bindings are `⌘\\`` and `⌘⇧\\``, where the key IS a backtick, so a single
    delimiter closes the span in the middle of the key. Markdown's answer is a longer fence,
    padded so a leading or trailing backtick is not read as part of it.
    """
    runs = re.findall(r"`+", text)
    fence = "`" * ((max(len(r) for r in runs) + 1) if runs else 1)
    pad = " " if text.startswith("`") or text.endswith("`") else ""
    return "%s%s%s%s%s" % (fence, pad, text, pad, fence)


def inline(node):
    """Inline runs, with the marks that survive a plain-text reading."""
    out, keys = [], []
    prev_kbd = False
    for k in node.kids:
        if isinstance(k, str):
            out.append(re.sub(r"\s+", " ", k))
            prev_kbd = prev_kbd and not k.strip()
            continue
        inner = inline(k)
        is_kbd = k.tag == "kbd"
        if is_kbd and prev_kbd and keys:
            # Caps sit side by side in the HTML whether they are a chord (⌘ then K, pressed
            # together) or alternatives (J or K, either one). On screen the gap between caps
            # carries that; in plain text nothing does. A chord always opens with a modifier,
            # so that is the test: a chord becomes one span, alternatives stay separate spans
            # with a space, and `JK` stops reading as a key that does not exist.
            if keys[-1][0] in "⌘⌥⌃⇧":
                keys[-1] += inner.strip()
                out[-1] = code_span(keys[-1])
            else:
                keys.append(inner.strip())
                out.append(" " + code_span(inner.strip()))
            continue
        prev_kbd = is_kbd
        if is_kbd:
            keys.append(inner.strip())
        if k.tag in ("strong", "b"):
            out.append("**%s**" % inner.strip())
        elif k.tag in ("em", "i"):
            out.append("*%s*" % inner.strip())
        elif k.tag in ("code", "kbd"):
            out.append(code_span(inner.strip()))
        elif k.tag == "div" and "ref__args" in k.attrs.get("class", ""):
            # the generated tool table's argument line, which belongs to the name beside it
            out.append("(%s)" % inner.strip())
        elif k.tag == "span" and "ref__or" in k.attrs.get("class", ""):
            # the alternate-binding separator, whose spacing is margin in the HTML
            out.append(" %s " % inner.strip())
        elif k.tag == "a":
            href = k.attrs.get("href", "")
            # a sibling page is its markdown twin, so a reader following links stays in markdown
            href = re.sub(r"^([a-z-]+)\.html(#.*)?$", lambda m: m.group(1) + ".md" + (m.group(2) or ""), href)
            if href == "./":
                href = "index.md"
            out.append("[%s](%s)" % (inner.strip(), href))
        elif k.tag == "img":
            out.append("![%s](%s)" % (re.sub(r"\s+", " ", k.attrs.get("alt", "")).strip(),
                                      k.attrs.get("src", "")))
        elif k.tag == "br":
            out.append("\n")
        else:
            out.append(inner)
    return "".join(out)


def cells(row):
    return [inline(c).strip().replace("|", "\\|") for c in row.kids
            if not isinstance(c, str) and c.tag in ("td", "th")]


def block(node, depth=0):
    """One markdown block per element, in document order."""
    out = []
    for k in node.kids:
        if isinstance(k, str):
            if k.strip():
                out.append(re.sub(r"\s+", " ", k).strip())
            continue
        t, cls = k.tag, k.attrs.get("class", "")
        if t in ("h2", "h3"):
            out.append("%s %s" % ("#" * (int(t[1]) ), inline(k).strip()))
        elif t == "p":
            out.append(inline(k).strip())
        elif t in ("ul", "ol"):
            items = [x for x in k.kids if not isinstance(x, str) and x.tag == "li"]
            out.append("\n".join(
                "%s %s" % ("-" if t == "ul" else "%d." % (i + 1), inline(x).strip())
                for i, x in enumerate(items)))
        elif t == "pre":
            out.append("```\n%s\n```" % k.text().strip("\n").rstrip())
        elif t == "table":
            rows = []
            for section in k.kids:
                if isinstance(section, str):
                    continue
                src = [section] if section.tag == "tr" else [
                    r for r in section.kids if not isinstance(r, str) and r.tag == "tr"]
                rows.extend(src)
            grid = [cells(r) for r in rows if cells(r)]
            if not grid:
                continue
            width = max(len(r) for r in grid)
            grid = [r + [""] * (width - len(r)) for r in grid]
            # Most of these tables define terms and carry no header row. Markdown needs one,
            # so an empty header is synthesised rather than promoting the first definition
            # into a heading it was never written as.
            has_head = any(not isinstance(c, str) and c.tag == "thead" for c in k.kids)
            head, body = (grid[0], grid[1:]) if has_head else ([""] * width, grid)
            out.append("\n".join(
                ["| " + " | ".join(head) + " |", "|" + "---|" * width]
                + ["| " + " | ".join(r) + " |" for r in body]))
        elif t == "figure":
            img = next((x for x in k.kids if not isinstance(x, str) and x.tag == "img"), None)
            cap = next((x for x in k.kids if not isinstance(x, str) and x.tag == "figcaption"), None)
            if img:
                out.append("![%s](%s)" % (re.sub(r"\s+", " ", img.attrs.get("alt", "")).strip(),
                                          img.attrs.get("src", "")))
            if cap:
                out.append("*%s*" % inline(cap).strip())
        elif t == "div" and cls in ("note", "warn"):
            inner = block(k, depth + 1)
            out.append("\n".join("> " + line if line else ">" for line in inner.split("\n")))
        else:
            nested = block(k, depth + 1)
            if nested:
                out.append(nested)
    return "\n\n".join(x for x in out if x)


def to_markdown(slug, body):
    tree = Tree()
    tree.feed(body)
    md = block(tree.root)
    md = re.sub(r"\n{3,}", "\n\n", md)
    return md.strip() + "\n"


def markdown_page(slug, title, summary, body):
    return "# %s\n\n%s\n\n%s" % (title, summary, to_markdown(slug, body))


def check_balance(page, slug):
    """Tag counts must agree. Cheap, and it catches exactly the splice the ledger records."""
    for tag in ("html", "head", "body", "main", "article", "table", "nav", "footer"):
        opens = len(re.findall(r"<%s[\s>]" % tag, page))
        closes = page.count("</%s>" % tag)
        if opens != closes:
            raise BuildError("%s: %d <%s> against %d </%s>" % (slug, opens, tag, closes, tag))


SITE = "https://trysynth.dev"
CARD = SITE + "/img/share-card.png"


def canonical(slug):
    """The one address for a page. There are four ways to reach each of these — `/docs/`
    against `/docs/index.html`, and the `.md` twin against the `.html` — and a crawler that
    finds two of them has found two pages unless the page says which one it is."""
    return "%s/docs/" % SITE if slug == "index" else "%s/docs/%s.html" % (SITE, slug)


def social(slug, title, summary):
    """The share card and the breadcrumb for one docs page.

    Docs URLs are the ones people paste to each other; every one of them used to unfurl as a
    bare grey link, because this shell emitted a title and a description and stopped. The
    picture is the landing page's — one card for the site, rather than a rendering job per
    page — and the title and description are the page's own, which is what the reader of the
    unfurl is actually choosing between.
    """
    url = canonical(slug)
    full = "%s - Synth docs" % title
    crumbs = [("Synth", SITE + "/"), ("Docs", SITE + "/docs/")]
    if slug != "index":
        crumbs.append((title, url))
    trail = json.dumps({
        "@context": "https://schema.org",
        "@type": "BreadcrumbList",
        "itemListElement": [
            {"@type": "ListItem", "position": i, "name": name, "item": at}
            for i, (name, at) in enumerate(crumbs, 1)
        ],
    }, indent=2)
    tags = [
        ("property", "og:type", "article"),
        ("property", "og:site_name", "Synth"),
        ("property", "og:locale", "en_GB"),
        ("property", "og:url", url),
        ("property", "og:title", full),
        ("property", "og:description", summary),
        ("property", "og:image", CARD),
        ("property", "og:image:width", "1200"),
        ("property", "og:image:height", "630"),
        ("property", "og:image:alt", "Synth - run every coding agent, commit to none of them"),
        ("name", "twitter:card", "summary_large_image"),
        ("name", "twitter:image", CARD),
    ]
    lines = ['<meta %s="%s" content="%s" />' % (kind, key, html.escape(value, quote=True))
             for kind, key, value in tags]
    lines.append('<script type="application/ld+json">\n%s\n</script>' % trail)
    return "\n".join(lines)


def llms_index(built):
    """The root index an agent reads first: what this site is, and every page with one line.

    Kept to links and summaries rather than prose, because its job is to say what exists and
    where the full text is, not to be the full text.
    """
    lines = [
        "# Synth",
        "",
        "> A Mac-native development environment for coding agents. It hosts the agents you "
        "already have (Claude Code, OpenCode, Antigravity, or your own command), runs each "
        "branch in its own git worktree, and tells you which session needs you.",
        "",
        "Every page below is also served as markdown: replace `.html` with `.md`, or read "
        "[llms-full.txt](%s/llms-full.txt) for all of them in one file." % SITE,
        "",
    ]
    for group, pages in NAV:
        lines.append("## %s" % group)
        lines.append("")
        for slug, title in pages:
            lines.append("- [%s](%s/docs/%s.md): %s" % (title, SITE, slug, built[slug]["summary"]))
        lines.append("")
    lines += ["## Elsewhere", "",
              "- [Landing page](%s/): what Synth is, in five claims." % SITE,
              "- [Download](%s): the signed disk image. macOS 14 or later, Apple silicon." % DMG,
              ""]
    return "\n".join(lines)


def llms_full(built):
    parts = ["# Synth documentation", "",
             "Every page of the Synth documentation, in reading order, generated from the "
             "same source as the site.", ""]
    for slug in PAGES:
        parts += ["---", "", built[slug]["markdown"].rstrip(), ""]
    return "\n".join(parts) + "\n"


def sitemap():
    """Every address on this site, generated from NAV so a page added there is a page a
    crawler is told about. Only the canonical form of each is listed — the `.md` twins are
    the same documents for a different reader, and offering both invites a crawler to treat
    the site as twice its size with every page duplicated."""
    urls = [SITE + "/"] + [canonical(slug) for slug in PAGES]
    body = "\n".join("  <url><loc>%s</loc></url>" % u for u in urls)
    return ('<?xml version="1.0" encoding="UTF-8"?>\n'
            '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n'
            '%s\n</urlset>\n' % body)


ROBOTS = """# Everything here is meant to be read, by people and by agents alike.
User-agent: *
Allow: /

# The documentation, written for an agent rather than rendered for a browser. Nothing links
# to these from the pages, so this is the only place they are announced.
# %(site)s/llms.txt
# %(site)s/llms-full.txt

Sitemap: %(site)s/sitemap.xml
"""


def build():
    """Every file this build owns, keyed by its path relative to site/."""
    css = landing_css()
    with open(DOCS_CSS, encoding="utf-8") as f:
        css = css + "\n\n" + f.read().strip("\n")

    built = {}
    for slug in PAGES:
        built[slug] = build_page(slug, css)
        check_balance(built[slug]["html"], slug)

    files = {}
    for slug in PAGES:
        files["docs/%s.html" % slug] = built[slug]["html"]
        files["docs/%s.md" % slug] = built[slug]["markdown"]
    files["llms.txt"] = llms_index(built)
    files["llms-full.txt"] = llms_full(built)
    files["sitemap.xml"] = sitemap()
    files["robots.txt"] = ROBOTS % {"site": SITE}
    # GitHub Pages runs Jekyll by default, which would take the .md twins and render them
    # into HTML rather than serving the markdown an agent asked for.
    files[".nojekyll"] = ""
    return files


def main():
    check = "--check" in sys.argv
    files = build()
    os.makedirs(OUT, exist_ok=True)
    stale = []
    for name, content in files.items():
        path = os.path.join(ROOT, name)
        old = None
        if os.path.exists(path):
            with open(path, encoding="utf-8") as f:
                old = f.read()
        if old == content:
            continue
        stale.append(name)
        if not check:
            with open(path, "w", encoding="utf-8") as f:
                f.write(content)

    known = {n.split("/", 1)[1] for n in files if n.startswith("docs/")}
    for name in sorted(os.listdir(OUT)) if os.path.isdir(OUT) else []:
        if name.endswith((".html", ".md")) and name not in known:
            raise BuildError("%s is in docs/ but not in NAV; delete it or add it" % name)

    if check:
        if stale:
            print("out of date: %s" % ", ".join(stale), file=sys.stderr)
            return 1
        print("site/ matches docs-src/ (%d files)" % len(files))
        return 0
    print("built %d files%s" % (len(files), (" (%s)" % ", ".join(stale)) if stale else ", no change"))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except BuildError as exc:
        print("build_docs: %s" % exc, file=sys.stderr)
        sys.exit(2)
