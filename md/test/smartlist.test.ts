import { expect, test, describe } from "bun:test"
import { continueList, indentItem, renumber, renumberPreservingCursor } from "../src/smartlist"
import { segment } from "../src/blocks"

/// Cursor position is half the behaviour, so the fixtures mark it with `|` and the helper
/// strips it — an assertion that reads like the thing the user sees.
function at(marked: string) {
  const cursor = marked.indexOf("|")
  return { source: marked.replace("|", ""), cursor }
}
function show(edit: { source: string; cursor: number } | null) {
  if (!edit) return null
  return edit.source.slice(0, edit.cursor) + "|" + edit.source.slice(edit.cursor)
}

describe("continueList", () => {
  test("continues a bullet list", () => {
    const { source, cursor } = at("- alpha|\n")
    expect(show(continueList(source, cursor))).toBe("- alpha\n- |\n")
  })

  test("continues an ordered list, incrementing", () => {
    const { source, cursor } = at("1. first|\n")
    expect(show(continueList(source, cursor))).toBe("1. first\n2. |\n")
  })

  test("keeps the delimiter style", () => {
    const { source, cursor } = at("3) third|\n")
    expect(show(continueList(source, cursor))).toBe("3) third\n4) |\n")
  })

  test("keeps indentation for a nested item", () => {
    const { source, cursor } = at("- a\n  - nested|\n")
    expect(show(continueList(source, cursor))).toBe("- a\n  - nested\n  - |\n")
  })

  test("carries the checkbox but never the checked state", () => {
    const { source, cursor } = at("- [x] done|\n")
    expect(show(continueList(source, cursor))).toBe("- [x] done\n- [ ] |\n")
  })

  test("outdents an empty nested item instead of continuing", () => {
    const { source, cursor } = at("- a\n  - |\n")
    expect(show(continueList(source, cursor))).toBe("- a\n- |\n")
  })

  test("breaks out of the list from an empty top-level item", () => {
    const { source, cursor } = at("- a\n- |\n")
    expect(show(continueList(source, cursor))).toBe("- a\n|\n")
  })

  test("declines mid-content, so Enter splits the line normally", () => {
    const { source, cursor } = at("- al|pha\n")
    expect(continueList(source, cursor)).toBeNull()
  })

  test("declines outside a list", () => {
    const { source, cursor } = at("just prose|\n")
    expect(continueList(source, cursor)).toBeNull()
  })
})

describe("indentItem", () => {
  test("indents an item under its predecessor", () => {
    const { source, cursor } = at("- a\n- b|\n")
    expect(show(indentItem(source, cursor, 1))).toBe("- a\n  - b|\n")
  })

  test("refuses to indent the first item of a list", () => {
    const { source, cursor } = at("- a|\n- b\n")
    expect(indentItem(source, cursor, 1)).toBeNull()
  })

  test("refuses to indent past one level below the predecessor", () => {
    const { source, cursor } = at("- a\n  - b|\n")
    expect(indentItem(source, cursor, 1)).toBeNull()
  })

  test("outdents a nested item", () => {
    const { source, cursor } = at("- a\n  - b|\n")
    expect(show(indentItem(source, cursor, -1))).toBe("- a\n- b|\n")
  })

  test("refuses to outdent a top-level item", () => {
    const { source, cursor } = at("- a|\n")
    expect(indentItem(source, cursor, -1)).toBeNull()
  })

  test("declines outside a list", () => {
    const { source, cursor } = at("prose|\n")
    expect(indentItem(source, cursor, 1)).toBeNull()
  })

  test("indenting produces a block one nesting step deeper", () => {
    const { source, cursor } = at("- a\n- b|\n")
    const next = indentItem(source, cursor, 1)!
    const items = segment(next.source).filter((b) => b.kind === "list-item")
    expect(items.map((b) => b.listDepth)).toEqual([0, 1])
  })
})

describe("renumber", () => {
  test("fixes a list the writer left out of order", () => {
    expect(renumber("1. a\n2. b\n2. c\n5. d\n")).toBe("1. a\n2. b\n3. c\n4. d\n")
  })

  test("honours the first item as the list's start", () => {
    expect(renumber("3. a\n9. b\n1. c\n")).toBe("3. a\n4. b\n5. c\n")
  })

  test("numbers each nesting depth independently", () => {
    expect(renumber("1. a\n  1. x\n  7. y\n9. b\n")).toBe("1. a\n  1. x\n  2. y\n2. b\n")
  })

  test("restarts after a blank line, which ends the list", () => {
    expect(renumber("1. a\n2. b\n\n7. new list\n8. x\n")).toBe("1. a\n2. b\n\n7. new list\n8. x\n")
  })

  test("leaves bullets alone", () => {
    expect(renumber("- a\n- b\n")).toBe("- a\n- b\n")
  })

  test("preserves checkboxes and content", () => {
    expect(renumber("1. [x] done\n5. [ ] todo\n")).toBe("1. [x] done\n2. [ ] todo\n")
  })

  test("never rewrites digits inside a fenced code block", () => {
    const src = "1. a\n\n```\n1. not a list\n7. still not\n```\n\n1. b\n2. c\n"
    expect(renumber(src)).toBe(src)
  })
})

describe("renumberPreservingCursor", () => {
  test("keeps the cursor on the same character when marker width changes", () => {
    // "9." becomes "10.", so a naive offset would drift one column left.
    const source = "9. nine\n1. ten\n"
    const cursor = source.indexOf("ten") + 3
    const out = renumberPreservingCursor(source, cursor)
    expect(out.source).toBe("9. nine\n10. ten\n")
    expect(out.source.slice(0, out.cursor)).toEndWith("ten")
  })

  test("is a no-op for an already-correct list", () => {
    const source = "1. a\n2. b\n"
    expect(renumberPreservingCursor(source, 3)).toEqual({ source, cursor: 3 })
  })
})
