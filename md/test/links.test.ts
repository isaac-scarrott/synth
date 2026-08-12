import { expect, test, describe } from "bun:test"
import { writeFile } from "node:fs/promises"
import { dirname, join } from "node:path"
import { linkAt, linksIn } from "../src/links"
import { colOf, open, rowOf, trim } from "./harness"

describe("linksIn", () => {
  test("finds inline links, autolinks and bare URLs", () => {
    const raw = "See [the notes](./notes.md) and <https://example.org> and https://bare.example"
    expect(linksIn(raw).map((s) => s.href)).toEqual([
      "./notes.md",
      "https://example.org",
      "https://bare.example",
    ])
  })

  test("counts a bare URL inside an inline link only once", () => {
    expect(linksIn("[x](https://example.com)").map((s) => s.href)).toEqual(["https://example.com"])
  })

  test("ignores a link title", () => {
    expect(linksIn('[x](https://example.com "Title")')[0].href).toBe("https://example.com")
  })

  test("locates the link under an offset, and nothing outside one", () => {
    const raw = "before [text](./a.md) after"
    expect(linkAt(raw, raw.indexOf("text"))).toBe("./a.md")
    expect(linkAt(raw, raw.indexOf("./a.md"))).toBe("./a.md")
    expect(linkAt(raw, 0)).toBeNull()
    expect(linkAt(raw, raw.length - 1)).toBeNull()
  })
})

describe("following links", () => {
  test("a relative markdown link navigates in place, and back returns", async () => {
    const h = await open("# Index\n\nGo to [the notes](./notes.md).\n")
    await writeFile(join(dirname(h.path), "notes.md"), "# Notes\n\nThe notes body.\n", "utf8")

    let frame = await h.frame()
    await h.mouse.click(colOf(frame, "the notes") + 2, rowOf(frame, "the notes"))
    // Cursor is in the link text; ctrl+] follows it.
    h.keys.pressKey("]", { ctrl: true })
    await Bun.sleep(120)
    frame = trim(await h.frame())

    expect(frame).toContain("Notes")
    expect(frame).toContain("The notes body.")
    expect(h.app.currentPath).toEndWith("notes.md")

    // Back returns to the document that linked here.
    h.keys.pressKey("b", { ctrl: true })
    await Bun.sleep(120)
    frame = trim(await h.frame())
    expect(frame).toContain("Index")
    expect(h.app.currentPath).toEndWith("doc.md")

    await h.dispose()
  }, 30000)

  test("a web link is handed to the app rather than opened here", async () => {
    const h = await open("# Doc\n\nSee [example](https://example.com).\n")
    const frame = await h.frame()
    await h.mouse.click(colOf(frame, "example") + 2, rowOf(frame, "example"))
    h.keys.pressKey("]", { ctrl: true })
    await Bun.sleep(120)

    expect((h as any).externalOpens).toContain("https://example.com")
    // The viewer stayed put.
    expect(h.app.currentPath).toEndWith("doc.md")
    await h.dispose()
  }, 30000)

  test("says so when the cursor is not in a link", async () => {
    const h = await open("# Doc\n\nPlain prose with no link.\n")
    const frame = await h.frame()
    await h.mouse.click(colOf(frame, "Plain") + 2, rowOf(frame, "Plain"))
    h.keys.pressKey("]", { ctrl: true })
    expect(trim(await h.frame())).toContain("no link under the cursor")
    await h.dispose()
  }, 30000)

  test("back with nothing to go back to is a no-op, not an error", async () => {
    const h = await open("# Doc\n\nProse.\n")
    const before = await h.frame()
    h.keys.pressKey("b", { ctrl: true })
    await Bun.sleep(80)
    expect(await h.frame()).toBe(before)
    await h.dispose()
  }, 30000)
})
