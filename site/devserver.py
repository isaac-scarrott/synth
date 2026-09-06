#!/usr/bin/env python3
"""Dev server for the Synth site, with copy editable in the page itself.

A save is an exact string swap, not a guess: the browser sends back the innerHTML it
was served alongside the replacement, so the server can find the one place in the file
that text came from, and refuse the write outright if it can't. Nothing in index.html
has to be annotated for this to work.

    python3 devserver.py [port]

Binds to localhost only.
"""
import http.server
import json
import os
import re
import sys
import textwrap
import threading
import time
import urllib.parse

ROOT = os.path.dirname(os.path.abspath(__file__))
PAGE = os.path.join(ROOT, "index.html")
WRAP = 100
WATCH = ("index.html", "dev-edit.js")

_stamps_lock = threading.Lock()


def stamps():
    out = {}
    for name in WATCH:
        try:
            out[name] = os.stat(os.path.join(ROOT, name)).st_mtime_ns
        except OSError:
            out[name] = 0
    return out


_stamps = stamps()


def note_own_write():
    """Absorb the mtime of a write we just made, so a save doesn't reload the page under you."""
    global _stamps
    with _stamps_lock:
        _stamps = stamps()


def reflow(original: str, updated: str) -> str:
    """Put the replacement back in the shape the source was in.

    An edited element arrives as one long line. Where the original spanned several,
    re-wrap to the same indent so the file doesn't slowly turn into a single column.
    """
    if "\n" not in original:
        return updated.strip()
    lines = original.split("\n")
    body_indent = re.match(r"[ \t]*", lines[1]).group(0)
    tail_indent = re.match(r"[ \t]*", lines[-1]).group(0)
    flat = " ".join(updated.split())
    wrapped = textwrap.wrap(flat, width=WRAP, break_long_words=False, break_on_hyphens=False)
    return "\n" + "\n".join(body_indent + line for line in wrapped) + "\n" + tail_indent


class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=ROOT, **kwargs)

    def log_message(self, fmt, *args):
        if "__save" in (args[0] if args else ""):
            super().log_message(fmt, *args)

    def _send(self, payload: bytes, ctype: str, status: int = 200):
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):
        path = urllib.parse.urlparse(self.path).path
        if path == "/__events":
            return self._events()
        if path == "/__edit.js":
            with open(os.path.join(ROOT, "dev-edit.js"), "rb") as f:
                return self._send(f.read(), "application/javascript")
        if path in ("/", "/index.html"):
            with open(PAGE, encoding="utf-8") as f:
                html = f.read()
            html = html.replace("</body>", '<script src="/__edit.js"></script>\n</body>', 1)
            return self._send(html.encode("utf-8"), "text/html; charset=utf-8")
        return super().do_GET()

    def _events(self):
        """Server-sent events: one line whenever a watched file changes on disk."""
        global _stamps
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        try:
            while True:
                time.sleep(0.35)
                with _stamps_lock:
                    now = stamps()
                    changed = [k for k in WATCH if now[k] != _stamps[k]]
                    _stamps = now
                payload = "data: %s\n\n" % (",".join(changed) if changed else "ping")
                self.wfile.write(payload.encode("utf-8"))
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            return

    def do_POST(self):
        if urllib.parse.urlparse(self.path).path != "/__save":
            return self.send_error(404)
        try:
            raw = self.rfile.read(int(self.headers["Content-Length"]))
            edit = json.loads(raw)
            original, updated, tag = edit["original"], edit["updated"], edit["tag"]
        except Exception as exc:
            return self._reply(400, ok=False, error="bad request: %s" % exc)

        with open(PAGE, encoding="utf-8") as f:
            src = f.read()

        # Anchored between the element's own tags: without this, a line that is a prefix of
        # another (". . . Apple silicon" inside ". . . Apple silicon, signed and notarised")
        # looks ambiguous and the write is refused for no good reason.
        close = "</%s>" % tag
        needle = ">" + original + close
        found = src.count(needle)
        if found != 1:
            return self._reply(
                409, ok=False,
                error="found %d places in index.html matching that <%s>, so there is no single one to write to"
                      % (found, tag),
            )

        # contenteditable emits &nbsp; (and U+00A0) wherever two spaces meet; neither belongs
        # in prose, and both are invisible in the diff that follows.
        updated = updated.replace("&nbsp;", " ").replace("\u00a0", " ")
        replacement = reflow(original, updated)
        with open(PAGE, "w", encoding="utf-8") as f:
            f.write(src.replace(needle, ">" + replacement + close, 1))
        note_own_write()
        return self._reply(200, ok=True, stored=replacement)

    def _reply(self, status, **body):
        self._send(json.dumps(body).encode("utf-8"), "application/json", status)


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8912
    with http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler) as httpd:
        print("editing http://localhost:%d/ — writes land in %s" % (port, PAGE))
        httpd.serve_forever()
