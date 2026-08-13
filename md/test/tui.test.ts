import { expect, test, describe } from "bun:test"
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
