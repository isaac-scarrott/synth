import { existsSync } from "node:fs"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"

/// Point OpenTUI at the staged asset directory that ships beside this bundle.
///
/// Imported for its side effect, and imported FIRST — before anything that pulls in
/// `@opentui/core` — because the native dylib, the tree-sitter grammars and the parser worker
/// are all resolved through `OTUI_ASSET_ROOT` the moment the library needs them.
///
/// Self-locating rather than set by the launcher: the shell shim, the app's session launch
/// command and `bun run src/main.ts` in a dev checkout would each have to know the layout and
/// keep knowing it. Deriving it from the bundle's own path means the payload can be copied
/// anywhere in Synth.app and still find its parts.
///
/// An explicit `OTUI_ASSET_ROOT` in the environment always wins, so a developer can point a
/// build at a different asset set without editing anything.
if (!process.env.OTUI_ASSET_ROOT) {
  const here = dirname(fileURLToPath(import.meta.url))
  // Beside the built bundle (dist/assets), or one level up from src/ in a dev checkout.
  for (const candidate of [join(here, "assets"), join(here, "..", "dist", "assets")]) {
    if (existsSync(candidate)) {
      process.env.OTUI_ASSET_ROOT = candidate
      break
    }
  }
}
