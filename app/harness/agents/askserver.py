"""Three servers a developer really meets, so t29 can prove the pane can reach them.

Every one of these was unreachable from Synth's browser before the handlers were wired, and
none of them can be faked: a certificate error only exists if a real TLS handshake presents a
certificate nothing trusts, and a basic-auth prompt only exists if a server really sends
`WWW-Authenticate`. So the gate runs them.

  https  a self-signed certificate on 127.0.0.1 — the local dev server case
  auth   401 + WWW-Authenticate: Basic, until the right credentials arrive
  plain  pages that call alert/confirm/prompt and getUserMedia

Each returns (process, port). Kill the process to stop it.
"""
import http.server, os, pathlib, socket, ssl, subprocess, sys, tempfile, threading, time

# The dialogs fire off the fragment, so the gate triggers them by NAVIGATING — the app's own
# "go to" call — rather than over CDP. A CDP client with the Page domain enabled answers
# JavaScript dialogs itself, which would quietly measure the harness instead of the handler.
DIALOG_PAGE = """<!doctype html><title>DIALOGS</title><body>
<h1 id="hero">dialogs</h1>
<script>
  window.__answer = null;
  function ask(kind) {
    window.__answer = null;
    if (kind === 'alert') { alert('the page has something to say'); window.__answer = 'alerted'; }
    if (kind === 'confirm') { window.__answer = String(confirm('shall we?')); }
    if (kind === 'prompt') { window.__answer = String(prompt('what is your name?', 'nobody')); }
    if (kind === 'camera') {
      navigator.mediaDevices.getUserMedia({ video: true })
        .then(() => { window.__answer = 'granted'; })
        .catch((e) => { window.__answer = 'denied:' + e.name; });
    }
  }
  // A beat after load, never inside it: a page stopped inside alert() during its own load
  // never finishes loading, and the gate would be waiting on the wrong thing.
  const fire = () => { const k = location.hash.slice(1); if (k) setTimeout(() => ask(k), 60); };
  window.addEventListener('hashchange', fire);
  fire();
</script></body>"""

FIND_PAGE = ("<!doctype html><title>FIND</title><body><h1 id='hero'>find</h1>"
             "<p>Checkout. Review your order before you pay. Your order is held for 20 "
             "minutes. Order summary. Order total. Return to basket.</p></body>")


def _free_port():
    s = socket.socket(); s.bind(("127.0.0.1", 0)); port = s.getsockname()[1]; s.close()
    return port


def _wait(port, tls=False):
    for _ in range(100):
        try:
            socket.create_connection(("127.0.0.1", port), timeout=0.5).close()
            return True
        except OSError:
            time.sleep(0.1)
    return False


def _serve(directory, port, handler_cls, ssl_ctx=None):
    """A threaded server in this process — the pages are static and the assertions are all on
    the app side, so there is nothing to gain from another interpreter."""
    handler = type("Bound", (handler_cls,), {
        "directory_root": str(directory),
        "log_message": lambda self, *a: None,
    })
    httpd = http.server.ThreadingHTTPServer(("127.0.0.1", port), handler)
    if ssl_ctx:
        httpd.socket = ssl_ctx.wrap_socket(httpd.socket, server_side=True)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    _wait(port)
    return httpd


class _Static(http.server.SimpleHTTPRequestHandler):
    directory_root = "."

    def __init__(self, *a, **kw):
        super().__init__(*a, directory=self.directory_root, **kw)


class _BasicAuth(_Static):
    """Refuses until Authorization arrives, then serves the tree. The realm is asserted, so it
    has to be a realm someone would recognise rather than a placeholder."""
    REALM = "Staging"

    def do_GET(self):
        if not self.headers.get("Authorization"):
            self.send_response(401)
            self.send_header("WWW-Authenticate", f'Basic realm="{self.REALM}"')
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        super().do_GET()


def make_pages(root):
    root = pathlib.Path(root)
    root.mkdir(parents=True, exist_ok=True)
    (root / "dialogs.html").write_text(DIALOG_PAGE)
    (root / "find.html").write_text(FIND_PAGE)
    # One page per phase, named for it: a target left over from an earlier phase must never
    # be able to answer a later phase's question about "did the page load".
    (root / "secure.html").write_text("<!doctype html><title>SECURE</title><h1 id='hero'>secure</h1>")
    (root / "protected.html").write_text("<!doctype html><title>PROTECTED</title><h1 id='hero'>protected</h1>")
    return root


def self_signed(root):
    """A certificate nothing on this machine trusts, made fresh for the run. `openssl` ships
    with macOS, so the gate needs nothing installed."""
    key = pathlib.Path(root) / "key.pem"
    crt = pathlib.Path(root) / "cert.pem"
    subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
                    "-keyout", str(key), "-out", str(crt), "-days", "1",
                    "-subj", "/CN=127.0.0.1"],
                   check=True, capture_output=True)
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(str(crt), str(key))
    return ctx


def start_all(root):
    """(plain_port, https_port, auth_port, [servers])"""
    pages = make_pages(root)
    plain, https, auth = _free_port(), _free_port(), _free_port()
    servers = [
        _serve(pages, plain, _Static),
        _serve(pages, https, _Static, ssl_ctx=self_signed(root)),
        _serve(pages, auth, _BasicAuth),
    ]
    return plain, https, auth, servers
