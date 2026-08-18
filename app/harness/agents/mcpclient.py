"""Speak MCP to a bundled server the way an agent does, without an agent.

t4b and t4c prove a real agent finds these tools and drives the browser with them. That is the
integration claim, and it is worth what it costs — minutes, a model, and a turn that has to go
the way you hoped. It is the wrong instrument for the tool CONTRACT: whether sessionId is
required, whether a ref survives a re-render, what a screenshot returns. Those are answers the
server gives directly, and asking it directly is both exact and fast.

The launch comes from the app's own `automation.mcpLaunchEnv`, so this can never drift from
what a real agent is handed — it is the same command line and the same environment.
"""
import json, os, subprocess, threading


class MCPError(RuntimeError):
    pass


class MCPServer:
    """One bundled MCP server over stdio. `with MCPServer(...) as s: s.call(...)`."""

    def __init__(self, launch_env, server="synth-browser", session_id=None):
        spec = json.loads(launch_env["SYNTH_MCP_CLAUDE"])["mcpServers"][server]
        env = dict(os.environ)
        env.update(spec.get("env") or {})
        if session_id:
            env["SYNTH_SESSION_ID"] = session_id
        self._proc = subprocess.Popen(
            [spec["command"], *spec["args"]], env=env, text=True,
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        # stderr is drained rather than ignored: a server that dies on startup says why there,
        # and a full pipe would wedge it silently.
        self.stderr = []
        threading.Thread(target=self._drain, daemon=True).start()
        self._next_id = 0
        self.tools = {}

    def _drain(self):
        for line in self._proc.stderr:
            self.stderr.append(line.rstrip())

    def __enter__(self):
        self._request("initialize", {
            "protocolVersion": "2024-11-05",
            "capabilities": {},
            "clientInfo": {"name": "synth-gate", "version": "1"},
        })
        self._notify("notifications/initialized")
        self.tools = {t["name"]: t for t in self._request("tools/list", {})["tools"]}
        return self

    def __exit__(self, *exc):
        self.close()

    def close(self):
        try:
            self._proc.stdin.close()
            self._proc.wait(timeout=10)
        except Exception:
            self._proc.kill()

    def _send(self, message):
        self._proc.stdin.write(json.dumps(message) + "\n")
        self._proc.stdin.flush()

    def _notify(self, method, params=None):
        self._send({"jsonrpc": "2.0", "method": method, "params": params or {}})

    def _request(self, method, params, timeout=180):
        self._next_id += 1
        want = self._next_id
        self._send({"jsonrpc": "2.0", "id": want, "method": method, "params": params})
        # Notifications and server-initiated requests can arrive in between; only the reply
        # carrying our id is the answer.
        while True:
            line = self._proc.stdout.readline()
            if not line:
                raise MCPError(f"server closed while waiting for {method}: "
                               + "\n".join(self.stderr[-8:]))
            message = json.loads(line)
            if message.get("id") != want:
                continue
            if "error" in message:
                raise MCPError(f"{method}: {message['error']}")
            return message["result"]

    def call(self, tool, **arguments):
        """The tool's reply as (text, is_error). A tool that raises comes back as an error
        RESULT rather than a protocol failure (mcp/shared.mjs makeTool), which is what an agent
        sees, so that is what this returns."""
        result = self._request("tools/call", {"name": tool, "arguments": arguments})
        text = "\n".join(c.get("text", "") for c in result.get("content", [])
                         if c.get("type") == "text")
        return text, bool(result.get("isError"))

    def images(self, tool, **arguments):
        """How many image blocks a tool's reply carried."""
        result = self._request("tools/call", {"name": tool, "arguments": arguments})
        return sum(1 for c in result.get("content", []) if c.get("type") == "image")

    def required(self, tool):
        return set(self.tools[tool]["inputSchema"].get("required") or [])
