#!/usr/bin/env python3
"""Run a command on a real PTY, feed it keystrokes, and print everything it drew.

Why this exists rather than `script -q`: macOS's `script` calls tcgetattr on its own stdin
and fails outright when that is a pipe, which is exactly what a test harness gives it. This
allocates the pty itself, so the child gets a controlling terminal, a real window size, and
isatty() true — the conditions the shipped TUI actually runs under — while the harness on the
other side stays an ordinary piped process.

Usage:  pty-driver.py '<json script>' -- <command> [args...]

The script is a list of steps, executed in order:
    {"wait": 1200}          sleep this many milliseconds, reading output throughout
    {"send": "\\r"}          write these bytes to the pty

Output from the child is copied to stdout verbatim, escape sequences and all.
"""
import json
import os
import pty
import select
import signal
import struct
import sys
import termios
import fcntl

COLUMNS, LINES = 90, 40


def main() -> int:
    steps = json.loads(sys.argv[1])
    command = sys.argv[sys.argv.index("--") + 1:]

    pid, fd = pty.fork()
    if pid == 0:
        # Child: it is now the session leader with the slave pty as its controlling terminal.
        os.environ["TERM"] = "xterm-256color"
        os.environ["COLUMNS"] = str(COLUMNS)
        os.environ["LINES"] = str(LINES)
        os.execvp(command[0], command)
        os._exit(127)

    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", LINES, COLUMNS, 0, 0))

    captured = bytearray()

    def drain(timeout_s: float) -> None:
        """Read for `timeout_s`, never blocking longer than the child takes to be quiet."""
        deadline = timeout_s
        while deadline > 0:
            slice_s = min(0.05, deadline)
            ready, _, _ = select.select([fd], [], [], slice_s)
            deadline -= slice_s
            if not ready:
                continue
            try:
                chunk = os.read(fd, 65536)
            except OSError:
                return
            if not chunk:
                return
            captured.extend(chunk)

    for step in steps:
        if "wait" in step:
            drain(step["wait"] / 1000)
        if "send" in step:
            os.write(fd, step["send"].encode("utf-8"))

    try:
        os.kill(pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    drain(0.4)
    try:
        os.waitpid(pid, 0)
    except ChildProcessError:
        pass

    sys.stdout.buffer.write(bytes(captured))
    sys.stdout.buffer.flush()
    return 0


if __name__ == "__main__":
    sys.exit(main())
