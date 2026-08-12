import { expect, test, describe } from "bun:test"
import { segment, blockAt, nextEditable, toggleTask, outline, splice } from "../src/blocks"

const RICH = `# Title

Some prose here.

- alpha
- beta
  - nested gamma
- [ ] todo one
- [x] done two

1. first
2. second

| a | b |
| - | - |
| 1 | 2 |

> quoted

\`\`\`ts
const x = 1
\`\`\`
`

/// Coverage is the invariant every other block operation rests on: the cursor is an offset,
/// and a hole in the segmentation is a cursor with nowhere to be.
function assertGapless(source: string) {
  const blocks = segment(source)
  expect(blocks[0].start).toBe(0)
  expect(blocks[blocks.length - 1].end).toBe(source.length)
  for (let i = 1; i < blocks.length; i++) {
    expect(blocks[i].start).toBe(blocks[i - 1].end)
  }
  for (const b of blocks) expect(source.slice(b.start, b.end)).toBe(b.raw)
  return blocks
}

describe("segment", () => {
  test("covers the source with no gaps or overlaps", () => {
    assertGapless(RICH)
  })

  test("covers awkward sources", () => {
    for (const s of ["", "\n", "no trailing newline", "\n\n\n", "# h", "- a", "text\n\n\n\n"]) {
      assertGapless(s)
    }
  })

  test("classifies each block kind", () => {
    const kinds = segment(RICH).filter((b) => b.kind !== "blank").map((b) => b.kind)
    expect(kinds).toEqual([
      "heading",
      "paragraph",
      "list-item", "list-item", "list-item", "list-item", "list-item",
      "list-item", "list-item",
      "table",
      "blockquote",
      "code",
    ])
  })

  test("splits list items individually, with depth and task state", () => {
    const items = segment(RICH).filter((b) => b.kind === "list-item")
    expect(items.map((b) => b.listDepth)).toEqual([0, 0, 1, 0, 0, 0, 0])
    expect(items.map((b) => b.checked)).toEqual([
      undefined, undefined, undefined, false, true, undefined, undefined,
    ])
    expect(items.map((b) => b.marker)).toEqual(["-", "-", "-", "-", "-", "1.", "2."])
  })

  test("records heading level and fence language", () => {
    const blocks = segment(RICH)
    expect(blocks.find((b) => b.kind === "heading")!.level).toBe(1)
    expect(blocks.find((b) => b.kind === "code")!.lang).toBe("ts")
  })

  test("treats a footnote definition as its own kind", () => {
    const blocks = segment("body\n\n[^1]: the note\n")
    expect(blocks.map((b) => b.kind).filter((k) => k !== "blank")).toEqual(["paragraph", "footnote"])
  })
})

describe("blockAt / nextEditable", () => {
  test("maps an offset to its containing block", () => {
    const blocks = segment(RICH)
    expect(blocks[blockAt(blocks, 0)].kind).toBe("heading")
    expect(blocks[blockAt(blocks, RICH.indexOf("Some prose"))].kind).toBe("paragraph")
    expect(blocks[blockAt(blocks, RICH.length)].kind).toBeDefined()
  })

  test("skips blank separators when stepping", () => {
    const blocks = segment("# a\n\npara\n")
    const heading = blockAt(blocks, 0)
    const next = nextEditable(blocks, heading + 1, 1)
    expect(blocks[next].kind).toBe("paragraph")
  })

  test("returns -1 when there is nothing further", () => {
    const blocks = segment("# a\n")
    expect(nextEditable(blocks, blocks.length, 1)).toBe(-1)
    expect(nextEditable(blocks, -1, -1)).toBe(-1)
  })
})

describe("toggleTask", () => {
  test("flips unchecked to checked and back, leaving the rest byte-identical", () => {
    const src = "- [ ] todo\n"
    const on = toggleTask(src, segment(src).find((b) => b.kind === "list-item")!)!
    expect(on).toBe("- [x] todo\n")
    const off = toggleTask(on, segment(on).find((b) => b.kind === "list-item")!)!
    expect(off).toBe(src)
  })

  test("preserves indentation and ordered markers", () => {
    const src = "  1. [ ] nested todo\n"
    expect(toggleTask(src, segment(src).find((b) => b.kind === "list-item")!)).toBe(
      "  1. [x] nested todo\n",
    )
  })

  test("is a no-op on a non-task block", () => {
    const src = "- plain\n"
    expect(toggleTask(src, segment(src).find((b) => b.kind === "list-item")!)).toBeNull()
    expect(toggleTask(src, segment("# h\n")[0])).toBeNull()
  })

  test("only touches the clicked item in a multi-item list", () => {
    const src = "- [ ] one\n- [ ] two\n- [ ] three\n"
    const items = segment(src).filter((b) => b.kind === "list-item")
    expect(toggleTask(src, items[1])).toBe("- [ ] one\n- [x] two\n- [ ] three\n")
  })
})

describe("outline", () => {
  // Indices are block indices, and a heading token absorbs the blank line after it while a
  // paragraph does not — so the gaps between these are not uniform.
  test("lists headings with level and clean text", () => {
    const blocks = segment("# One\n\n## Two ##\n\ntext\n\n### Three\n")
    expect(outline(blocks)).toEqual([
      { index: 0, level: 1, text: "One" },
      { index: 1, level: 2, text: "Two" },
      { index: 4, level: 3, text: "Three" },
    ])
  })
})

describe("splice", () => {
  test("replaces exactly the given range", () => {
    expect(splice("abcdef", 2, 4, "XY")).toBe("abXYef")
    expect(splice("abc", 3, 3, "!")).toBe("abc!")
  })
})
