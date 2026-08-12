import { expect, test, describe, beforeAll } from "bun:test"
import { mkdtemp, readFile, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { dirname, join } from "node:path"

/// The built payload, under a real PTY.
///
/// This is the half `tui.test.ts` deliberately leaves out. That suite drives the app object on
/// a test renderer, which is faster and lets frames be read as text — but it never exercises
/// the SHIPPED artefact: that the vendored Bun starts, that the bundle finds its native dylib
/// and tree-sitter assets with no `node_modules` anywhere on disk, that a tty is negotiated,
/// and that keystrokes arriving as bytes down a pty reach the document and land in the file.
///
/// Assertions are on the raw byte stream rather than a reconstructed frame. Rebuilding the
/// grid would mean writing a terminal emulator, and stripping escapes naively reorders the
/// output enough to read a correctly-rendered document as a broken one — it did, and cost an
/// hour. What matters here is unambiguous either way: source markers must be ABSENT from the
/// stream (concealment ran) and rendered glyphs must be PRESENT.

const ROOT = dirname(dirname(Bun.fileURLToPath(import.meta.url)))
const BUNDLE = join(ROOT, "dist/synth-md.js")
const RUNTIME = join(ROOT, "dist/bun/aarch64/bun")
const DRIVER = join(ROOT, "test/pty-driver.py")

type Step = { wait: number } | { send: string }

/// Run the built TUI on a real pty and return everything it drew.
async function runInPty(path: string, steps: Step[]): Promise<string> {
  const script: Step[] = [
    // Let it paint before anything else: the first frame waits on a tree-sitter round-trip.
    { wait: 1500 },
    ...steps,
    // ctrl+Q is the TUI's own quit, which flushes a pending autosave on the way out.
    { send: "\x11" },
    { wait: 800 },
  ]
  const proc = Bun.spawn(["python3", DRIVER, JSON.stringify(script), "--", RUNTIME, BUNDLE, path], {
    stdout: "pipe",
    stderr: "pipe",
    env: { ...process.env, SYNTH_MD_APPEARANCE: "dark" },
  })
  const [stdout, stderr] = await Promise.all([
    new Response(proc.stdout).text(),
    new Response(proc.stderr).text(),
  ])
  await proc.exited
  if (stderr.trim()) throw new Error(`pty driver failed: ${stderr}`)
  return stdout
}

async function fixture(content: string) {
  const dir = await mkdtemp(join(tmpdir(), "synth-md-pty-"))
  const path = join(dir, "doc.md")
  await writeFile(path, content, "utf8")
  return path
}

describe("the built payload under a real pty", () => {
  beforeAll(async () => {
    if (!(await Bun.file(BUNDLE).exists())) {
      throw new Error(`missing ${BUNDLE} — run \`bun run build\` first`)
    }
  })

  test("starts from the vendored runtime with no node_modules, and renders", async () => {
    const path = await fixture(
      "# Release plan\n\nShip the **viewer** today.\n\n- alpha\n- [ ] cut the branch\n",
    )
    const out = await runInPty(path, [{ wait: 2500 }])

    // Rendered text is present…
    for (const shown of ["Release plan", "viewer", "alpha", "cut the branch"]) {
      expect(out).toContain(shown)
    }
    // …and its source markers are not, which is the whole claim: markdown was rendered by the
    // shipped bundle, not echoed.
    for (const marker of ["**viewer**", "# Release plan", "- [ ]", "- alpha"]) {
      expect(out).not.toContain(marker)
    }
    // The view's own glyphs, drawn from the block model rather than by the markdown renderer.
    expect(out).toContain("•")
    expect(out).toContain("□")
  }, 60000)

  test("loads its native library and tree-sitter assets from the staged asset root", async () => {
    const path = await fixture("# Doc\n\n```ts\nconst version: number = 1\n```\n")
    const out = await runInPty(path, [{ wait: 2500 }])

    // A highlighted fence proves the whole chain resolved: libopentui.dylib for the renderer,
    // tree-sitter.wasm and the typescript grammar for the highlight, and parser.worker.js for
    // the worker that asks for them. Any one missing and this is blank.
    expect(out).toContain("const version: number = 1")
    expect(out).not.toContain("```")
    expect(out).not.toContain("Worker initialization timed out")
    expect(out).not.toContain("Cannot find module")
  }, 60000)

  test("takes typed bytes down the pty and autosaves them to the file", async () => {
    const path = await fixture("# Doc\n\nProse.\n")
    await runInPty(path, [
      { send: "\r" },        // Enter opens the first block for editing
      { wait: 400 },
      { send: "\x1b[F" },    // End — to the end of the line
      { wait: 200 },
      { send: " edited in a pty" },
      { wait: 900 },         // past the autosave debounce
    ])

    expect(await readFile(path, "utf8")).toContain("edited in a pty")
  }, 60000)

  test("enters and leaves the alternate screen, so the host shell keeps its scrollback", async () => {
    const path = await fixture("# Doc\n\nProse.\n")
    const out = await runInPty(path, [{ wait: 800 }])
    expect(out).toContain("\x1b[?1049h")
    expect(out).toContain("\x1b[?1049l")
  }, 60000)
})
