"""A terminal just complete enough to answer "what colour is this character, and what is behind it".

The contrast gate needs the *resolved* colour of every cell, and no capture of raw bytes gives that:
a TUI sets a foreground once and then moves the cursor around for a dozen lines, paints a background
that a later erase reverts, and redraws the same row three times before the frame settles. Only the
final grid is what a reader sees, so the only honest way to measure is to replay the stream the way
ghostty does and read the cells out afterwards.

Deliberately not a terminal: no scrollback, no wrapping subtleties, no charsets, no mouse. It
implements the sequences Claude Code actually emits (SGR, cursor moves, erases, scroll regions,
alternate screen) and ignores the rest. Anything unimplemented is dropped rather than guessed at —
a dropped sequence shows up as text in the wrong place, which is loud, where a guessed one would
quietly report a colour nothing ever rendered.
"""

import codecs

DEFAULT = None   # "whatever the terminal's default is" — resolved by the caller's palette


class Cell:
    __slots__ = ("ch", "fg", "bg", "bold", "faint", "reverse")

    def __init__(self):
        self.ch = " "
        self.fg = DEFAULT
        self.bg = DEFAULT
        self.bold = False
        self.faint = False
        self.reverse = False

    def copy(self):
        c = Cell()
        c.ch, c.fg, c.bg = self.ch, self.fg, self.bg
        c.bold, c.faint, c.reverse = self.bold, self.faint, self.reverse
        return c


class Screen:
    def __init__(self, cols=100, rows=44):
        self.cols, self.rows = cols, rows
        self.grid = [[Cell() for _ in range(cols)] for _ in range(rows)]
        self.x = self.y = 0
        self.top, self.bot = 0, rows - 1
        self._reset_sgr()

    def _reset_sgr(self):
        self.fg = self.bg = DEFAULT
        self.bold = self.faint = self.reverse = False

    def _blank_row(self):
        return [Cell() for _ in range(self.cols)]

    def put(self, ch):
        if self.x >= self.cols:
            self.x = self.cols - 1
        c = self.grid[self.y][self.x]
        c.ch = ch
        c.fg, c.bg = self.fg, self.bg
        c.bold, c.faint, c.reverse = self.bold, self.faint, self.reverse
        self.x += 1

    def newline(self):
        if self.y == self.bot:
            del self.grid[self.top]
            self.grid.insert(self.bot, self._blank_row())
        else:
            self.y = min(self.y + 1, self.rows - 1)

    def erase(self, y, x0, x1):
        for x in range(max(0, x0), min(self.cols, x1)):
            cell = self.grid[y][x]
            cell.ch = " "
            # An erase paints the *current* background — that is how a TUI fills a coloured band —
            # but never the current foreground, since there is no glyph to colour.
            cell.fg = DEFAULT
            cell.bg = self.bg
            cell.bold = cell.faint = cell.reverse = False


class Emulator:
    """Replays a byte stream onto a Screen. `screen` is readable at any point."""

    def __init__(self, cols=100, rows=44):
        self.screen = Screen(cols, rows)
        self.alt = None          # set while the alternate screen is active
        self.saved = None
        # A pty read can end in the middle of an escape sequence. Dropping the fragment would let
        # its tail arrive as printable text on the next read — `\x1b[38;2;51;51;51m` split after
        # `\x1b[3` renders as "8;2;51;51;51m" in the middle of a word — so an incomplete trailing
        # sequence is held back and re-parsed once the rest turns up.
        self._pending = ""
        # The same hazard one level down: a read can also split a multi-byte character, and decoding
        # each chunk on its own turns `─` into replacement characters that no longer look like the
        # box drawing they are. An incremental decoder carries the partial bytes across reads.
        self._decoder = codecs.getincrementaldecoder("utf-8")("replace")

    # --- SGR ------------------------------------------------------------------
    def _sgr(self, params):
        s = self.screen
        i = 0
        if not params:
            params = [0]
        while i < len(params):
            p = params[i]
            if p == 0:
                s._reset_sgr()
            elif p == 1:
                s.bold = True
            elif p == 2:
                s.faint = True
            elif p == 7:
                s.reverse = True
            elif p == 22:
                s.bold = s.faint = False
            elif p == 27:
                s.reverse = False
            elif 30 <= p <= 37:
                s.fg = ("idx", p - 30)
            elif p == 39:
                s.fg = DEFAULT
            elif 40 <= p <= 47:
                s.bg = ("idx", p - 40)
            elif p == 49:
                s.bg = DEFAULT
            elif 90 <= p <= 97:
                s.fg = ("idx", p - 90 + 8)
            elif 100 <= p <= 107:
                s.bg = ("idx", p - 100 + 8)
            elif p in (38, 48):
                target = "fg" if p == 38 else "bg"
                if i + 1 < len(params) and params[i + 1] == 5:
                    val = ("idx", params[i + 2]) if i + 2 < len(params) else DEFAULT
                    i += 2
                elif i + 1 < len(params) and params[i + 1] == 2:
                    rgb = tuple(params[i + 2:i + 5])
                    val = ("rgb", rgb) if len(rgb) == 3 else DEFAULT
                    i += 4
                else:
                    val = DEFAULT
                setattr(s, target, val)
            i += 1

    # --- stream ---------------------------------------------------------------
    def feed(self, data):
        if isinstance(data, bytes):
            data = self._decoder.decode(data)
        if self._pending:
            data, self._pending = self._pending + data, ""
        n, i = len(data), 0
        while i < n:
            ch = data[i]
            if ch == "\x1b":
                nxt = self._escape(data, i)
                if nxt < 0:
                    self._pending = data[i:]
                    return
                i = nxt
                continue
            s = self.screen
            if ch == "\r":
                s.x = 0
            elif ch == "\n":
                s.newline()
            elif ch == "\b":
                s.x = max(0, s.x - 1)
            elif ch == "\t":
                s.x = min(self.screen.cols - 1, (s.x // 8 + 1) * 8)
            elif ch == "\x07":
                pass
            elif ch >= " ":
                s.put(ch)
            i += 1

    def _escape(self, d, i):
        """Index just past the sequence, or -1 if `d` ends before the sequence does."""
        n = len(d)
        if i + 1 >= n:
            return -1
        k = d[i + 1]
        if k == "[":
            j = i + 2
            while j < n and d[j] not in "@ABCDEFGHIJKLMNPSTXZ`abcdefghilmnpqrstuvwxyz{|}~":
                j += 1
            if j >= n:
                return -1
            return self._csi(d[i + 2:j], d[j], j + 1)
        if k == "]":                      # OSC — title, hyperlinks; no cell effect
            j = i + 2
            while j < n:
                if d[j] == "\x07":
                    return j + 1
                if d[j] == "\x1b":
                    if j + 1 >= n:
                        return -1
                    if d[j + 1] == "\\":
                        return j + 2
                j += 1
            return -1
        if k == "7":
            self.saved = (self.screen.x, self.screen.y)
            return i + 2
        if k == "8":
            if self.saved:
                self.screen.x, self.screen.y = self.saved
            return i + 2
        if k in "DEM":
            if k == "M":
                s = self.screen
                if s.y == s.top:
                    del s.grid[s.bot]
                    s.grid.insert(s.top, s._blank_row())
                else:
                    s.y -= 1
            else:
                self.screen.newline()
                if k == "E":
                    self.screen.x = 0
            return i + 2
        if k in "()#%":                   # charset designation
            return i + 3 if i + 2 < n else -1
        return i + 2

    def _csi(self, body, final, nxt):
        s = self.screen
        priv = body[:1] in ("?", ">", "<", "=")
        raw = body[1:] if priv else body
        parts = [q for q in raw.replace(":", ";").split(";")]
        params = [int(q) for q in parts if q.isdigit()]

        def p0(default=1):
            return params[0] if params else default

        if priv:
            # Alternate screen: a fresh grid, so the app's own frame is never measured against
            # leftovers from the shell that launched it.
            if final in "hl" and 1049 in params:
                if final == "h" and self.alt is None:
                    self.alt = self.screen
                    self.screen = Screen(s.cols, s.rows)
                elif final == "l" and self.alt is not None:
                    self.screen, self.alt = self.alt, None
            return nxt
        if final == "m":
            self._sgr(params if params or not raw else [0])
        elif final == "H" or final == "f":
            s.y = max(0, min(s.rows - 1, (params[0] if len(params) > 0 else 1) - 1))
            s.x = max(0, min(s.cols - 1, (params[1] if len(params) > 1 else 1) - 1))
        elif final == "G" or final == "`":
            s.x = max(0, min(s.cols - 1, p0() - 1))
        elif final == "d":
            s.y = max(0, min(s.rows - 1, p0() - 1))
        elif final == "A":
            s.y = max(0, s.y - p0())
        elif final == "B":
            s.y = min(s.rows - 1, s.y + p0())
        elif final == "C":
            s.x = min(s.cols - 1, s.x + p0())
        elif final == "D":
            s.x = max(0, s.x - p0())
        elif final == "E":
            s.y = min(s.rows - 1, s.y + p0()); s.x = 0
        elif final == "F":
            s.y = max(0, s.y - p0()); s.x = 0
        elif final == "J":
            mode = p0(0)
            if mode == 0:
                s.erase(s.y, s.x, s.cols)
                for y in range(s.y + 1, s.rows):
                    s.erase(y, 0, s.cols)
            elif mode == 1:
                s.erase(s.y, 0, s.x + 1)
                for y in range(0, s.y):
                    s.erase(y, 0, s.cols)
            else:
                for y in range(s.rows):
                    s.erase(y, 0, s.cols)
        elif final == "K":
            mode = p0(0)
            if mode == 0:
                s.erase(s.y, s.x, s.cols)
            elif mode == 1:
                s.erase(s.y, 0, s.x + 1)
            else:
                s.erase(s.y, 0, s.cols)
        elif final == "X":
            s.erase(s.y, s.x, s.x + p0())
        elif final == "L":
            for _ in range(p0()):
                del s.grid[s.bot]
                s.grid.insert(s.y, s._blank_row())
        elif final == "M":
            for _ in range(p0()):
                del s.grid[s.y]
                s.grid.insert(s.bot, s._blank_row())
        elif final == "P":
            row = s.grid[s.y]
            for _ in range(p0()):
                del row[s.x]
                row.append(Cell())
        elif final == "@":
            row = s.grid[s.y]
            for _ in range(p0()):
                row.insert(s.x, Cell())
                del row[-1]
        elif final == "r":
            s.top = (params[0] - 1) if len(params) > 0 else 0
            s.bot = (params[1] - 1) if len(params) > 1 else s.rows - 1
            s.top = max(0, min(s.rows - 1, s.top))
            s.bot = max(s.top, min(s.rows - 1, s.bot))
        elif final == "S":
            for _ in range(p0()):
                del s.grid[s.top]; s.grid.insert(s.bot, s._blank_row())
        elif final == "T":
            for _ in range(p0()):
                del s.grid[s.bot]; s.grid.insert(s.top, s._blank_row())
        return nxt

    # --- reading out ----------------------------------------------------------
    def text(self):
        return "\n".join("".join(c.ch for c in row).rstrip() for row in self.screen.grid)

    def cells(self):
        for y, row in enumerate(self.screen.grid):
            for x, c in enumerate(row):
                yield y, x, c
