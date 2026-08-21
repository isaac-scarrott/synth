import { createTestRenderer, type TestRendererSetup } from "@opentui/core/testing"
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { App } from "../src/app"
import { readTheme } from "../src/theme"
import { AUTOSAVE_DELAY_MS } from "../src/save"

/// The snapshot harness: a real `App` on a real renderer, driven by real keystroke and mouse
/// bytes, over a real file on disk.
///
/// Headless rather than through a PTY, and that is the stronger test rather than a weaker
/// one. `createTestRenderer` feeds input through the same stdin parser a terminal would and
/// runs the same renderer and layout engine; what it omits is the tty device itself. In
/// exchange the frame is readable as text and the run is deterministic — a PTY suite asserting
/// on frames has to sleep for repaints and still races them. The tty half is covered where it
/// actually lives: `test/pty.test.ts` launches the built bundle under a real PTY, and the E2E
/// pass drives the shipped app.

/// Render until the frame stops changing, then return it.
///
/// The obvious tool — `waitForVisualIdle` — is wrong here, and wrong in a way that produced a
/// clean-looking empty frame: markdown text arrives from the tree-sitter worker one round-trip
/// AFTER layout, so between layout and highlight the frame is perfectly stable and perfectly
/// blank. "Nothing changed recently" and "nothing is still coming" are different questions.
/// So this drives real time forward and requires several identical consecutive captures.
async function settle(setup: TestRendererSetup): Promise<string> {
  await setup.flush()
  let previous = ""
  let stable = 0
  for (let i = 0; i < 120; i++) {
    await Bun.sleep(15)
    await setup.renderOnce()
    const frame = setup.captureCharFrame()
    stable = frame === previous ? stable + 1 : 0
    previous = frame
    // Three identical frames after at least ~100ms of real time: long enough for the worker
    // round-trip on a loaded machine, short enough that a settled document returns fast.
    if (stable >= 3 && i >= 6) break
  }
  return previous
}

export interface Harness {
  app: App
  path: string
  renderer: TestRendererSetup["renderer"]
  keys: TestRendererSetup["mockInput"]
  mouse: TestRendererSetup["mockMouse"]
  /// Settle the frame, then return it as text.
  frame(): Promise<string>
  /// ONE render pass, then the frame as it stands — no settling. This is how a test watches
  /// a transition instead of its end state: call it in a loop across a click or a reveal and
  /// every intermediate frame the user's eye would have seen passes through your hands.
  tick(ms?: number): Promise<string>
  /// The bytes currently on disk.
  onDisk(): Promise<string>
  /// Wait past the autosave debounce and let the write land.
  settleSave(): Promise<void>
  /// Rewrite the file from "another process", as an agent would.
  writeExternally(text: string): Promise<void>
  dispose(): Promise<void>
}

export async function open(
  content: string,
  options: { width?: number; height?: number; name?: string } = {},
): Promise<Harness> {
  const dir = await mkdtemp(join(tmpdir(), "synth-md-"))
  const path = join(dir, options.name ?? "doc.md")
  await writeFile(path, content, "utf8")
  // The reading width persists (column.ts), so a run that read the developer's own saved
  // choice would open at whatever measure they last used. Point the state at this test's
  // temp dir: every harness starts from the default and can assert what a ⌃W wrote.
  process.env.SYNTH_MD_STATE_DIR = dir

  const setup = await createTestRenderer({
    width: options.width ?? 90,
    height: options.height ?? 40,
    // The real renderer runs with this off (main.ts): ^C must never kill a document. The
    // test renderer's default would destroy itself under the very keypress the view answers
    // with "⌃Q quits".
    exitOnCtrlC: false,
  })

  const app = await App.start(setup.renderer, {
    path,
    theme: readTheme({ SYNTH_MD_APPEARANCE: "dark" } as NodeJS.ProcessEnv),
    // Never reach for the control socket in a test; record intent instead.
    openExternal: async (url) => {
      externalOpens.push(url)
      return true
    },
    onQuit: () => {
      quits++
    },
  })

  const externalOpens: string[] = []
  let quits = 0

  const harness: Harness = {
    app,
    path,
    renderer: setup.renderer,
    keys: setup.mockInput,
    mouse: setup.mockMouse,
    frame: () => settle(setup),
    async tick(ms = 8) {
      // A zero-ms tick is ONE raw render pass — no flush, no sleep. flush() renders to
      // visual idle, which lets deferred work catch up and repaints over the very
      // intermediate frame a transition test exists to sample.
      if (ms > 0) {
        await setup.flush()
        await Bun.sleep(ms)
      }
      await setup.renderOnce()
      return setup.captureCharFrame()
    },
    onDisk: () => readFile(path, "utf8"),
    async settleSave() {
      await Bun.sleep(AUTOSAVE_DELAY_MS + 120)
    },
    async writeExternally(text: string) {
      await writeFile(path, text, "utf8")
      // Give the fs watcher a beat to deliver; it is an OS event, not a promise we hold.
      await Bun.sleep(180)
      await setup.flush()
    },
    async dispose() {
      await app.dispose()
      setup.renderer.destroy()
      await rm(dir, { recursive: true, force: true })
    },
  }
  Object.defineProperty(harness, "externalOpens", { get: () => externalOpens })
  Object.defineProperty(harness, "quits", { get: () => quits })
  return harness
}

/// Frame text with trailing blanks stripped, so an assertion reads like the screen rather
/// than like 90-column padding.
export function trim(frame: string): string {
  return frame
    .split("\n")
    .map((line) => line.replace(/\s+$/, ""))
    .join("\n")
    .replace(/\n+$/, "")
}

/// The 1-based screen row a piece of text appears on, or -1. Mouse coordinates are screen
/// cells, so tests that click something have to find it first.
export function rowOf(frame: string, needle: string): number {
  return frame.split("\n").findIndex((line) => line.includes(needle))
}

export function colOf(frame: string, needle: string): number {
  const row = rowOf(frame, needle)
  if (row < 0) return -1
  return frame.split("\n")[row].indexOf(needle)
}
