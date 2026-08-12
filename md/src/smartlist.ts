/// Structure editing for lists, as pure `(source, cursor) -> (source, cursor)` rewrites.
///
/// Deliberately document-level rather than block-level, even though the user is typing inside
/// one revealed block: pressing Enter at the end of a list item *creates a sibling block*, and
/// Tab on the first item of a list changes how the whole list renumbers. Neither fits inside a
/// single block's text, so the whole document is the unit and the view resegments afterwards.

export interface Edit {
  source: string
  cursor: number
}

const ITEM_RE = /^(\s*)([-*+]|(\d+)([.)]))(\s+)(\[[ xX]\]\s*)?(.*)$/
/// Matches the indent-only prefix, used to keep a continuation aligned under its item.
const INDENT_STEP = 2

interface ItemLine {
  indent: string
  marker: string
  /// The ordered-list number, or null for a bullet.
  number: number | null
  /// The delimiter after an ordered number: "." or ")".
  delim: string
  /// Whitespace between marker and content.
  gap: string
  /// The `[ ] ` / `[x] ` prefix, or "" — carried onto a continued item so a checklist keeps
  /// producing checkboxes rather than degrading to plain bullets after one Enter.
  task: string
  content: string
}

function parseItem(line: string): ItemLine | null {
  const m = ITEM_RE.exec(line)
  if (!m) return null
  return {
    indent: m[1],
    marker: m[2],
    number: m[3] !== undefined ? Number(m[3]) : null,
    delim: m[4] ?? "",
    gap: m[5],
    task: m[6] ?? "",
    content: m[7],
  }
}

/// Bounds of the line containing `cursor`, excluding its newline.
function lineAt(source: string, cursor: number): { start: number; end: number; text: string } {
  const start = source.lastIndexOf("\n", Math.max(0, cursor - 1)) + 1
  const nl = source.indexOf("\n", cursor)
  const end = nl === -1 ? source.length : nl
  return { start, end, text: source.slice(start, end) }
}

/// Enter inside a list item. Continues the list with a fresh marker at the same indent,
/// carrying the checkbox if there was one.
///
/// An item whose content is empty ends the list instead — the universal editor convention,
/// and the only way out of a list that doesn't require reaching for the mouse. Ending an
/// indented item outdents it one step first, so Enter walks back out of nesting one level per
/// press before finally breaking out.
///
/// Returns null when the cursor is not in a list item, meaning "no smart behavior — insert a
/// plain newline".
export function continueList(source: string, cursor: number): Edit | null {
  const line = lineAt(source, cursor)
  const item = parseItem(line.text)
  if (!item) return null
  // Splitting mid-content is ordinary text editing, not list continuation: only a cursor at
  // (or past) the end of the line is asking for a new item.
  if (cursor < line.end) return null

  if (item.content.trim() === "" && item.task === "") {
    if (item.indent.length >= INDENT_STEP) {
      const outdented = item.indent.slice(INDENT_STEP) + item.marker + item.gap
      return {
        source: source.slice(0, line.start) + outdented + source.slice(line.end),
        cursor: line.start + outdented.length,
      }
    }
    // Top level: clear the orphan marker and leave a blank line, which is where the writer
    // now types ordinary prose.
    return {
      source: source.slice(0, line.start) + source.slice(line.end),
      cursor: line.start,
    }
  }

  const marker = item.number !== null ? `${item.number + 1}${item.delim}` : item.marker
  // An unchecked box, never a copy of the checked state: continuing a done item means
  // writing the next thing to do.
  const task = item.task ? "[ ] " : ""
  const inserted = "\n" + item.indent + marker + item.gap + task
  return {
    source: source.slice(0, cursor) + inserted + source.slice(cursor),
    cursor: cursor + inserted.length,
  }
}

/// Tab / Shift-Tab on a list item. `dir` is +1 to indent, -1 to outdent.
///
/// Indenting the first item of a list is refused: CommonMark has nothing for it to nest
/// under, so it would silently become a code block or a sibling at the same level depending
/// on context. Refusing is honest and keeps Tab from mangling the document.
///
/// `previousIndent` supplies that predecessor's indent when `source` cannot show it. The
/// caller is usually editing ONE list item in isolation — a revealed block — so the sibling
/// this item would nest under lives in a different block entirely, and without it every Tab
/// on a one-line buffer would be refused as "first item of a list".
export function indentItem(
  source: string,
  cursor: number,
  dir: 1 | -1,
  previousIndent: number | null = null,
): Edit | null {
  const line = lineAt(source, cursor)
  const item = parseItem(line.text)
  if (!item) return null

  if (dir === 1) {
    const prev = previousItemLine(source, line.start)
    const prevIndent = prev ? prev.indent.length : previousIndent
    if (prevIndent === null || prevIndent < item.indent.length) return null
    const pad = " ".repeat(INDENT_STEP)
    return {
      source: source.slice(0, line.start) + pad + source.slice(line.start),
      cursor: cursor + pad.length,
    }
  }

  if (item.indent.length < INDENT_STEP) return null
  return {
    source: source.slice(0, line.start) + source.slice(line.start + INDENT_STEP),
    cursor: Math.max(line.start, cursor - INDENT_STEP),
  }
}

/// The nearest list-item line above `start`, stopping at a blank line — a blank line ends the
/// list, so an item after one has no previous sibling to nest under.
function previousItemLine(source: string, start: number): ItemLine | null {
  let pos = start
  while (pos > 0) {
    const line = lineAt(source, pos - 1)
    if (line.text.trim() === "") return null
    const item = parseItem(line.text)
    if (item) return item
    pos = line.start
  }
  return null
}

/// Renumber every ordered list so the numbers run 1, 2, 3 from each list's own start, per
/// nesting depth. Run after any structural change, because the alternative — trusting what
/// the writer typed — leaves "1. 2. 2. 5." on screen after a single insertion, and this is a
/// *rendered* editor where those digits are visible output, not source noise.
///
/// The first item's number is honoured as the list's start (`3.` then `4.` then `5.`), which
/// is the one case where the typed number carries intent.
export function renumber(source: string): string {
  const lines = source.split("\n")
  // Depth (in indent columns) -> the number the next item at that depth takes.
  const counters = new Map<number, number>()
  let inFence = false

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i]
    if (/^\s*(```|~~~)/.test(line)) {
      inFence = !inFence
      continue
    }
    // A fence's contents are data, not document structure: renumbering inside one would
    // rewrite the user's sample code.
    if (inFence) continue

    if (line.trim() === "") {
      counters.clear()
      continue
    }
    const item = parseItem(line)
    if (!item) continue

    const depth = item.indent.length
    // A deeper list has started and any sibling counters below it are stale.
    for (const key of [...counters.keys()]) if (key > depth) counters.delete(key)

    if (item.number === null) {
      counters.delete(depth)
      continue
    }
    const next = counters.get(depth) ?? item.number
    counters.set(depth, next + 1)
    lines[i] = item.indent + next + item.delim + item.gap + item.task + item.content
  }
  return lines.join("\n")
}

/// Renumber while keeping the cursor on the same character. Renumbering can change how many
/// digits precede the cursor ("9." -> "10."), and a cursor left at a raw offset would drift
/// by that difference on every press of Enter deep in a long list.
///
/// The anchor is distance from the END of the line, not the start: renumbering only ever
/// rewrites the marker prefix, so everything after it — which is all the writer's own text,
/// and where the cursor actually is — keeps its position relative to the line's tail.
export function renumberPreservingCursor(source: string, cursor: number): Edit {
  const before = source.slice(0, cursor)
  const lineIndex = before.split("\n").length - 1

  const oldLines = source.split("\n")
  const oldLine = oldLines[lineIndex] ?? ""
  const column = before.length - (before.lastIndexOf("\n") + 1)
  const fromEnd = oldLine.length - column

  const next = renumber(source)
  const lines = next.split("\n")
  let offset = 0
  for (let i = 0; i < lineIndex && i < lines.length; i++) offset += lines[i].length + 1
  const newLine = lines[Math.min(lineIndex, lines.length - 1)] ?? ""
  return { source: next, cursor: offset + Math.max(0, newLine.length - fromEnd) }
}
