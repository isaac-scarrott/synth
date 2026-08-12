// First, and before anything that reaches @opentui/core: it tells the library where its
// native dylib and tree-sitter assets live in a bundle that has no node_modules.
import "./asset-root"
import { createCliRenderer } from "@opentui/core"
import { resolve } from "node:path"
import { App } from "./app"

/// The process entry point: `synth-md <file.md>`.
///
/// Everything interesting is in `app.ts`, which the snapshot suite drives directly against a
/// test renderer. This file owns only the things a real process has and a test does not — argv,
/// the terminal, and exiting.

const target = process.argv[2]
if (!target) {
  process.stderr.write("usage: synth-md <file.md>\n")
  process.exit(2)
}

const renderer = await createCliRenderer({
  targetFps: 60,
  useMouse: true,
  enableMouseMovement: false,
  exitOnCtrlC: false,
  // The document IS the screen: the alternate screen keeps the reader's scrollback intact
  // underneath, so quitting a doc opened over a working shell puts them back where they were.
  screenMode: "alternate-screen",
  // Ghostty's card is already painting Synth's translucent surface. Anything opaque here
  // would be a second coat over it (see theme.ts).
  backgroundColor: "transparent",
})

const app = await App.start(renderer, {
  path: resolve(target),
  onQuit: () => {
    void app.dispose().finally(() => {
      renderer.destroy()
      process.exit(0)
    })
  },
})

// A terminal that goes away mid-edit still owes the writer their keystrokes.
for (const signal of ["SIGINT", "SIGTERM", "SIGHUP"] as const) {
  process.on(signal, () => {
    void app.dispose().finally(() => process.exit(0))
  })
}
