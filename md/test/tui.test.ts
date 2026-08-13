import { expect, test, describe } from "bun:test"
import { writeFile } from "node:fs/promises"
import { dirname, join } from "node:path"
import { colOf, open, rowOf, trim } from "./harness"

/// End-to-end behaviour of the TUI: real renderer, real keystroke and mouse bytes, real file
/// on disk. Every assertion is either something on screen or something in the file — the two
/// things a user can actually observe.

const RICH = `---
title: Release plan
owner: isaac
---

# Release plan

Ship the **viewer** and the _editor_ together. See [the notes](./notes.md).

## Tasks

- [ ] cut the branch
- [x] write the spike
- plain bullet
  - nested bullet

## Order

1. first
2. second

## Data

| stage | state |
| ----- | ----- |
| spike | done  |
| build | now   |

> A quoted aside.

\`\`\`ts
const version: number = 1
\`\`\`
`

describe("rendering", () => {
  test("renders a rich document with every element styled, not raw", async () => {
    const h = await open(RICH)
    const frame = trim(await h.frame())

    // Frontmatter is a key/value header, never the lexer's break/paragraph/break.
    expect(frame).toContain("title")
    expect(frame).toContain("Release plan")
    expect(frame).not.toContain("---")

    // Inline markers are concealed; their text survives.
    expect(frame).toContain("Ship the viewer and the editor together.")
    expect(frame).not.toContain("**")
    expect(frame).not.toContain("_editor_")

    // Task items are checkboxes, plain items are bullets, and neither shows its source.
    expect(frame).toContain("□ cut the branch")
    expect(frame).toContain("■ write the spike")
    expect(frame).toContain("• plain bullet")
    expect(frame).not.toContain("- [ ]")

    // Ordered items keep their numbers; tables draw as tables; fences keep their code.
    expect(frame).toContain("1. first")
    expect(frame).toContain("2. second")
    expect(frame).toContain("│stage")
    expect(frame).toContain("const version: number = 1")

    await h.dispose()
  }, 30000)

  test("centres the column and leaves a gutter on both sides", async () => {
    const h = await open("# Heading\n", { width: 100 })
    const frame = await h.frame()
    expect(colOf(frame, "Heading")).toBeGreaterThan(2)
    await h.dispose()
  }, 30000)

  test("a long paragraph wraps inside the column instead of running off the page", async () => {
    const words = Array.from({ length: 40 }, (_, i) => `word${i}`).join(" ")
    const h = await open(`# Title\n\n${words}\n`, { width: 100 })
    const frame = await h.frame()

    // Every word is on screen — nothing was clipped at the right edge…
    const flat = trim(frame).replace(/\s+/g, " ")
    expect(flat).toContain("word0")
    expect(flat).toContain("word39")
    // …because the paragraph broke across lines rather than holding one long one.
    expect(rowOf(frame, "word39")).toBeGreaterThan(rowOf(frame, "word0"))
    for (const line of frame.split("\n")) expect(line.replace(/\s+$/, "").length).toBeLessThanOrEqual(95)
    await h.dispose()
  }, 30000)

  test("renders a mermaid fence as marked code rather than dropping it", async () => {
    // OpenTUI 0.5.1 has no mermaid renderable (see the ADR); the locked fallback is that the
    // diagram source stays visible and highlighted rather than vanishing.
    const h = await open("```mermaid\ngraph TD\n  A --> B\n```\n")
    const frame = trim(await h.frame())
    expect(frame).toContain("graph TD")
    expect(frame).toContain("A --> B")
    await h.dispose()
  }, 30000)
})

describe("block reveal", () => {
  test("clicking a block shows its raw markdown and leaving snaps it back", async () => {
    const h = await open("# Title\n\nSome **bold** prose.\n")
    let frame = await h.frame()
    expect(trim(frame)).toContain("Some bold prose.")

    const row = rowOf(frame, "Some bold prose.")
    await h.mouse.click(colOf(frame, "Some") + 2, row)
    frame = await h.frame()
    // The clicked block, and only it, is now source.
    expect(trim(frame)).toContain("Some **bold** prose.")
    expect(trim(frame)).toContain("Title")
    expect(trim(frame)).not.toContain("# Title")

    h.keys.pressEscape()
    frame = await h.frame()
    expect(trim(frame)).toContain("Some bold prose.")
    expect(trim(frame)).not.toContain("**")

    await h.dispose()
  }, 30000)

  test("clicking a different block moves the reveal rather than opening two", async () => {
    const h = await open("# Title\n\nFirst **para**.\n\nSecond _para_.\n")
    let frame = await h.frame()
    await h.mouse.click(colOf(frame, "First") + 1, rowOf(frame, "First"))
    frame = await h.frame()
    expect(trim(frame)).toContain("First **para**.")

    await h.mouse.click(colOf(frame, "Second") + 1, rowOf(frame, "Second"))
    frame = await h.frame()
    expect(trim(frame)).toContain("Second _para_.")
    expect(trim(frame)).not.toContain("First **para**.")

    await h.dispose()
  }, 30000)

  test("clicking off the text folds the block back, the same as escape", async () => {
    const h = await open("# Title\n\nSome **bold** prose.\n\nA second paragraph.\n")
    let frame = await h.frame()
    await h.mouse.click(colOf(frame, "Some") + 2, rowOf(frame, "Some"))
    frame = await h.frame()
    expect(trim(frame)).toContain("Some **bold** prose.")

    // The margin beside the column — inside the page, on no block at all.
    await h.mouse.click(0, rowOf(frame, "Some **bold** prose."))
    frame = await h.frame()
    expect(trim(frame)).toContain("Some bold prose.")
    expect(trim(frame)).not.toContain("**")

    await h.dispose()
  }, 30000)

  test("clicking empty space below the document also folds the block back", async () => {
    const h = await open("# Title\n\nSome **bold** prose.\n")
    let frame = await h.frame()
    await h.mouse.click(colOf(frame, "Some") + 2, rowOf(frame, "Some"))
    expect(trim(await h.frame())).toContain("Some **bold** prose.")

    // Well past the last block, still inside the scrolling page.
    await h.mouse.click(20, 30)
    expect(trim(await h.frame())).not.toContain("**")
    await h.dispose()
  }, 30000)

  test("clicking off the text keeps the edit rather than discarding it", async () => {
    const h = await open("# Title\n\nProse.\n")
    const frame = await h.frame()
    await h.mouse.click(colOf(frame, "Prose.") + 6, rowOf(frame, "Prose."))
    await h.keys.typeText(" kept")
    await h.mouse.click(0, 30)
    await h.frame()

    expect(h.app.fileState.text).toContain("Prose. kept")
    await h.settleSave()
    expect(await h.onDisk()).toContain("Prose. kept")
    await h.dispose()
  }, 30000)

  test("clicking a block while another is open moves the reveal, not closes it", async () => {
    const h = await open("# Title\n\nFirst **para**.\n\nSecond _para_.\n")
    let frame = await h.frame()
    await h.mouse.click(colOf(frame, "First") + 1, rowOf(frame, "First"))
    frame = await h.frame()
    expect(trim(frame)).toContain("First **para**.")

    await h.mouse.click(colOf(frame, "Second") + 1, rowOf(frame, "Second"))
    frame = await h.frame()
    // The second is open — a block click must not be swallowed by the fold-back behind it.
    expect(trim(frame)).toContain("Second _para_.")
    expect(trim(frame)).not.toContain("First **para**.")
    await h.dispose()
  }, 30000)

  /// Distinct words, no inline markup, longer than the 84-column measure: raw and rendered
  /// are byte-identical, so the wrap-aware click mapping can be asserted to the character —
  /// any concealment or wrap drift would land the caret on the wrong word.
  test("clicking a word on the second visual line of a wrapped paragraph lands there", async () => {
    const words = Array.from({ length: 30 }, (_, i) => `word${String(i).padStart(2, "0")}`)
    const h = await open(words.join(" ") + "\n")
    const frame = await h.frame()
    const firstRow = rowOf(frame, "word00")
    // A word the wrap pushed onto the SECOND visual line — found on screen, not computed,
    // so the test keeps working if the measure changes.
    const target = words.find((w) => rowOf(frame, w) === firstRow + 1)
    expect(target).toBeTruthy()
    await h.mouse.click(colOf(frame, target!), rowOf(frame, target!))
    // A settled frame before typing: the visual→logical refinement runs one frame after the
    // click, once the editor has laid out its wrap.
    await h.frame()
    await h.keys.typeText("QQ")
    await h.frame()

    // The caret was ON the clicked word — not at the paragraph start, not on line 1.
    expect(h.app.fileState.text).toContain("QQ" + target)
    await h.dispose()
  }, 30000)

  test("click then type immediately lands at the clicked character on a single line", async () => {
    const h = await open("# Title\n\nProse here today.\n")
    const frame = await h.frame()
    // Between "Prose " and "here" — and type with no settled frame in between, which is the
    // synchronous fast path: the deferred refinement must yield to the user's keystrokes.
    await h.mouse.click(colOf(frame, "Prose here today.") + 6, rowOf(frame, "Prose here today."))
    await h.keys.typeText("ZZ")
    await h.frame()

    expect(h.app.fileState.text).toContain("Prose ZZhere today.")
    await h.dispose()
  }, 30000)

  test("Enter after scrolling reveals a block the reader can see", async () => {
    const doc = Array.from({ length: 30 }, (_, i) => `paragraph ${i}`).join("\n\n") + "\n"
    const h = await open(doc, { height: 20 })
    await h.frame()
    h.keys.pressKey("\x1b[6~") // pagedown
    await h.frame()
    h.keys.pressKey("\x1b[6~")
    await h.frame()

    h.keys.pressEnter()
    await h.keys.typeText("MM")
    await h.frame()

    // The reveal went to a block inside the scrolled viewport, not back to the top of the
    // file — the caret would otherwise be pages away from what the reader was looking at.
    const landed = /MMparagraph (\d+)/.exec(h.app.fileState.text)
    expect(landed).not.toBeNull()
    expect(Number(landed![1])).toBeGreaterThan(5)
    await h.dispose()
  }, 30000)

  test("arrowing down through many blocks keeps the caret on screen", async () => {
    const doc = Array.from({ length: 30 }, (_, i) => `paragraph ${i}`).join("\n\n") + "\n"
    const h = await open(doc, { height: 20 })
    await h.frame()
    h.keys.pressEnter()
    await h.frame()
    // Each press is at the single-line block's bottom edge, so each steps to the next block.
    for (let i = 0; i < 15; i++) {
      h.keys.pressArrow("down")
      await h.frame()
    }
    await h.keys.typeText("VV")
    const frame = trim(await h.frame())

    expect(h.app.fileState.text).toContain("VVparagraph 15")
    // The scroll followed the reveal: what is being edited is on screen.
    expect(frame).toContain("VVparagraph 15")
    await h.dispose()
  }, 30000)

  test("clicking the frontmatter header neither folds the open block nor edits", async () => {
    const h = await open("---\ntitle: Plan\n---\n\nSome **bold** prose.\n")
    let frame = await h.frame()
    await h.mouse.click(colOf(frame, "Some") + 2, rowOf(frame, "Some"))
    frame = await h.frame()
    expect(trim(frame)).toContain("Some **bold** prose.")

    // The header is display-only (see buildFrontmatter): a click aimed AT it is not a click
    // away, so the open block stays open — and no editor appears over the header.
    await h.mouse.click(colOf(frame, "title"), rowOf(frame, "title"))
    frame = trim(await h.frame())
    expect(frame).toContain("Some **bold** prose.")
    expect(frame).not.toContain("---")
    await h.dispose()
  }, 30000)

  test("escape from a plain reading view does nothing rather than becoming a mode", async () => {
    const h = await open("# Title\n\nProse.\n")
    const before = await h.frame()
    h.keys.pressEscape()
    h.keys.pressEscape()
    expect(await h.frame()).toBe(before)
    await h.dispose()
  }, 30000)
})

describe("editing", () => {
  test("typing into a revealed block reaches the buffer and the file", async () => {
    const h = await open("# Title\n\nProse.\n")
    const frame = await h.frame()
    await h.mouse.click(colOf(frame, "Prose.") + 6, rowOf(frame, "Prose."))
    await h.keys.typeText(" More.")
    await h.frame()

    expect(h.app.fileState.text).toContain("Prose. More.")
    await h.settleSave()
    expect(await h.onDisk()).toContain("Prose. More.")
    await h.dispose()
  }, 30000)

  test("Enter continues a list, and the new item is a real block", async () => {
    const h = await open("# Tasks\n\n- alpha\n")
    let frame = await h.frame()
    await h.mouse.click(colOf(frame, "alpha") + 5, rowOf(frame, "alpha"))
    h.keys.pressEnter()
    await h.keys.typeText("beta")
    h.keys.pressEscape()
    frame = await h.frame()

    expect(trim(frame)).toContain("• alpha")
    expect(trim(frame)).toContain("• beta")
    expect(h.app.fileState.text).toContain("- alpha\n- beta")
    await h.dispose()
  }, 30000)

  test("Enter on a task item carries the checkbox forward unchecked", async () => {
    const h = await open("- [x] done\n")
    const frame = await h.frame()
    await h.mouse.click(colOf(frame, "done") + 4, rowOf(frame, "done"))
    h.keys.pressEnter()
    await h.keys.typeText("next")
    h.keys.pressEscape()

    expect(h.app.fileState.text).toContain("- [x] done\n- [ ] next")
    expect(trim(await h.frame())).toContain("□ next")
    await h.dispose()
  }, 30000)

  test("Tab indents a list item and the render nests it", async () => {
    const h = await open("- alpha\n- beta\n")
    let frame = await h.frame()
    await h.mouse.click(colOf(frame, "beta") + 4, rowOf(frame, "beta"))
    h.keys.pressTab()
    h.keys.pressEscape()
    frame = await h.frame()

    expect(h.app.fileState.text).toContain("- alpha\n  - beta")
    // Nesting is visible: the child's glyph sits right of the parent's.
    expect(colOf(frame, "◦ beta")).toBeGreaterThan(colOf(frame, "• alpha"))
    await h.dispose()
  }, 30000)

  test("typing '- ' turns a paragraph into a bullet on leaving the block", async () => {
    const h = await open("# Title\n\nplain\n")
    let frame = await h.frame()
    await h.mouse.click(colOf(frame, "plain"), rowOf(frame, "plain"))
    // Cursor to the very start of the block, then type the marker.
    h.keys.pressKey("HOME")
    await h.keys.typeText("- ")
    h.keys.pressEscape()
    frame = await h.frame()

    expect(h.app.fileState.text).toContain("- plain")
    expect(trim(frame)).toContain("• plain")
    await h.dispose()
  }, 30000)

  test("an ordered list renumbers itself after an insertion", async () => {
    const h = await open("1. one\n2. two\n")
    const frame = await h.frame()
    await h.mouse.click(colOf(frame, "one") + 3, rowOf(frame, "one"))
    h.keys.pressEnter()
    await h.keys.typeText("inserted")
    h.keys.pressEscape()
    await h.frame()

    expect(h.app.fileState.text).toContain("1. one\n2. inserted\n3. two")
    await h.dispose()
  }, 30000)

  /// One logical line, several visual lines: the paragraph is longer than the 84-column
  /// reading measure, so the editor word-wraps it. Arrow keys must move by what the user
  /// sees — a wrapped line below is "down", not the next block.
  const WRAPPED =
    "The **quick** brown fox jumps over the lazy dog again and again and again, " +
    "running well past the column limit so this single markdown paragraph occupies " +
    "several visual lines on the screen once the editor wraps it."

  test("down from a wrapped paragraph's first visual line stays inside the block", async () => {
    const h = await open(`${WRAPPED}\n\ntail paragraph\n`)
    await h.frame()
    // Enter reveals the first block with the cursor at its start.
    h.keys.pressEnter()
    let frame = await h.frame()
    expect(trim(frame)).toContain("**quick**")

    h.keys.pressArrow("down")
    await h.keys.typeText("XX")
    frame = await h.frame()

    // Still editing the wrapped paragraph — its raw markers are on screen and the typed
    // text landed inside it, not at the head of the block below.
    expect(trim(frame)).toContain("**quick**")
    expect(h.app.fileState.text).not.toContain("XXtail")
    expect(h.app.fileState.text.indexOf("XX")).toBeLessThan(h.app.fileState.text.indexOf("tail"))
    await h.dispose()
  }, 30000)

  test("up from a wrapped paragraph's last visual line stays inside the block", async () => {
    const h = await open(`head paragraph\n\n${WRAPPED}\n`)
    let frame = await h.frame()
    await h.mouse.click(colOf(frame, "The quick") + 1, rowOf(frame, "The quick"))
    // END puts the cursor at the end of the single logical line — the LAST visual line.
    h.keys.pressKey("END")
    h.keys.pressArrow("up")
    await h.keys.typeText("YY")
    frame = await h.frame()

    expect(trim(frame)).toContain("**quick**")
    expect(h.app.fileState.text).not.toContain("head paragraphYY")
    await h.dispose()
  }, 30000)

  test("undo reverts typing inside a revealed block", async () => {
    const h = await open("# Title\n\nProse.\n")
    const frame = await h.frame()
    await h.mouse.click(colOf(frame, "Prose.") + 6, rowOf(frame, "Prose."))
    await h.keys.typeText("XYZ")
    expect(h.app.fileState.text).toContain("Prose.XYZ")
    h.keys.pressKey("z", { ctrl: true })
    await h.frame()
    expect(h.app.fileState.text).not.toContain("XYZ")
    await h.dispose()
  }, 30000)
})

describe("one field", () => {
  /// The document should edit like a single textarea over its source, not a grid of boxes:
  /// arrows cross block boundaries in every direction, and backspace/⌦ reach across them.
  test("→ at a block's end crosses into the next, ← at the start crosses back", async () => {
    const h = await open("first\n\nsecond\n")
    const frame = await h.frame()
    await h.mouse.click(colOf(frame, "first"), rowOf(frame, "first"))
    h.keys.pressKey("END")
    h.keys.pressArrow("right")
    await h.keys.typeText("A")
    await h.frame()
    expect(h.app.fileState.text).toContain("Asecond")

    h.keys.pressKey("HOME")
    h.keys.pressArrow("left")
    await h.keys.typeText("B")
    await h.frame()
    expect(h.app.fileState.text).toContain("firstB")
    await h.dispose()
  }, 30000)

  test("backspace at a block's start eats the separator one newline per press", async () => {
    const h = await open("first para\n\nsecond para\n")
    const frame = await h.frame()
    await h.mouse.click(colOf(frame, "second"), rowOf(frame, "second"))
    h.keys.pressKey("HOME")
    // One press, one newline — exactly what the key would do in one big textarea. The blank
    // line thins to a soft break, and the blocks are now one.
    h.keys.pressBackspace()
    await h.frame()
    expect(h.app.fileState.text).toBe("first para\nsecond para\n")

    // The caret rode the join: the next press is an ordinary in-block backspace on the
    // remaining newline, and typing lands between the joined words.
    h.keys.pressBackspace()
    await h.keys.typeText("X")
    await h.frame()
    expect(h.app.fileState.text).toBe("first paraXsecond para\n")
    await h.dispose()
  }, 30000)

  test("⌦ at a block's end joins downward the same way", async () => {
    const h = await open("first para\n\nsecond para\n")
    const frame = await h.frame()
    await h.mouse.click(colOf(frame, "first"), rowOf(frame, "first"))
    h.keys.pressKey("END")
    h.keys.pressKey("DELETE")
    await h.frame()
    expect(h.app.fileState.text).toBe("first para\nsecond para\n")
    await h.dispose()
  }, 30000)

  test("backspace at the very first block's start stays put", async () => {
    const h = await open("only para\n")
    const frame = await h.frame()
    await h.mouse.click(colOf(frame, "only"), rowOf(frame, "only"))
    h.keys.pressKey("HOME")
    h.keys.pressBackspace()
    await h.frame()
    expect(h.app.fileState.text).toBe("only para\n")
    await h.dispose()
  }, 30000)

  test("deleting a block's whole text leaves one separator, not a crater", async () => {
    const h = await open("first para\n\nsecond para\n\nthird para\n")
    const frame = await h.frame()
    await h.mouse.click(colOf(frame, "second"), rowOf(frame, "second"))
    h.keys.pressKey("a", { ctrl: true })
    h.keys.pressBackspace()
    h.keys.pressEscape()
    await h.frame()
    // Not "first para\n\n\n\nthird para\n": the deleted block's own trailing newlines went
    // with it, so the neighbours sit a single blank line apart, as they started.
    expect(h.app.fileState.text).toBe("first para\n\nthird para\n")
    await h.dispose()
  }, 30000)

  test("↓ across a block boundary keeps the caret's column", async () => {
    const h = await open("abcdef\n\nuvwxyz\n")
    const frame = await h.frame()
    await h.mouse.click(colOf(frame, "abcdef") + 3, rowOf(frame, "abcdef"))
    await h.frame()
    h.keys.pressArrow("down")
    await h.keys.typeText("Q")
    await h.frame()
    expect(h.app.fileState.text).toContain("uvwQxyz")
    await h.dispose()
  }, 30000)

  test("↑ across a block boundary keeps the caret's column too", async () => {
    const h = await open("abcdef\n\nuvwxyz\n")
    const frame = await h.frame()
    await h.mouse.click(colOf(frame, "uvwxyz") + 4, rowOf(frame, "uvwxyz"))
    await h.frame()
    h.keys.pressArrow("up")
    // The goal column lands once the fresh editor has laid out its wrap.
    await h.frame()
    await h.keys.typeText("Q")
    await h.frame()
    expect(h.app.fileState.text).toContain("abcdQef")
    await h.dispose()
  }, 30000)

  test("↓ on the document's last line parks at the end of the text", async () => {
    const h = await open("only para\n")
    const frame = await h.frame()
    await h.mouse.click(colOf(frame, "only"), rowOf(frame, "only"))
    await h.frame()
    h.keys.pressArrow("down")
    await h.keys.typeText("E")
    await h.frame()
    expect(h.app.fileState.text).toBe("only paraE\n")
    await h.dispose()
  }, 30000)
})

describe("empty documents", () => {
  /// `synth newfile.md`: a zero-byte file must still be a document someone can type into —
  /// no block to click and nothing for Enter to reveal was a dead end.
  test("Enter on an empty file opens an editor, and typing fills the file", async () => {
    const h = await open("")
    await h.frame()
    h.keys.pressEnter()
    await h.keys.typeText("hello world")
    h.keys.pressEscape()
    const frame = trim(await h.frame())

    expect(frame).toContain("hello world")
    expect(h.app.fileState.text.startsWith("hello world")).toBe(true)
    await h.dispose()
  }, 30000)

  test("clicking into an empty file also opens the editor", async () => {
    const h = await open("")
    await h.frame()
    // The lone blank block sits at the top of the column; it renders no text, so the click
    // aims at coordinates rather than at a needle in the frame.
    await h.mouse.click(10, 0)
    await h.keys.typeText("clicked into being")
    h.keys.pressEscape()
    const frame = trim(await h.frame())

    expect(frame).toContain("clicked into being")
    expect(h.app.fileState.text).toContain("clicked into being")
    await h.dispose()
  }, 30000)

  test("typing into a whitespace-only file keeps its trailing newlines", async () => {
    const h = await open("\n\n")
    await h.frame()
    h.keys.pressEnter()
    await h.keys.typeText("hello")
    h.keys.pressEscape()
    await h.frame()

    // The blank run was the revealed block's own trailing suffix; folding back must
    // re-append it verbatim rather than normalising the writer's blank lines away.
    expect(h.app.fileState.text).toBe("hello\n\n")
    await h.dispose()
  }, 30000)

  test("a longer blank run behaves the same", async () => {
    const h = await open("\n\n\n")
    await h.frame()
    h.keys.pressEnter()
    await h.keys.typeText("hi")
    h.keys.pressEscape()
    await h.frame()

    expect(h.app.fileState.text).toBe("hi\n\n\n")
    await h.dispose()
  }, 30000)
})

describe("checkbox toggle", () => {
  test("clicking the box toggles it without revealing the block", async () => {
    const h = await open("# Tasks\n\n- [ ] cut the branch\n- [x] write the spike\n")
    let frame = await h.frame()

    await h.mouse.click(colOf(frame, "□ cut"), rowOf(frame, "□ cut"))
    frame = await h.frame()

    expect(h.app.fileState.text).toContain("- [x] cut the branch")
    expect(trim(frame)).toContain("■ cut the branch")
    // The killer part of the interaction: the row did NOT flip to raw under the click.
    expect(trim(frame)).not.toContain("- [x] cut the branch")

    // And back.
    await h.mouse.click(colOf(frame, "■ cut"), rowOf(frame, "■ cut"))
    frame = await h.frame()
    expect(h.app.fileState.text).toContain("- [ ] cut the branch")
    expect(trim(frame)).toContain("□ cut the branch")

    await h.dispose()
  }, 30000)

  test("toggling one item leaves its siblings byte-identical", async () => {
    const h = await open("- [ ] one\n- [ ] two\n- [ ] three\n")
    const frame = await h.frame()
    await h.mouse.click(colOf(frame, "□ two"), rowOf(frame, "□ two"))
    await h.frame()
    expect(h.app.fileState.text).toBe("- [ ] one\n- [x] two\n- [ ] three\n")
    await h.dispose()
  }, 30000)

  test("clicking a plain bullet reveals the block instead of toggling anything", async () => {
    const h = await open("- plain bullet\n")
    let frame = await h.frame()
    await h.mouse.click(colOf(frame, "• plain"), rowOf(frame, "• plain"))
    frame = await h.frame()
    expect(trim(frame)).toContain("- plain bullet")
    await h.dispose()
  }, 30000)
})

describe("autosave", () => {
  test("writes debounced, and the bytes are exactly the buffer", async () => {
    const h = await open("# Title\n\nProse.\n")
    const frame = await h.frame()
    await h.mouse.click(colOf(frame, "Prose.") + 6, rowOf(frame, "Prose."))
    await h.keys.typeText("!")

    // Still the original on disk: the debounce has not elapsed.
    expect(await h.onDisk()).toBe("# Title\n\nProse.\n")

    await h.settleSave()
    expect(await h.onDisk()).toBe(h.app.fileState.text)
    expect(await h.onDisk()).toBe("# Title\n\nProse.!\n")
    await h.dispose()
  }, 30000)

  test("a burst of typing is one document, not one write per key", async () => {
    const h = await open("para\n")
    const frame = await h.frame()
    await h.mouse.click(colOf(frame, "para") + 4, rowOf(frame, "para"))
    await h.keys.typeText("abcdefgh")
    await h.settleSave()
    expect(await h.onDisk()).toBe("paraabcdefgh\n")
    await h.dispose()
  }, 30000)

  test("⌘S flushes the typed text without folding the editor", async () => {
    const h = await open("# Title\n\nSome **bold** prose.\n")
    const frame = await h.frame()
    await h.mouse.click(colOf(frame, "Some bold prose.") + 2, rowOf(frame, "Some bold prose."))
    await h.frame()
    await h.keys.typeText("XX")
    h.keys.pressKey("s", { ctrl: true })
    const after = trim(await h.frame())

    // The block is still revealed — a habitual mid-typing ⌘S must not close the editor.
    expect(after).toContain("**bold**")
    expect(after).toContain("editing")
    // And the save needed no commit: the document text is live-synced per keystroke.
    expect(await h.onDisk()).toContain("XX")
    await h.dispose()
  }, 30000)

  test("closing flushes an in-flight edit rather than losing it", async () => {
    const h = await open("para\n")
    const frame = await h.frame()
    await h.mouse.click(colOf(frame, "para") + 4, rowOf(frame, "para"))
    await h.keys.typeText("!")
    // No settle: dispose must be what writes it.
    await h.app.dispose()
    expect(await h.onDisk()).toBe("para!\n")
    await h.dispose()
  }, 30000)
})

describe("external change", () => {
  test("a clean buffer adopts the file and re-renders", async () => {
    const h = await open("# Before\n\nOld prose.\n")
    expect(trim(await h.frame())).toContain("Old prose.")

    await h.writeExternally("# After\n\nNew prose from an agent.\n")
    const frame = trim(await h.frame())

    expect(frame).toContain("After")
    expect(frame).toContain("New prose from an agent.")
    expect(frame).not.toContain("Old prose.")
    await h.dispose()
  }, 30000)

  test("a dirty buffer keeps the local edit and says so", async () => {
    const h = await open("# Doc\n\nMine.\n")
    const frame = await h.frame()
    await h.mouse.click(colOf(frame, "Mine.") + 5, rowOf(frame, "Mine."))
    await h.keys.typeText(" edited")

    await h.writeExternally("# Doc\n\nTheirs.\n")
    const after = trim(await h.frame())

    // The keystrokes survive, and the conflict is surfaced rather than silently resolved.
    expect(h.app.fileState.text).toContain("Mine. edited")
    expect(after).not.toContain("Theirs.")
    expect(after).toContain("changed on disk")
    await h.dispose()
  }, 30000)

  test("a conflicted buffer stops autosaving until it is resolved", async () => {
    const h = await open("# Doc\n\nMine.\n")
    const frame = await h.frame()
    await h.mouse.click(colOf(frame, "Mine.") + 5, rowOf(frame, "Mine."))
    await h.keys.typeText(" edited")
    await h.writeExternally("# Doc\n\nTheirs.\n")

    await h.settleSave()
    // The agent's write is still there: autosave did not silently overwrite it.
    expect(await h.onDisk()).toBe("# Doc\n\nTheirs.\n")

    // An explicit save is the user choosing their side, and it goes through.
    h.keys.pressKey("s", { ctrl: true })
    await h.settleSave()
    expect(await h.onDisk()).toContain("Mine. edited")
    await h.dispose()
  }, 30000)

  test("a reload under an open editor returns cleanly to reading", async () => {
    const h = await open("# Doc\n\nMine here.\n")
    const frame = await h.frame()
    await h.mouse.click(colOf(frame, "Mine here.") + 2, rowOf(frame, "Mine here."))
    expect(trim(await h.frame())).toContain("editing")

    // The buffer is clean — revealing is not an edit — so the external write is adopted and
    // the reload destroys the open editor. The reveal bookkeeping must go with it, or the
    // status keeps claiming "editing" while keystrokes fall into the gap between modes.
    await h.writeExternally("# Doc\n\nTheirs now.\n")
    let after = trim(await h.frame())
    expect(after).not.toContain("editing")
    expect(after).toContain("click to edit")

    // And the app is really back in reading mode: keys scroll rather than vanish.
    h.keys.pressArrow("down")
    after = trim(await h.frame())
    expect(after).toContain("Theirs now.")
    await h.dispose()
  }, 30000)

  test("⌃R resolves a conflict by taking the disk version", async () => {
    const h = await open("# Doc\n\nMine.\n")
    const frame = await h.frame()
    await h.mouse.click(colOf(frame, "Mine.") + 5, rowOf(frame, "Mine."))
    await h.keys.typeText(" edited")
    await h.writeExternally("# Doc\n\nTheirs.\n")
    // The status line offers both halves of the choice.
    expect(trim(await h.frame())).toContain("⌃R takes disk")

    h.keys.pressKey("r", { ctrl: true })
    const after = trim(await h.frame())
    expect(after).toContain("Theirs.")
    expect(after).toContain("took the disk version")
    expect(after).not.toContain("changed on disk")
    expect(h.app.fileState.text).toBe("# Doc\n\nTheirs.\n")
    expect(await h.onDisk()).toBe("# Doc\n\nTheirs.\n")
    await h.dispose()
  }, 30000)

  test("closing while conflicted keeps the disk bytes", async () => {
    const h = await open("# Doc\n\nMine.\n")
    const frame = await h.frame()
    await h.mouse.click(colOf(frame, "Mine.") + 5, rowOf(frame, "Mine."))
    await h.keys.typeText(" edited")
    await h.writeExternally("# Doc\n\nTheirs.\n")
    await h.frame()

    // Quitting is not choosing: the close flush must not land "Mine. edited" on top of the
    // agent's write. The disk keeps the agent's version; ⌃S was the way to keep yours.
    await h.app.dispose()
    expect(await h.onDisk()).toBe("# Doc\n\nTheirs.\n")
    await h.dispose()
  }, 30000)
})

describe("links", () => {
  test("⌃B returns to where the reading stopped, not to the top", async () => {
    const filler = Array.from({ length: 30 }, (_, i) => `filler line ${i}`).join("\n\n")
    const h = await open(`# A\n\n${filler}\n\n[onward](./b.md)\n`, { height: 20 })
    await writeFile(join(dirname(h.path), "b.md"), "# B\n\nthe other doc\n", "utf8")
    let frame = await h.frame()

    // Read to the bottom, open the link's block, follow it.
    h.keys.pressKey("END")
    frame = await h.frame()
    await h.mouse.click(colOf(frame, "onward") + 2, rowOf(frame, "onward"))
    await h.frame()
    h.keys.pressKey("]", { ctrl: true })
    frame = trim(await h.frame())
    expect(frame).toContain("the other doc")

    // Back lands where the cross-reference was followed from, pages below the title.
    h.keys.pressKey("b", { ctrl: true })
    frame = trim(await h.frame())
    expect(frame).toContain("filler line 29")
    expect(frame).not.toContain("filler line 0")
    await h.dispose()
  }, 30000)

  test("⌃] on a #fragment jumps to its heading", async () => {
    const filler = Array.from({ length: 30 }, (_, i) => `filler line ${i}`).join("\n\n")
    const h = await open(`[go](#deep-section)\n\n${filler}\n\n## Deep Section\n\nthe target paragraph\n`, {
      height: 20,
    })
    let frame = await h.frame()
    await h.mouse.click(colOf(frame, "go"), rowOf(frame, "go"))
    await h.frame()
    h.keys.pressKey("]", { ctrl: true })
    frame = trim(await h.frame())
    expect(frame).toContain("Deep Section")
    expect(frame).toContain("the target paragraph")
    await h.dispose()
  }, 30000)

  test("⌃] on a fragment with no such heading says so", async () => {
    const h = await open("[go](#nowhere)\n\n## Real Heading\n\nprose\n")
    let frame = await h.frame()
    await h.mouse.click(colOf(frame, "go"), rowOf(frame, "go"))
    await h.frame()
    h.keys.pressKey("]", { ctrl: true })
    frame = trim(await h.frame())
    expect(frame).toContain("no such heading")
    await h.dispose()
  }, 30000)

  test("a cross-document fragment lands on the heading, and the way back is taught", async () => {
    const filler = Array.from({ length: 30 }, (_, i) => `c filler ${i}`).join("\n\n")
    const h = await open("[go](./c.md#part-two)\n", { height: 20 })
    await writeFile(
      join(dirname(h.path), "c.md"),
      `# C Top\n\n${filler}\n\n## Part Two\n\nthe far paragraph\n`,
      "utf8",
    )
    let frame = await h.frame()
    await h.mouse.click(colOf(frame, "go"), rowOf(frame, "go"))
    await h.frame()
    h.keys.pressKey("]", { ctrl: true })
    frame = trim(await h.frame())
    // Landed on the fragment's section, pages past the title — with ⌃B advertised at the
    // exact moment it became useful.
    expect(frame).toContain("Part Two")
    expect(frame).toContain("the far paragraph")
    expect(frame).not.toContain("C Top")
    expect(frame).toContain("⌃B back")
    await h.dispose()
  }, 30000)

  test("the read-mode hint offers ⌃] only when the document has links", async () => {
    const linked = await open("see [the notes](./notes.md)\n")
    expect(trim(await linked.frame())).toContain("⌃] links")
    await linked.dispose()

    const plain = await open("no links here at all\n")
    expect(trim(await plain.frame())).not.toContain("⌃] links")
    await plain.dispose()
  }, 30000)

  test("⌃] from the plain reader teaches the two-step instead of scolding", async () => {
    const h = await open("see [the notes](./notes.md)\n")
    await h.frame()
    h.keys.pressKey("]", { ctrl: true })
    expect(trim(await h.frame())).toContain("then ⌃] opens it")
    await h.dispose()
  }, 30000)
})

describe("document undo", () => {
  test("⌃Z after a fold restores the pre-reveal text, and autosaves it", async () => {
    const h = await open("# T\n\nProse.\n")
    const frame = await h.frame()
    await h.mouse.click(colOf(frame, "Prose.") + 6, rowOf(frame, "Prose."))
    await h.keys.typeText(" more")
    h.keys.pressEscape()
    await h.frame()
    expect(h.app.fileState.text).toBe("# T\n\nProse. more\n")

    h.keys.pressKey("z", { ctrl: true })
    const after = trim(await h.frame())
    expect(h.app.fileState.text).toBe("# T\n\nProse.\n")
    expect(after).toContain("undid edit")

    // The restored text re-arms autosave like any edit: the undo reaches the disk.
    await h.settleSave()
    expect(await h.onDisk()).toBe("# T\n\nProse.\n")
    await h.dispose()
  }, 30000)

  test("⌃Y redoes what ⌃Z undid", async () => {
    const h = await open("para\n")
    const frame = await h.frame()
    await h.mouse.click(colOf(frame, "para") + 4, rowOf(frame, "para"))
    await h.keys.typeText("!")
    h.keys.pressEscape()
    await h.frame()

    h.keys.pressKey("z", { ctrl: true })
    await h.frame()
    expect(h.app.fileState.text).toBe("para\n")

    // ⌃⇧Z only exists under the kitty protocol — at the legacy byte level shift is not
    // encodable on a control character, which is exactly why ⌃Y is bound too. The harness
    // speaks legacy bytes, so redo is exercised through ⌃Y.
    h.keys.pressKey("y", { ctrl: true })
    expect(trim(await h.frame())).toContain("redid edit")
    expect(h.app.fileState.text).toBe("para!\n")

    // A fresh edit opens a new timeline: the redo branch dies.
    h.keys.pressKey("z", { ctrl: true })
    await h.frame()
    const frame2 = await h.frame()
    await h.mouse.click(colOf(frame2, "para") + 4, rowOf(frame2, "para"))
    await h.keys.typeText("?")
    h.keys.pressEscape()
    await h.frame()
    h.keys.pressKey("y", { ctrl: true })
    expect(trim(await h.frame())).toContain("nothing to redo")
    expect(h.app.fileState.text).toBe("para?\n")
    await h.dispose()
  }, 30000)

  test("sequential folds unwind newest-first", async () => {
    const h = await open("aaa\n\nbbb\n")
    let frame = await h.frame()
    await h.mouse.click(colOf(frame, "aaa") + 3, rowOf(frame, "aaa"))
    await h.keys.typeText("1")
    h.keys.pressEscape()
    frame = await h.frame()
    await h.mouse.click(colOf(frame, "bbb") + 3, rowOf(frame, "bbb"))
    await h.keys.typeText("2")
    h.keys.pressEscape()
    await h.frame()
    expect(h.app.fileState.text).toBe("aaa1\n\nbbb2\n")

    h.keys.pressKey("z", { ctrl: true })
    await h.frame()
    expect(h.app.fileState.text).toBe("aaa1\n\nbbb\n")
    h.keys.pressKey("z", { ctrl: true })
    await h.frame()
    expect(h.app.fileState.text).toBe("aaa\n\nbbb\n")
    await h.dispose()
  }, 30000)

  test("a checkbox toggle is one undo step", async () => {
    const h = await open("- [ ] task one\n")
    let frame = await h.frame()
    await h.mouse.click(colOf(frame, "□ task"), rowOf(frame, "□ task"))
    await h.frame()
    expect(h.app.fileState.text).toBe("- [x] task one\n")

    h.keys.pressKey("z", { ctrl: true })
    frame = trim(await h.frame())
    expect(h.app.fileState.text).toBe("- [ ] task one\n")
    expect(frame).toContain("□ task one")
    await h.dispose()
  }, 30000)

  test("⌃Z inside a fresh reveal crosses the fold — a join comes straight back", async () => {
    const h = await open("first para\n\nsecond para\n")
    const frame = await h.frame()
    await h.mouse.click(colOf(frame, "second"), rowOf(frame, "second"))
    h.keys.pressKey("HOME")
    h.keys.pressBackspace()
    await h.frame()
    expect(h.app.fileState.text).toBe("first para\nsecond para\n")

    // The re-revealed editor has no history of its own, so ⌃Z falls through the fold to the
    // document stack and un-joins.
    h.keys.pressKey("z", { ctrl: true })
    const after = trim(await h.frame())
    expect(h.app.fileState.text).toBe("first para\n\nsecond para\n")
    expect(after).toContain("undid edit")
    await h.dispose()
  }, 30000)

  test("the editor's own history exhausts into the document stack", async () => {
    const h = await open("- [ ] task\n\npara text\n")
    let frame = await h.frame()
    await h.mouse.click(colOf(frame, "□ task"), rowOf(frame, "□ task"))
    frame = await h.frame()
    expect(h.app.fileState.text).toContain("- [x] task")

    await h.mouse.click(colOf(frame, "para text") + 9, rowOf(frame, "para text"))
    await h.keys.typeText("X")
    await h.frame()
    expect(h.app.fileState.text).toContain("para textX")

    // First ⌃Z: the editor's own step — the X goes, the block stays open.
    h.keys.pressKey("z", { ctrl: true })
    frame = trim(await h.frame())
    expect(h.app.fileState.text).toContain("para text\n")
    expect(frame).toContain("editing")

    // Second ⌃Z: nothing left in the editor, so the timeline continues through the fold and
    // undoes the toggle that came before the reveal.
    h.keys.pressKey("z", { ctrl: true })
    frame = trim(await h.frame())
    expect(h.app.fileState.text).toBe("- [ ] task\n\npara text\n")
    expect(frame).toContain("undid edit")
    await h.dispose()
  }, 30000)

  test("byte-neutral search stepping leaves no history", async () => {
    const h = await open("alpha one\n\nalpha two\n")
    await h.frame()
    h.keys.pressKey("f", { ctrl: true })
    await h.keys.typeText("alpha")
    h.keys.pressEnter()
    await h.frame()
    h.keys.pressEscape()
    await h.frame()
    h.keys.pressEscape()
    await h.frame()

    h.keys.pressKey("z", { ctrl: true })
    expect(trim(await h.frame())).toContain("nothing to undo")
    expect(h.app.fileState.text).toBe("alpha one\n\nalpha two\n")
    await h.dispose()
  }, 30000)

  test("an external reload is an epoch: no undoing into the agent's text", async () => {
    const h = await open("# Doc\n\nMine.\n")
    const frame = await h.frame()
    await h.mouse.click(colOf(frame, "Mine.") + 5, rowOf(frame, "Mine."))
    await h.keys.typeText(" edited")
    h.keys.pressEscape()
    await h.settleSave()

    await h.writeExternally("# Doc\n\nAgent text.\n")
    await h.frame()
    h.keys.pressKey("z", { ctrl: true })
    expect(trim(await h.frame())).toContain("nothing to undo")
    expect(h.app.fileState.text).toBe("# Doc\n\nAgent text.\n")
    await h.dispose()
  }, 30000)

  test("navigation is an epoch: the stack belongs to a document", async () => {
    const h = await open("[go](./d.md)\n\nsome para\n")
    await writeFile(join(dirname(h.path), "d.md"), "# D\n\nother doc\n", "utf8")
    let frame = await h.frame()
    await h.mouse.click(colOf(frame, "some para") + 4, rowOf(frame, "some para"))
    await h.keys.typeText("X")
    h.keys.pressEscape()
    frame = await h.frame()

    await h.mouse.click(colOf(frame, "go"), rowOf(frame, "go"))
    await h.frame()
    h.keys.pressKey("]", { ctrl: true })
    frame = trim(await h.frame())
    expect(frame).toContain("other doc")

    h.keys.pressKey("z", { ctrl: true })
    expect(trim(await h.frame())).toContain("nothing to undo")
    expect(h.app.fileState.text).toBe("# D\n\nother doc\n")
    await h.dispose()
  }, 30000)

  test("the stack caps at 100 entries", async () => {
    const h = await open("- [ ] task\n")
    const frame = await h.frame()
    const x = colOf(frame, "□ task")
    const y = rowOf(frame, "□ task")
    for (let i = 0; i < 102; i++) await h.mouse.click(x, y)

    // The hundredth ⌃Z still finds history…
    for (let i = 0; i < 100; i++) h.keys.pressKey("z", { ctrl: true })
    expect(trim(await h.frame())).toContain("undid edit")
    // …and the one after it finds the cap: the two oldest toggles fell off.
    h.keys.pressKey("z", { ctrl: true })
    expect(trim(await h.frame())).toContain("nothing to undo")
    expect(h.app.fileState.text).toBe("- [ ] task\n")
    await h.dispose()
  }, 30000)
})

describe("chords while editing", () => {
  test("⌃B moves the caret instead of navigating away", async () => {
    const h = await open("plain **p**\n")
    let frame = await h.frame()
    await h.mouse.click(colOf(frame, "plain"), rowOf(frame, "plain"))
    h.keys.pressKey("END")
    // Emacs move-left: one column back from the end, and the block stays open.
    h.keys.pressKey("b", { ctrl: true })
    await h.keys.typeText("X")
    frame = trim(await h.frame())
    expect(h.app.fileState.text).toBe("plain **p*X*\n")
    expect(frame).toContain("editing")
    await h.dispose()
  }, 30000)

  test("⌃F moves the caret; Esc then ⌃F still reaches search", async () => {
    const h = await open("plain **p**\n")
    let frame = await h.frame()
    await h.mouse.click(colOf(frame, "plain"), rowOf(frame, "plain"))
    h.keys.pressKey("HOME")
    // Emacs move-right — the sibling of ⌃B, behaving alike.
    h.keys.pressKey("f", { ctrl: true })
    await h.keys.typeText("X")
    await h.frame()
    expect(h.app.fileState.text).toBe("pXlain **p**\n")

    // Search is one fold away, exactly as documented. (The settle between the two keys
    // matters: a bare ESC byte chased immediately by ^F reads as one meta-chord.)
    h.keys.pressEscape()
    await h.frame()
    h.keys.pressKey("f", { ctrl: true })
    frame = trim(await h.frame())
    expect(frame).toContain("⇧⏎ prev")
    await h.dispose()
  }, 30000)
})

describe("discoverability", () => {
  test("⌃C from the reader teaches the real exit", async () => {
    const h = await open("just prose\n")
    await h.frame()
    h.keys.pressKey("c", { ctrl: true })
    expect(trim(await h.frame())).toContain("⌃Q quits")
    await h.dispose()
  }, 30000)

  test("⌘↓ and ⌘↑ jump to the ends of the document", async () => {
    const paragraphs = Array.from({ length: 40 }, (_, i) => `paragraph ${i}`).join("\n\n")
    const h = await open(`${paragraphs}\n`, { height: 20 })
    let frame = await h.frame()
    expect(trim(frame)).toContain("paragraph 0")

    h.keys.pressArrow("down", { ctrl: true })
    frame = trim(await h.frame())
    expect(frame).toContain("paragraph 39")
    expect(frame).not.toContain("paragraph 0")

    h.keys.pressArrow("up", { ctrl: true })
    frame = trim(await h.frame())
    expect(frame).toContain("paragraph 0")
    await h.dispose()
  }, 30000)
})

describe("status flash", () => {
  test("a flash clears itself rather than lingering for the session", async () => {
    const h = await open("just prose, nothing else\n")
    await h.frame()
    h.keys.pressKey("o", { ctrl: true })
    expect(trim(await h.frame())).toContain("no headings")

    // Past the 2.5s self-clear.
    await Bun.sleep(3200)
    expect(trim(await h.frame())).not.toContain("no headings")
    await h.dispose()
  }, 30000)
})

describe("search", () => {
  test("finds matches, reports position, and steps through them", async () => {
    const h = await open("# Doc\n\nalpha one\n\nbeta\n\nalpha two\n\nalpha three\n")
    await h.frame()

    h.keys.pressKey("f", { ctrl: true })
    await h.keys.typeText("alpha")
    let frame = trim(await h.frame())
    expect(frame).toContain("1/3")

    h.keys.pressEnter()
    frame = trim(await h.frame())
    expect(frame).toContain("2/3")

    h.keys.pressEnter()
    expect(trim(await h.frame())).toContain("3/3")

    // Wraps rather than dead-ending.
    h.keys.pressEnter()
    expect(trim(await h.frame())).toContain("1/3")

    await h.dispose()
  }, 30000)

  test("says so when nothing matches", async () => {
    const h = await open("# Doc\n\nprose\n")
    await h.frame()
    h.keys.pressKey("f", { ctrl: true })
    await h.keys.typeText("zzzz")
    expect(trim(await h.frame())).toContain("no match")

    // "no match" belongs to the open search bar; closed, there is nothing to step through
    // and the message would read as a stuck indicator.
    h.keys.pressEscape()
    expect(trim(await h.frame())).not.toContain("no match")
    await h.dispose()
  }, 30000)

  test("matches linger after closing search, with the stepping keys named", async () => {
    const h = await open("# Doc\n\nalpha one\n\nalpha two\n")
    await h.frame()
    h.keys.pressKey("f", { ctrl: true })
    await h.keys.typeText("alpha")
    expect(trim(await h.frame())).toContain("1/2")

    h.keys.pressEscape()
    const frame = trim(await h.frame())
    // The count survives Esc so n/p keep stepping — and the keys that explain it ride along.
    expect(frame).toContain("n next")
    expect(frame).toContain("p prev")
    await h.dispose()
  }, 30000)

  test("escape closes search and restores the reading view", async () => {
    const h = await open("# Doc\n\nalpha\n")
    await h.frame()
    h.keys.pressKey("f", { ctrl: true })
    await h.keys.typeText("alpha")
    expect(trim(await h.frame())).toContain("1/1")
    h.keys.pressEscape()
    expect(trim(await h.frame())).toContain("⌃F find")
    await h.dispose()
  }, 30000)

  test("stepping reveals the match's block raw, while the bar keeps the keys", async () => {
    const h = await open("# Doc\n\nalpha **one**\n\nbeta\n\nalpha **two**\n")
    await h.frame()
    h.keys.pressKey("f", { ctrl: true })
    await h.keys.typeText("alpha")
    expect(trim(await h.frame())).toContain("1/2")

    // Stepping opens the match's block as raw — the one surface a highlight can actually
    // render on — without taking the keys away from the query input.
    h.keys.pressEnter()
    let frame = trim(await h.frame())
    expect(frame).toContain("2/2")
    expect(frame).toContain("alpha **two**")

    // The query input still owns typing: the keystroke extends the query, not the document.
    await h.keys.typeText("x")
    frame = trim(await h.frame())
    expect(frame).toContain("no match")
    expect(h.app.fileState.text).not.toContain("alphax")
    await h.dispose()
  }, 30000)

  test("n and p keep stepping over an open match, and Enter steps into it", async () => {
    const h = await open("# Doc\n\nalpha **one**\n\nalpha **two**\n")
    await h.frame()
    h.keys.pressKey("f", { ctrl: true })
    await h.keys.typeText("alpha")
    h.keys.pressEscape()
    expect(trim(await h.frame())).toContain("n next")

    // n reveals the next match's block — and stays a step, never a typed character, because
    // the revealed block is on screen without keyboard focus.
    h.keys.pressKey("n")
    let frame = trim(await h.frame())
    expect(frame).toContain("2/2")
    expect(frame).toContain("alpha **two**")
    expect(frame).toContain("⏎ edit")

    h.keys.pressKey("n")
    frame = trim(await h.frame())
    expect(frame).toContain("1/2")
    expect(frame).toContain("alpha **one**")
    expect(h.app.fileState.text).toBe("# Doc\n\nalpha **one**\n\nalpha **two**\n")

    // Enter enters the open block, with the caret already parked on the match.
    h.keys.pressEnter()
    await h.keys.typeText("X")
    await h.frame()
    expect(h.app.fileState.text).toContain("Xalpha **one**")
    await h.dispose()
  }, 30000)

  test("typing the query never scrolls the reader beneath the bar", async () => {
    const paragraphs = Array.from({ length: 30 }, (_, i) => `paragraph ${i}`).join("\n\n")
    const h = await open(`# Top\n\n${paragraphs}\n`, { height: 20 })
    await h.frame()
    h.keys.pressKey("f", { ctrl: true })
    // j and space are reader keys; inside the bar they are only ever query characters.
    await h.keys.typeText("j j")
    const frame = trim(await h.frame())
    expect(frame).toContain("Top")
    expect(frame).toContain("no match")
    await h.dispose()
  }, 30000)
})

describe("outline", () => {
  test("lists headings and jumps to the chosen one", async () => {
    const body = Array.from({ length: 25 }, (_, i) => `filler line ${i}`).join("\n\n")
    const h = await open(`# Top\n\n${body}\n\n## Deep Section\n\nthe target paragraph\n`, {
      height: 20,
    })
    await h.frame()

    h.keys.pressKey("o", { ctrl: true })
    let frame = trim(await h.frame())
    expect(frame).toContain("Top")
    expect(frame).toContain("Deep Section")
    expect(frame).toContain("⏎ jump")

    h.keys.pressArrow("down")
    h.keys.pressEnter()
    frame = trim(await h.frame())

    // The overlay is gone and the chosen heading is on screen.
    expect(frame).not.toContain("⏎ jump")
    expect(frame).toContain("Deep Section")
    await h.dispose()
  }, 30000)

  test("says so when the document has no headings", async () => {
    const h = await open("just prose, no headings at all\n")
    await h.frame()
    h.keys.pressKey("o", { ctrl: true })
    expect(trim(await h.frame())).toContain("no headings")
    await h.dispose()
  }, 30000)

  test("opens on the heading the reader is inside, not the first", async () => {
    const filler = Array.from({ length: 25 }, (_, i) => `alpha body ${i}`).join("\n\n")
    const tail = Array.from({ length: 20 }, (_, i) => `omega body ${i}`).join("\n\n")
    const h = await open(`# Alpha Head\n\n${filler}\n\n## Omega Head\n\n${tail}\n`, { height: 20 })
    await h.frame()

    // Read deep into the second section, then ask "where am I".
    h.keys.pressKey("END")
    await h.frame()
    h.keys.pressKey("o", { ctrl: true })
    // ⏎ with no arrow pressed: the selection already sits on the section being read.
    h.keys.pressEnter()
    const frame = trim(await h.frame())
    expect(frame).toContain("Omega Head")
    expect(frame).not.toContain("Alpha Head")
    await h.dispose()
  }, 30000)

  test("clicking an outline row jumps, the same as ⏎", async () => {
    const filler = Array.from({ length: 25 }, (_, i) => `alpha body ${i}`).join("\n\n")
    const h = await open(`# Alpha Head\n\n${filler}\n\n## Omega Head\n\ntail text\n`, { height: 20 })
    await h.frame()
    h.keys.pressKey("o", { ctrl: true })
    let frame = await h.frame()

    await h.mouse.click(colOf(frame, "Omega Head"), rowOf(frame, "Omega Head"))
    frame = trim(await h.frame())
    expect(frame).not.toContain("⏎ jump")
    expect(frame).toContain("tail text")
    await h.dispose()
  }, 30000)

  test("the selection window slides when the list outgrows the overlay", async () => {
    const doc = Array.from({ length: 30 }, (_, i) => `## H${i} heading\n\nbody ${i}\n`).join("\n")
    const h = await open(doc, { height: 16 })
    await h.frame()
    h.keys.pressKey("o", { ctrl: true })
    // The overlay window starts at the selection; the last heading is pages below it.
    let frame = trim(await h.frame())
    expect(frame).not.toContain("H29 heading")

    // ↑ wraps to the last heading — past the overlay's rows, so the window must follow the
    // selection or the picker goes blind.
    h.keys.pressArrow("up")
    frame = trim(await h.frame())
    expect(frame).toContain("H29 heading")

    // And back down to the top.
    h.keys.pressArrow("down")
    frame = trim(await h.frame())
    expect(frame).not.toContain("H29 heading")
    await h.dispose()
  }, 30000)
})

describe("overlay scrollbar", () => {
  /// A document tall enough to scroll in a 20-row window, and the thumb glyphs the overlay
  /// draws: slim right-half blocks at rest, full blocks under the pointer.
  const TALL = Array.from({ length: 40 }, (_, i) => `paragraph ${i}`).join("\n\n") + "\n"
  const SLIM = ["▐", "▗", "▝"]
  const WIDE = ["█", "▄", "▀"]
  const hasGlyph = (frame: string, glyphs: string[]) => glyphs.some((g) => frame.includes(g))

  test("appears on scroll, slims at rest, and folds away after the linger", async () => {
    const h = await open(TALL, { height: 20 })
    let frame = await h.frame()
    // At rest there is no bar at all — a still page is all page.
    expect(hasGlyph(frame, [...SLIM, ...WIDE])).toBe(false)

    h.keys.pressKey("j")
    frame = await h.frame()
    expect(hasGlyph(frame, SLIM)).toBe(true)

    // The linger elapses with no further movement and the bar folds away.
    await Bun.sleep(1100)
    frame = await h.frame()
    expect(hasGlyph(frame, [...SLIM, ...WIDE])).toBe(false)
    await h.dispose()
  }, 30000)

  test("widens under the pointer and drags the document with it", async () => {
    const h = await open(TALL, { height: 20, width: 90 })
    await h.frame()
    h.keys.pressKey("j")
    let frame = await h.frame()
    const barX = 89

    // Hovering the thumb widens it — the grab affordance.
    await h.mouse.moveTo(barX, 1)
    frame = await h.frame()
    expect(hasGlyph(frame, WIDE)).toBe(true)

    // Dragging it to the bottom takes the document to the end.
    await h.mouse.pressDown(barX, 1)
    await h.mouse.emitMouseEvent("drag", barX, 18)
    await h.mouse.release(barX, 18)
    frame = await h.frame()
    expect(trim(frame)).toContain("paragraph 39")
    await h.dispose()
  }, 30000)

  test("a drag the renderer never captured still ends, and the bar still hides", async () => {
    // Press the bar, then flick so fast the first drag report is already off the bar: capture
    // never engages, so no further event — drag, up, out — will ever reach the bar. The
    // liveness net must end the dead drag and let the linger fold the bar away, rather than
    // leaving it pinned on screen in a drag that can never finish.
    const h = await open(TALL, { height: 20, width: 90 })
    await h.frame()
    h.keys.pressKey("j")
    let frame = await h.frame()
    expect(hasGlyph(frame, SLIM)).toBe(true)

    await h.mouse.pressDown(89, 1)
    await h.mouse.emitMouseEvent("drag", 89, 25) // beyond the window in one report
    await h.mouse.release(89, 25)
    await h.mouse.moveTo(40, 10)

    // Liveness net (~600ms) plus linger (~900ms), with renders driven in between.
    await h.frame()
    await Bun.sleep(800)
    await h.frame()
    await Bun.sleep(1100)
    frame = await h.frame()
    expect(hasGlyph(frame, [...SLIM, ...WIDE])).toBe(false)
    await h.dispose()
  }, 30000)
})
