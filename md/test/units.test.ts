import { expect, test, describe } from "bun:test"
import { mkdtemp, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { splitFrontmatter } from "../src/frontmatter"
import { find, matchesWithin, step } from "../src/search"
import { anchorSlug, History, resolveLink } from "../src/links"
import { readTheme } from "../src/theme"

describe("frontmatter", () => {
  test("splits a block and keeps the body offset exact", () => {
    const source = "---\ntitle: Doc\nowner: isaac\n---\n# Body\n"
    const { front, body } = splitFrontmatter(source)
    expect(front!.entries).toEqual([
      { key: "title", value: "Doc" },
      { key: "owner", value: "isaac" },
    ])
    expect(body).toBe("# Body\n")
    // The offset is what keeps every downstream block range an index into the real file.
    expect(source.slice(front!.bodyStart)).toBe(body)
    expect(front!.raw + body).toBe(source)
  })

  test("leaves a document with no frontmatter untouched", () => {
    const source = "# Just a doc\n"
    expect(splitFrontmatter(source)).toEqual({ front: null, body: source })
  })

  test("does not treat a leading horizontal rule as frontmatter", () => {
    // An unterminated opening fence is a thematic break, not a header.
    const source = "---\n\nbody with no closing fence\n"
    expect(splitFrontmatter(source).front).toBeNull()
  })

  test("keeps list and quoted values as written rather than parsing them", () => {
    const { front } = splitFrontmatter("---\ntags: [a, b]\ntitle: \"Quoted\"\n---\nbody\n")
    expect(front!.entries).toEqual([
      { key: "tags", value: "[a, b]" },
      { key: "title", value: '"Quoted"' },
    ])
  })

  test("ignores comments and blank lines", () => {
    const { front } = splitFrontmatter("---\n# a comment\n\nkey: value\n---\nbody\n")
    expect(front!.entries).toEqual([{ key: "key", value: "value" }])
  })
})

describe("search", () => {
  const doc = "Alpha beta alpha BETA alpha"

  test("is case-insensitive for a lowercase query", () => {
    expect(find(doc, "alpha").offsets).toEqual([0, 11, 22])
  })

  test("is case-sensitive once the query has a capital", () => {
    expect(find(doc, "Alpha").offsets).toEqual([0])
    expect(find(doc, "BETA").offsets).toEqual([17])
  })

  test("counts overlapping matches from each start", () => {
    expect(find("aaa", "aa").offsets).toEqual([0, 1])
  })

  test("opens on the first match at or after the caret", () => {
    expect(find(doc, "alpha", 11).current).toBe(1)
    expect(find(doc, "alpha", 12).current).toBe(2)
    // Past the last match, it wraps to the top rather than reporting nothing.
    expect(find(doc, "alpha", 99).current).toBe(0)
  })

  test("steps and wraps in both directions", () => {
    let m = find(doc, "alpha")
    expect(m.current).toBe(0)
    m = step(m, -1)
    expect(m.current).toBe(2)
    m = step(m, 1)
    expect(m.current).toBe(0)
  })

  test("reports an empty query as no matches", () => {
    expect(find(doc, "").offsets).toEqual([])
    expect(find(doc, "").current).toBe(-1)
  })

  test("rebases matches into a block's own coordinates", () => {
    const m = find(doc, "alpha")
    expect(matchesWithin(m, 11, 27)).toEqual([
      { start: 0, end: 5, current: false },
      { start: 11, end: 16, current: false },
    ])
  })
})

describe("resolveLink", () => {
  test("navigates to a relative markdown sibling that exists", async () => {
    const dir = await mkdtemp(join(tmpdir(), "synth-md-links-"))
    const from = join(dir, "index.md")
    const sibling = join(dir, "notes.md")
    await writeFile(from, "", "utf8")
    await writeFile(sibling, "", "utf8")

    expect(resolveLink("./notes.md", from)).toEqual({ kind: "document", path: sibling })
    // A fragment rides along, so the caller can finish the jump after the load.
    expect(resolveLink("notes.md#section", from)).toEqual({
      kind: "document",
      path: sibling,
      fragment: "section",
    })
    expect(resolveLink(`file://${sibling}`, from)).toEqual({ kind: "document", path: sibling })
    expect(resolveLink(`file://${sibling}#part-two`, from)).toEqual({
      kind: "document",
      path: sibling,
      fragment: "part-two",
    })
  })

  test("hands a markdown link that does not exist to the app, which explains itself", async () => {
    const dir = await mkdtemp(join(tmpdir(), "synth-md-links-"))
    const from = join(dir, "index.md")
    await writeFile(from, "", "utf8")
    const target = resolveLink("./missing.md", from)
    expect(target.kind).toBe("external")
  })

  test("hands every web scheme to the app rather than deciding routing itself", () => {
    for (const href of [
      "https://example.com",
      "http://localhost:3000",
      "mailto:someone@example.com",
    ]) {
      expect(resolveLink(href, "/tmp/doc.md")).toEqual({ kind: "external", url: href })
    }
  })

  test("hands a non-markdown relative file to the app as a file URL", () => {
    const target = resolveLink("./diagram.png", "/tmp/doc.md")
    expect(target).toEqual({ kind: "external", url: "file:///tmp/diagram.png" })
  })

  test("treats a bare fragment as staying in this document", () => {
    expect(resolveLink("#section", "/tmp/doc.md")).toEqual({
      kind: "document",
      path: "/tmp/doc.md",
      fragment: "section",
    })
  })
})

describe("anchorSlug", () => {
  test("mints GitHub-style anchors from heading text", () => {
    expect(anchorSlug("Deep Section")).toBe("deep-section")
    expect(anchorSlug("What's New?")).toBe("whats-new")
    // Both sides of the comparison go through the slug, so a GitHub-minted double-hyphen
    // anchor and the heading it names meet in the middle.
    expect(anchorSlug("v2.0 — the_plan")).toBe("v20-the_plan")
    expect(anchorSlug("v20--the_plan")).toBe("v20-the_plan")
    expect(anchorSlug("deep-section")).toBe("deep-section")
  })
})

describe("History", () => {
  test("pops in reverse order and reports when it is empty", () => {
    const h = new History()
    expect(h.canGoBack).toBe(false)
    expect(h.pop()).toBeNull()

    h.push("/a.md", 0)
    h.push("/b.md", 12)
    expect(h.canGoBack).toBe(true)
    expect(h.pop()).toEqual({ path: "/b.md", scroll: 12 })
    expect(h.pop()).toEqual({ path: "/a.md", scroll: 0 })
    expect(h.canGoBack).toBe(false)
  })
})

describe("theme", () => {
  test("defaults to dark and supplies a full palette with no env at all", () => {
    const theme = readTheme({} as NodeJS.ProcessEnv)
    expect(theme.appearance).toBe("dark")
    expect(theme.palette.fg).toMatch(/^#/)
    expect(theme.matchStyleId).toBeGreaterThanOrEqual(0)
  })

  test("takes the appearance and overrides the app sends", () => {
    const theme = readTheme({
      SYNTH_MD_APPEARANCE: "light",
      SYNTH_MD_PALETTE: JSON.stringify({ accent: "#123456" }),
    } as NodeJS.ProcessEnv)
    expect(theme.appearance).toBe("light")
    expect(theme.palette.accent).toBe("#123456")
    // Unspecified keys keep the light defaults rather than becoming undefined.
    expect(theme.palette.fg).toBe("#1C1E23")
  })

  test("falls back to defaults rather than failing on a corrupt or hostile blob", () => {
    for (const blob of ["not json", '{"fg": 42}', '{"__proto__": "x"}', "[]"]) {
      const theme = readTheme({ SYNTH_MD_PALETTE: blob } as NodeJS.ProcessEnv)
      expect(theme.palette.fg).toBe("#E6E8ED")
    }
  })
})
