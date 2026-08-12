import { expect, test, describe } from "bun:test"
import { createTestRenderer } from "@opentui/core/testing"
import type { CapturedSpan, RGBA } from "@opentui/core"
import { mkdtemp, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { App } from "../src/app"
import { readTheme } from "../src/theme"

/// Every glyph the reader can see, measured against what is behind it, in both appearances.
///
/// This exists because a colour bug here is invisible to every other test in the suite: the
/// frame-text assertions read characters, not colours, so a block rendered as black ink on a
/// black field passes all of them while being literally unreadable. That is not hypothetical —
/// the code-span and revealed-block tints were written as low-alpha washes, and a terminal cell
/// has no backdrop to blend into, so they composited against nothing and landed on pure black.
///
/// The terminal surface underneath is Synth's card, not the void, so a cell painting no
/// background of its own is measured against that card's colour (TerminalTheme) rather than
/// against black.

const SURFACE = { dark: [0x12, 0x13, 0x17], light: [0xf7, 0xf8, 0xfa] } as const

const DOC = await Bun.file(join(import.meta.dir, "fixtures/rich.md")).text()

function channel(c: number): number {
  const s = c / 255
  return s <= 0.03928 ? s / 12.92 : ((s + 0.055) / 1.055) ** 2.4
}

function luminance(rgb: readonly number[]): number {
  return 0.2126 * channel(rgb[0]) + 0.7152 * channel(rgb[1]) + 0.0722 * channel(rgb[2])
}

function contrast(a: readonly number[], b: readonly number[]): number {
  const [hi, lo] = [luminance(a), luminance(b)].sort((x, y) => y - x)
  return (hi + 0.05) / (lo + 0.05)
}

/// RGBA arrives 0..1 per channel. Composite it over `under` using its own alpha — the step
/// that turns "a tint" into "the colour a human actually sees".
function flatten(c: RGBA, under: readonly number[]): number[] {
  return [c.r, c.g, c.b].map((v, i) => Math.round(v * 255 * c.a + under[i] * (1 - c.a)))
}

interface Measured {
  text: string
  ratio: number
  fg: number[]
  bg: number[]
}

/// Render the document, optionally click into a block, and measure every visible span.
async function measure(
  appearance: "light" | "dark",
  options: { reveal?: boolean } = {},
): Promise<Measured[]> {
  const dir = await mkdtemp(join(tmpdir(), "synth-md-contrast-"))
  const path = join(dir, "doc.md")
  await writeFile(path, DOC, "utf8")

  const setup = await createTestRenderer({ width: 90, height: 44 })
  const app = await App.start(setup.renderer, {
    path,
    theme: readTheme({ SYNTH_MD_APPEARANCE: appearance } as NodeJS.ProcessEnv),
    openExternal: async () => true,
    onQuit: () => {},
  })

  const settle = async () => {
    await setup.flush()
    for (let i = 0; i < 40; i++) {
      await Bun.sleep(15)
      await setup.renderOnce()
    }
  }
  await settle()

  if (options.reveal) {
    const lines = setup.captureCharFrame().split("\n")
    const row = lines.findIndex((l) => l.includes("Ship the viewer"))
    await setup.mockMouse.click(lines[row].indexOf("Ship") + 2, row)
    await settle()
  }

  const surface = SURFACE[appearance]
  const out: Measured[] = []
  for (const line of setup.captureSpans().lines) {
    for (const span of line.spans as CapturedSpan[]) {
      if (span.text.trim() === "") continue
      const bg = flatten(span.bg, surface)
      const fg = flatten(span.fg, bg)
      out.push({ text: span.text.trim(), ratio: contrast(fg, bg), fg, bg })
    }
  }
  await app.dispose()
  setup.renderer.destroy()
  return out
}

function report(spans: Measured[], floor: number): string {
  return spans
    .filter((s) => s.ratio < floor)
    .map((s) => `${JSON.stringify(s.text.slice(0, 40))} ${s.ratio.toFixed(2)}:1 fg=${s.fg} bg=${s.bg}`)
    .join("\n")
}

/// 4.5:1 is the body-text floor. Rules, table borders and the status hints are non-text or
/// decorative and take WCAG's 3:1 non-text threshold — but nothing is allowed to disappear,
/// which is what this suite is really guarding.
const BODY_FLOOR = 4.5
const NON_TEXT_FLOOR = 3

describe("contrast", () => {
  for (const appearance of ["dark", "light"] as const) {
    test(`${appearance}: nothing rendered falls below the non-text floor`, async () => {
      const spans = await measure(appearance)
      expect(spans.length).toBeGreaterThan(20)
      expect(report(spans, NON_TEXT_FLOOR)).toBe("")
    }, 60000)

    test(`${appearance}: the document's own words clear 4.5:1`, async () => {
      const spans = await measure(appearance)
      const body = spans.filter((s) =>
        /Release plan|Ship the|cut the branch|write the spike|plain bullet|quoted aside|version/.test(s.text),
      )
      expect(body.length).toBeGreaterThan(4)
      expect(report(body, BODY_FLOOR)).toBe("")
    }, 60000)

    test(`${appearance}: raw markdown under the cursor stays readable`, async () => {
      const spans = await measure(appearance, { reveal: true })
      // The reveal really happened — the source markers are on screen.
      expect(spans.some((s) => s.text.includes("**") || s.text.includes("]("))).toBe(true)
      expect(report(spans, NON_TEXT_FLOOR)).toBe("")

      const raw = spans.filter((s) => /Ship the|viewer|italic|inline code/.test(s.text))
      expect(raw.length).toBeGreaterThan(0)
      expect(report(raw, BODY_FLOOR)).toBe("")
    }, 60000)
  }
})
