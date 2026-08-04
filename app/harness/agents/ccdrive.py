"""Drive a real Claude Code in a pty, against a seeded HOME and a transcript of our own.

Two things here that the rest of the harness does not need, and why:

**A pty, not the app.** The colours under test are the ones the *agent* emits, and it emits them the
same way into any terminal. Driving `claude` directly makes the gate independent of a Synth build,
so a contrast regression is not hidden behind a build failure, and it costs seconds rather than
minutes. What the real surface does with those colours is `t13_termcontrast`'s job.

**A transcript fixture, not a real session.** `--resume` re-renders a whole conversation with no API
call, which is the only way to get diffs, tool results and markdown on screen for free. Resuming one
of the developer's own sessions would work and was how this was first measured, but it makes the gate
depend on whichever conversations happen to be on the machine. `fixture_transcript` builds the same
screens every time, on any machine, and exercises the parts that carry colour: a diff, a code fence,
a collapsed tool result, an error, a todo list.

Nothing here signs in and nothing here spends a token: a resumed transcript is replayed from disk.
"""
import fcntl, json, os, pty, re, select, shutil, struct, termios, time, uuid

CONFIG = os.path.expanduser("~/.claude.json")
COLS, ROWS = 100, 44
# Claude Code, started with no MCP servers so a gate measures the agent and not whatever the machine
# happens to have connected. Passed by the caller, because they are Claude Code's flags alone —
# opencode exits with a usage error on them.
CLAUDE_ISOLATION = ["--strict-mcp-config", "--mcp-config", '{"mcpServers":{}}']
SESSION_ID = "5e17b0ad-0000-4000-8000-5ec70a1e0001"


INSTALL_HINTS = ["~/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]


def _is_shim(path):
    """Synth's own `claude` is a shim that re-execs the real one through the hook path. Running it
    would measure the shim, and — launched outside a Synth session — it prints
    `synth-hook: unknown invocation` and exits.

    The tell is where it lands, not what it is called: the shim resolves to `synth-hook` inside the
    app bundle, while the real CLI resolves to a *versioned* file in its own install
    (`~/.local/share/claude/versions/2.1.221`), so a basename check would reject the real one.
    """
    real = os.path.realpath(path)
    return ".app/" in real or "synth" in os.path.basename(real).lower()


def agent_binary(name, extra_dirs=()):
    """The first `name` on PATH that is the real CLI rather than Synth's shim."""
    dirs = ([d for d in os.environ.get("PATH", "").split(":") if d]
            + [os.path.expanduser(d) for d in list(INSTALL_HINTS) + list(extra_dirs)])
    seen = set()
    for d in dirs:
        c = os.path.join(d, name)
        if c in seen:
            continue
        seen.add(c)
        if os.path.isfile(c) and os.access(c, os.X_OK) and not _is_shim(c):
            return os.path.realpath(c)
    return ""


def claude_binary():
    return agent_binary("claude")


def opencode_binary():
    """opencode's own install first, then PATH.

    Order matters twice over: a package-manager `opencode` on PATH is often a launcher script, which
    runs the TUI fine but has no theme table inside it — and `t25` reads opencode's own theme out of
    the binary to prove Synth only changed the light half.
    """
    native = os.path.expanduser("~/.opencode/bin/opencode")
    if os.path.isfile(native) and os.access(native, os.X_OK):
        return os.path.realpath(native)
    return agent_binary("opencode", extra_dirs=["~/.npm-global/bin"])


# ---------------------------------------------------------------------------- transcript fixture

def _row(**kw):
    return kw


def fixture_transcript(cwd, session_id=SESSION_ID):
    """A conversation that puts every colour-carrying element on screen.

    Written as real transcript rows rather than driven through the UI because a resumed transcript
    renders the *finished* forms — a diff with its own backgrounds, a collapsed result, a failed
    command — which a live session would only reach by actually doing the work.
    """
    ids = [str(uuid.UUID(int=0x5e17b0ad0000 + i)) for i in range(40)]
    base = dict(isSidechain=False, userType="external", entrypoint="cli", cwd=cwd,
                sessionId=session_id, version="2.1.221", gitBranch="main")
    rows = [_row(type="mode", mode="normal", sessionId=session_id)]

    def user(text, i, parent):
        rows.append(_row(parentUuid=parent, type="user", uuid=ids[i], isMeta=False,
                         timestamp="2026-08-04T09:00:00.000Z",
                         message={"role": "user", "content": text}, **base))
        return ids[i]

    def assistant(content, i, parent, extra=None):
        r = _row(parentUuid=parent, type="assistant", uuid=ids[i],
                 timestamp="2026-08-04T09:00:01.000Z", requestId="req_fixture",
                 message={"model": "claude-opus-4-8", "id": f"msg_fixture{i}",
                          "type": "message", "role": "assistant", "content": content}, **base)
        if extra:
            r.update(extra)
        rows.append(r)
        return ids[i]

    def result(tool_id, content, i, parent, extra=None):
        r = _row(parentUuid=parent, type="user", uuid=ids[i], isMeta=False,
                 timestamp="2026-08-04T09:00:02.000Z",
                 message={"role": "user",
                          "content": [{"tool_use_id": tool_id, "type": "tool_result",
                                       "content": content}]}, **base)
        if extra:
            r.update(extra)
        rows.append(r)
        return ids[i]

    p = user("Tidy the layout helper and run the tests.", 1, None)

    # Markdown: heading, bold, inline code, a fenced block (the syntax highlighter's screen), a list.
    p = assistant([{"type": "text", "text":
                    "## Plan\n\n"
                    "I'll fix **two** things in `layout.js`, then run the suite.\n\n"
                    "```javascript\n"
                    "function greet(name) {\n"
                    "  const greeting = `Hello, ${name}!`;   // a comment\n"
                    "  console.log(greeting);\n"
                    "  return greeting.length > 0;\n"
                    "}\n"
                    "```\n\n"
                    "- first, the reorder guard\n"
                    "- then, the drop-zone maths\n"}], 2, p)

    # A todo list, which paints its own status colours.
    tid = "toolu_fixture_todo"
    p = assistant([{"type": "tool_use", "id": tid, "name": "TodoWrite",
                    "input": {"todos": [
                        {"content": "Fix the reorder guard", "status": "completed",
                         "activeForm": "Fixing the reorder guard"},
                        {"content": "Fix the drop-zone maths", "status": "in_progress",
                         "activeForm": "Fixing the drop-zone maths"},
                        {"content": "Run the suite", "status": "pending",
                         "activeForm": "Running the suite"}]}}], 3, p)
    p = result(tid, "Todos have been modified successfully.", 4, p)

    # An Edit, whose structuredPatch is what Claude Code renders as a coloured diff.
    tid = "toolu_fixture_edit"
    old = "  if (a && b) { return node; }"
    new = "  if (a && b) { node.a = a; node.b = b; return node; }"
    path = os.path.join(cwd, "layout.js")
    p = assistant([{"type": "tool_use", "id": tid, "name": "Edit",
                    "input": {"file_path": path, "old_string": old,
                              "new_string": new, "replace_all": False}}], 5, p)
    p = result(tid, f"The file {path} has been updated successfully.", 6, p, extra={
        "toolUseResult": {
            "filePath": path, "oldString": old, "newString": new,
            "originalFile": "function walk(node) {\n" + old + "\n  return a || b;\n}\n",
            "replaceAll": False, "userModified": False,
            "structuredPatch": [{
                "oldStart": 1, "oldLines": 4, "newStart": 1, "newLines": 4,
                "lines": [" function walk(node) {", "-" + old, "+" + new,
                          "   return a || b;", " }"],
            }],
        }})

    # A Bash call with a long result, so the "+N lines" collapse renders too.
    tid = "toolu_fixture_bash"
    p = assistant([{"type": "tool_use", "id": tid, "name": "Bash",
                    "input": {"command": "npm test -- --reporter=dot",
                              "description": "Run the test suite"}}], 7, p)
    p = result(tid, "\n".join(["> layout@1.0.0 test", "", "  ....F..."]
                              + [f"  ok {i} - reorder guard holds" for i in range(1, 9)]
                              + ["", "  1 failing", "  AssertionError: expected 3 to equal 4"]),
               8, p)

    # A failed command: the error path has colours of its own.
    tid = "toolu_fixture_fail"
    p = assistant([{"type": "tool_use", "id": tid, "name": "Bash",
                    "input": {"command": "npx eslint layout.js",
                              "description": "Lint the changed file"}}], 9, p)
    p = result(tid, "layout.js:12:5  error  'node' is assigned but never used  no-unused-vars",
               10, p, extra={"toolUseResult": {"stdout": "", "stderr": "1 problem",
                                               "interrupted": False, "isImage": False}})

    p = assistant([{"type": "text", "text":
                    "One test still fails and the lint is unhappy. Want me to fix both?"}], 11, p)
    return rows


# ---------------------------------------------------------------------------- driven session

Q_BG = re.compile(rb"\x1b\]11;\?(\x07|\x1b\\)")
Q_FG = re.compile(rb"\x1b\]10;\?(\x07|\x1b\\)")
# Ghostty's "the appearance changed" notification, which an app subscribes to with DEC mode 2031.
NOTIFY_DARK = b"\x1b[?997;1n"
NOTIFY_LIGHT = b"\x1b[?997;2n"


def osc_colour(index, rgb):
    """An OSC 10/11 reply in ghostty's form: 16-bit components, ST-terminated."""
    r, g, b = rgb
    return f"\x1b]{index};rgb:{r:02x}{r:02x}/{g:02x}{g:02x}/{b:02x}{b:02x}\x1b\\".encode()


class Session:
    """A live agent under a pty, with the emulator fed as bytes arrive.

    Pass `surface` to answer the colour queries a real ghostty answers. This is not optional
    politeness: opencode asks the terminal what colour it is (OSC 10/11) and falls back to its *dark*
    theme when nothing replies, so a harness that only records output measures a screen no user ever
    sees. That artefact is on record for Claude Code too (2026-07-27) — it is the single easiest way
    to draw the wrong conclusion here.
    """

    def __init__(self, home, args=(), env_extra=None, cols=COLS, rows=ROWS, emulator=None,
                 cwd=None, binary=None, surface=None):
        self.home = home
        self.cols, self.rows = cols, rows
        self.em = emulator
        self.surface = surface
        self.answered = {"fg": 0, "bg": 0}
        binary = binary or claude_binary()
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            # The working directory is not cosmetic: it is the key `seed_home` files the transcript
            # and the trust acceptance under. Start anywhere else and Claude Code finds neither —
            # it opens on the trust prompt, and a gate measures *that* screen's four colours and
            # calls it a pass.
            env = dict(os.environ)
            if cwd:
                # `PWD` as well as the real chdir: Claude Code reads the environment's idea of the
                # working directory, so an inherited `PWD` from wherever the harness was started
                # sends it looking for the transcript under the wrong project key.
                env["PWD"] = os.path.realpath(cwd)
                os.chdir(env["PWD"])
            env.update(TERM="xterm-256color", COLORTERM="truecolor", HOME=home,
                       LINES=str(rows), COLUMNS=str(cols))
            # A driven run is launched *from* a Claude Code session in practice, and these leak in:
            # they switch the child into child-session mode and change what it paints.
            for k in ("CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SSE_PORT",
                      "CLAUDE_CODE_SESSION_ID", "CLAUDE_CODE_CHILD_SESSION",
                      "CLAUDE_CONFIG_DIR", "CLAUDE_CODE_EXECPATH"):
                env.pop(k, None)
            if env_extra:
                env.update(env_extra)
            os.execvpe(binary, [binary, *args], env)
        self.resize(cols)

    def resize(self, cols):
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ, struct.pack("HHHH", self.rows, cols, 0, 0))

    def pump(self, seconds):
        end = time.time() + seconds
        while time.time() < end:
            r, _, _ = select.select([self.fd], [], [], 0.15)
            if r:
                try:
                    b = os.read(self.fd, 65536)
                except OSError:
                    return
                if not b:
                    return
                self._answer(b)
                if self.em is not None:
                    self.em.feed(b)

    def _answer(self, chunk):
        """Reply to colour queries in this chunk, before the app gives up waiting on them."""
        if self.surface is None:
            return
        for pattern, index, key, colour in ((Q_BG, 11, "bg", self.surface.bg),
                                            (Q_FG, 10, "fg", self.surface.fg)):
            for _ in pattern.findall(chunk):
                try:
                    os.write(self.fd, osc_colour(index, colour))
                except OSError:
                    return
                self.answered[key] += 1

    def notify_theme(self, dark):
        """Announce an appearance change the way ghostty does, for apps that subscribe to 2031."""
        os.write(self.fd, NOTIFY_DARK if dark else NOTIFY_LIGHT)

    def send(self, s, wait=0.6):
        os.write(self.fd, s.encode() if isinstance(s, str) else s)
        self.pump(wait)

    def repaint(self, wait=2.5):
        """Force a full frame. A width change is the one nudge that makes the TUI rewrite every
        cell it owns, which is what a colour measurement needs after a live re-theme."""
        self.resize(self.cols - 1)
        self.pump(1.2)
        self.resize(self.cols)
        self.pump(wait)

    def close(self):
        try:
            os.kill(self.pid, 9)
            os.waitpid(self.pid, 0)
        except (ProcessLookupError, ChildProcessError):
            pass
        try:
            os.close(self.fd)
        except OSError:
            pass


# ---------------------------------------------------------------------------- seeded HOME

def project_key(cwd):
    """How Claude Code names a project's transcript directory: every non-alphanumeric becomes `-`.

    Not just the separators — a harness scratch path like `synth-agent-gate-ri4_b8iz` has its
    underscore flattened too, and getting that wrong files the transcript one directory away from
    where `--resume` looks, which reads as "No conversation found" rather than as a path bug.
    """
    return re.sub(r"[^a-zA-Z0-9]", "-", cwd)


def seed_home(root, theme, cwd, transcript=True, session_id=SESSION_ID):
    """A HOME that differs from the developer's in exactly the ways the gate needs.

    The real `~/.claude.json` is copied rather than invented so the run inherits a completed
    onboarding — a fresh config drops straight into the theme picker, which previews *all* themes and
    is therefore the one screen whose colours mean nothing.
    """
    # Claude Code keys both the trust acceptance and the transcript directory by the *resolved* path.
    # A harness scratch dir is typically `/var/folders/...`, which is a symlink to `/private/var/...`,
    # so seeding under the unresolved form files them where nothing will look: the session opens on
    # the trust prompt with no transcript to resume.
    cwd = os.path.realpath(cwd)
    shutil.rmtree(root, ignore_errors=True)
    os.makedirs(f"{root}/.claude/themes", exist_ok=True)
    cfg = {}
    try:
        with open(CONFIG) as fh:
            cfg = json.load(fh)
    except (OSError, ValueError):
        cfg = {}
    cfg["theme"] = theme
    cfg["projects"] = {cwd: {"hasTrustDialogAccepted": True,
                             "hasCompletedProjectOnboarding": True,
                             "allowedTools": [], "history": []}}
    # Both upsells are modal on startup and would be the only thing on screen.
    cfg["fullscreenUpsellSeenCount"] = 99
    cfg["fullscreenDownsellSeenCount"] = 99
    with open(f"{root}/.claude.json", "w") as fh:
        json.dump(cfg, fh)
    if transcript:
        d = f"{root}/.claude/projects/{project_key(cwd)}"
        os.makedirs(d, exist_ok=True)
        with open(f"{d}/{session_id}.jsonl", "w") as fh:
            for r in fixture_transcript(cwd, session_id):
                fh.write(json.dumps(r) + "\n")
    return root


def write_theme(root, base, overrides, slug="synth"):
    """Write the custom theme the way `AgentTheme` does — atomically, so the watcher sees one event."""
    path = f"{root}/.claude/themes/{slug}.json"
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w") as fh:
        json.dump({"name": "Synth", "base": base, "overrides": overrides}, fh, indent=2)
    os.replace(tmp, path)
