/// Print the measured contrast of every rendered span, worst first — the human-readable
/// companion to contrast.test.ts, for when a colour needs choosing rather than checking.
import { createTestRenderer } from "@opentui/core/testing"
import type { CapturedSpan, RGBA } from "@opentui/core"
import { mkdtemp, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { App } from "./src/app"
import { readTheme } from "./src/theme"

const SURFACE = { dark: [0x12, 0x13, 0x17], light: [0xf7, 0xf8, 0xfa] } as const
const ch = (c: number) => (c / 255 <= 0.03928 ? c / 255 / 12.92 : ((c / 255 + 0.055) / 1.055) ** 2.4)
const L = (r: number[]) => 0.2126 * ch(r[0]) + 0.7152 * ch(r[1]) + 0.0722 * ch(r[2])
const C = (a: number[], b: number[]) => {
  const [hi, lo] = [L(a), L(b)].sort((x, y) => y - x)
  return (hi + 0.05) / (lo + 0.05)
}
const flat = (c: RGBA, u: readonly number[]) =>
  [c.r, c.g, c.b].map((v, i) => Math.round(v * 255 * c.a + u[i] * (1 - c.a)))

const DOC = await Bun.file(join(import.meta.dir, "test/fixtures/rich.md")).text()

for (const appearance of ["dark", "light"] as const) {
  const dir = await mkdtemp(join(tmpdir(), "synth-md-audit-"))
  const path = join(dir, "doc.md")
  await writeFile(path, DOC, "utf8")
  const s = await createTestRenderer({ width: 90, height: 44 })
  const app = await App.start(s.renderer, {
    path,
    theme: readTheme({ SYNTH_MD_APPEARANCE: appearance } as NodeJS.ProcessEnv),
    openExternal: async () => true,
    onQuit: () => {},
  })
  await s.flush()
  for (let i = 0; i < 40; i++) {
    await Bun.sleep(15)
    await s.renderOnce()
  }
  if (process.argv[2] === "--reveal") {
    const frame = s.captureCharFrame()
    const row = frame.split("\n").findIndex((l) => l.includes("Ship the viewer"))
    await s.mockMouse.click(frame.split("\n")[row].indexOf("Ship") + 2, row)
    for (let i = 0; i < 30; i++) {
      await Bun.sleep(15)
      await s.renderOnce()
    }
  }
  const rows: { text: string; ratio: number }[] = []
  for (const line of s.captureSpans().lines) {
    for (const span of line.spans as CapturedSpan[]) {
      if (span.text.trim() === "") continue
      const bg = flat(span.bg, SURFACE[appearance])
      rows.push({ text: span.text.trim().slice(0, 40), ratio: C(flat(span.fg, bg), bg) })
    }
  }
  rows.sort((a, b) => a.ratio - b.ratio)
  console.log(`\n=== ${appearance}${process.argv[2] === "--reveal" ? " (revealed)" : ""} ===`)
  for (const r of rows.slice(0, 12)) console.log(r.ratio.toFixed(2).padStart(6), r.text)
  await app.dispose()
  s.renderer.destroy()
}
process.exit(0)
