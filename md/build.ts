import { getNodeAssets, type NodeAssetTarget } from "@opentui/core/node-assets"
import { mkdir, rm, cp, stat } from "node:fs/promises"
import { dirname, join, resolve } from "node:path"

/// Build the relocatable synth-md payload that ships inside Synth.app.
///
/// Three parts land in `dist/`:
///
///   synth-md.js        the whole TUI as one file (`bun build`)
///   assets/…           OpenTUI's runtime assets, keyed by the names it looks them up under
///   bun/<arch>/bun     the runtime, from vendor/ (fetch-bun.sh)
///
/// The assets directory is the load-bearing idea. OpenTUI normally finds its native dylib,
/// its tree-sitter grammars and its parser worker by resolving them inside `node_modules`,
/// which does not exist in a shipped .app. Setting `OTUI_ASSET_ROOT` to an absolute directory
/// makes it look them up by key instead — a supported, documented path, not a hack — so the
/// payload can live anywhere and be code-signed as ordinary resources.

const ROOT = dirname(Bun.fileURLToPath(import.meta.url))
const DIST = join(ROOT, "dist")

/// Synth ships arm64-only: app/vendor/fetch-cef.sh takes the macosarm64 CEF distro and
/// dist.sh's `swift build` is host-arch, so the app itself is already a single slice. The
/// layout stays per-arch keyed anyway — adding x64 is this list plus a fetch-bun.sh arch.
const TARGETS: NodeAssetTarget[] = [{ platform: "darwin", arch: "arm64" }]

/// Bun resolves every platform's native package when it bundles, including the ones this
/// machine will never have installed. They are marked external and never actually imported at
/// runtime, because `OTUI_ASSET_ROOT` is checked first and answers with the staged dylib.
const NATIVE_PACKAGES = [
  "darwin-arm64", "darwin-x64",
  "linux-x64", "linux-arm64", "linux-x64-musl", "linux-arm64-musl",
  "win32-x64", "win32-arm64",
].map((slug) => `@opentui/core-${slug}`)

async function main() {
  await rm(DIST, { recursive: true, force: true })
  await mkdir(DIST, { recursive: true })

  const built = await Bun.build({
    entrypoints: [join(ROOT, "src/main.ts")],
    outdir: DIST,
    target: "bun",
    external: NATIVE_PACKAGES,
    naming: { entry: "synth-md.js" },
    minify: false, // a shipped stack trace should still name a real line
  })
  if (!built.success) {
    for (const log of built.logs) console.error(log)
    throw new Error("bun build failed")
  }

  for (const target of TARGETS) {
    const root = join(DIST, "assets")
    for (const asset of getNodeAssets(target)) {
      const dest = join(root, asset.key)
      await mkdir(dirname(dest), { recursive: true })
      await Bun.write(dest, Bun.file(asset.source))
    }
  }

  for (const target of TARGETS) {
    const arch = target.arch === "arm64" ? "aarch64" : target.arch
    const source = join(ROOT, "vendor/bun", arch, "bun")
    if (!(await exists(source))) {
      throw new Error(`missing Bun runtime for ${arch} — run ./vendor/fetch-bun.sh`)
    }
    const dest = join(DIST, "bun", arch, "bun")
    await mkdir(dirname(dest), { recursive: true })
    await cp(source, dest)
  }

  // `bun build` also emits its own copy of every asset it saw imported, beside the bundle.
  // They are unreachable — `asset-root.ts` points OpenTUI at `assets/` before it looks
  // anything up — and leaving several megabytes of duplicate tree-sitter grammars loose in
  // the app's Resources would invite exactly one question from the next reader.
  for (const stray of new Bun.Glob("*.{wasm,scm}").scanSync({ cwd: DIST })) {
    await rm(join(DIST, stray))
  }
  for (const stray of new Bun.Glob("parser.worker-*.js").scanSync({ cwd: DIST })) {
    await rm(join(DIST, stray))
  }

  const bundle = await stat(join(DIST, "synth-md.js"))
  console.log(`synth-md.js  ${(bundle.size / 1024).toFixed(0)} KB`)
  console.log(`dist/        ${resolve(DIST)}`)
}

async function exists(path: string) {
  return await Bun.file(path)
    .exists()
    .catch(() => false)
}

await main()
