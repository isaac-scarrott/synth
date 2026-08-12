import { Lexer, type Token } from "marked"

/// The unit of both rendering and reveal. A block owns a half-open source range, so editing
/// one is a splice into the document string and nothing else needs to know where it lived.
///
/// List *items* are blocks in their own right rather than one block per list. That is what
/// makes the two locked list interactions possible at all: revealing a single item without
/// dropping the rest of the list back to raw, and toggling a checkbox by clicking the item
/// you aimed at. The cost is that a list's rendering is reassembled from its items, which is
/// why `listDepth` and `marker` ride along.
export type BlockKind =
  | "heading"
  | "paragraph"
  | "list-item"
  | "table"
  | "code"
  | "blockquote"
  | "hr"
  | "html"
  | "footnote"
  | "blank"

export interface Block {
  kind: BlockKind
  /// Half-open source range. `source.slice(start, end)` is exactly `raw`.
  start: number
  end: number
  raw: string
  /// Heading level (1–6), else 0.
  level: number
  /// Indent depth for a list item, in nesting steps rather than columns.
  listDepth: number
  /// The literal list marker as typed ("-", "*", "1.", "2)"), else "".
  marker: string
  /// Task-list state: `true`/`false` for `- [x]`/`- [ ]`, `undefined` for a plain item.
  checked?: boolean
  /// A fence's info string ("typescript", "mermaid"), else "".
  lang: string
}

/// A line that opens a list item, at any indent: `- x`, `* x`, `+ x`, `1. x`, `2) x`.
const LIST_ITEM_RE = /^(\s*)([-*+]|\d+[.)])([ \t]+|$)(.*)$/
/// The `[ ]` / `[x]` that makes a list item a task item, taken from the item's content.
const TASK_RE = /^\[([ xX])\]\s?/

/// One nesting step per this many leading columns. CommonMark ties nesting to the parent
/// marker's width, which varies; markdown people type two or four spaces and mean "one
/// level". Rounding on 2 reads both the same way and never invents a depth the writer
/// didn't intend.
const INDENT_STEP = 2

export function listIndentOf(line: string): number {
  const m = LIST_ITEM_RE.exec(line)
  return m ? m[1].length : 0
}

/// Segment `source` into blocks covering it end to end, with no gaps: every offset in the
/// document belongs to exactly one block. Gapless is a hard requirement — `blockAt` maps a
/// cursor offset to a block by containment, and a hole would strand the cursor.
export function segment(source: string): Block[] {
  const tokens = new Lexer({ gfm: true }).lex(source) as Token[]
  const blocks: Block[] = []
  let offset = 0
  for (const token of tokens) {
    const raw = token.raw ?? ""
    if (raw.length === 0) continue
    push(blocks, token, offset)
    offset += raw.length
  }
  // The lexer drops a trailing run it considers insignificant; the document must still be
  // covered, or a cursor parked at EOF has no block.
  if (offset < source.length) {
    blocks.push(blank(source.slice(offset), offset))
  }
  if (blocks.length === 0) blocks.push(blank("", 0))
  return blocks
}

function push(out: Block[], token: Token, offset: number) {
  const raw = token.raw as string
  switch (token.type) {
    case "list":
      out.push(...splitListItems(raw, offset))
      return
    case "space":
      out.push(blank(raw, offset))
      return
    case "heading":
      out.push(base("heading", raw, offset, { level: (token as any).depth ?? 1 }))
      return
    case "code":
      out.push(base("code", raw, offset, { lang: ((token as any).lang ?? "").trim() }))
      return
    case "table":
      out.push(base("table", raw, offset))
      return
    case "blockquote":
      out.push(base("blockquote", raw, offset))
      return
    case "hr":
      out.push(base("hr", raw, offset))
      return
    case "html":
      out.push(base("html", raw, offset))
      return
    default:
      // A footnote definition lexes as a paragraph; it is called out so the reader can style
      // it apart from body text.
      out.push(base(/^\[\^[^\]]+\]:/.test(raw) ? "footnote" : "paragraph", raw, offset))
  }
}

/// Split a list token's raw into one block per item, at any nesting depth. Line-based rather
/// than walking marked's nested item tokens: an item's `raw` includes its children's text, so
/// the token tree double-counts source that this has to slice exactly once.
///
/// Works in cut points and slices the original `raw`, never reassembling text from lines —
/// rejoining loses each item's trailing newline, and a byte lost here is a one-offset hole
/// in the document's block coverage.
function splitListItems(raw: string, offset: number): Block[] {
  const lines = raw.split("\n")
  const cuts: number[] = []
  let local = 0
  for (let i = 0; i < lines.length; i++) {
    if (LIST_ITEM_RE.test(lines[i])) cuts.push(local)
    local += lines[i].length + (i < lines.length - 1 ? 1 : 0)
  }

  const blocks: Block[] = []
  // Matter before the first marker, which the lexer only hands us for a malformed list.
  // Kept as its own block so coverage stays gapless.
  if (cuts.length === 0) return [blank(raw, offset)]
  if (cuts[0] > 0) blocks.push(blank(raw.slice(0, cuts[0]), offset))

  for (let i = 0; i < cuts.length; i++) {
    const from = cuts[i]
    const to = i + 1 < cuts.length ? cuts[i + 1] : raw.length
    blocks.push(listItem(raw.slice(from, to), offset + from))
  }
  return blocks
}

function listItem(raw: string, offset: number): Block {
  const m = LIST_ITEM_RE.exec(raw.split("\n")[0])
  const indent = m ? m[1].length : 0
  const marker = m ? m[2] : "-"
  const content = m ? m[4] : raw
  const task = TASK_RE.exec(content)
  return {
    kind: "list-item",
    start: offset,
    end: offset + raw.length,
    raw,
    level: 0,
    listDepth: Math.floor(indent / INDENT_STEP),
    marker,
    checked: task ? task[1].toLowerCase() === "x" : undefined,
    lang: "",
  }
}

function base(kind: BlockKind, raw: string, offset: number, extra: Partial<Block> = {}): Block {
  return {
    kind,
    start: offset,
    end: offset + raw.length,
    raw,
    level: 0,
    listDepth: 0,
    marker: "",
    lang: "",
    ...extra,
  }
}

function blank(raw: string, offset: number): Block {
  return base("blank", raw, offset)
}

/// The block containing `offset`. Ranges are half-open, so an offset sitting exactly on a
/// boundary belongs to the block it opens; an offset at EOF belongs to the last block.
export function blockAt(blocks: Block[], offset: number): number {
  for (let i = 0; i < blocks.length; i++) {
    if (offset >= blocks[i].start && offset < blocks[i].end) return i
  }
  return blocks.length - 1
}

/// The nearest block a cursor can usefully occupy, searching in `dir` from `index`. Blank
/// blocks are pure separators — landing on one would show the user an empty raw box — so
/// arrowing past the end of a paragraph skips the blank line and reveals the next real block.
export function nextEditable(blocks: Block[], index: number, dir: 1 | -1): number {
  for (let i = index; i >= 0 && i < blocks.length; i += dir) {
    if (blocks[i].kind !== "blank") return i
  }
  return -1
}

/// Splice `text` over `[start, end)`. The single mutation path for the document, so that
/// every edit — typing, checkbox toggle, smart-list rewrite — resegments identically.
export function splice(source: string, start: number, end: number, text: string): string {
  return source.slice(0, start) + text + source.slice(end)
}

/// Flip a task item's `[ ]` ⇄ `[x]` in place, returning the new document. Null when the
/// block is not a task item, so callers can treat "clicked a non-checkbox" as a no-op.
export function toggleTask(source: string, block: Block): string | null {
  if (block.kind !== "list-item" || block.checked === undefined) return null
  const m = LIST_ITEM_RE.exec(block.raw.split("\n")[0])
  if (!m) return null
  const head = m[1] + m[2] + m[3]
  const box = block.checked ? "[ ]" : "[x]"
  const rest = block.raw.slice(head.length).replace(TASK_RE, "")
  return splice(source, block.start, block.end, head + box + " " + rest)
}

/// Heading blocks in document order, for the outline overlay.
export function outline(blocks: Block[]): { index: number; level: number; text: string }[] {
  return blocks
    .map((b, index) => ({ b, index }))
    .filter(({ b }) => b.kind === "heading")
    .map(({ b, index }) => ({
      index,
      level: b.level,
      text: b.raw.replace(/^#+\s*/, "").replace(/\s*#*\s*$/, "").trim(),
    }))
}
