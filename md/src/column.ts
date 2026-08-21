import { mkdirSync, readFileSync, writeFileSync } from "node:fs"
import { homedir } from "node:os"
import { join } from "node:path"

/// How wide the reading column is allowed to grow — the reader's choice, stepped with ⌃W,
/// rather than one number baked into the layout.
///
/// A measure is a trade nobody wins for everybody: past ~80 columns the eye loses the start
/// of the next line, but a document read in a wide pane beside code is often wanted
/// edge-to-edge, and a wide table or a fenced block is simply cut short by a narrow one. So
/// all three are on the ladder and the default sits in the middle.

export type ColumnSize = "small" | "medium" | "large"

export const COLUMN_SIZES = ["small", "medium", "large"] as const

/// `large` has no ceiling of its own: `relayout` already clamps every measure against the
/// terminal, so "no ceiling" arrives as "fill the pane, gutters aside".
export const COLUMN_CEILING: Record<ColumnSize, number> = {
  small: 80,
  medium: 96,
  large: Infinity,
}

export const DEFAULT_COLUMN_SIZE: ColumnSize = "medium"

export function nextColumnSize(size: ColumnSize): ColumnSize {
  const index = COLUMN_SIZES.indexOf(size)
  return COLUMN_SIZES[(index + 1) % COLUMN_SIZES.length]
}

/// Where the choice is remembered. The app hands the directory over in the launch env
/// (MarkdownSession.environment) so the stable and development channels keep their own, the
/// same way every other piece of Synth's state is channel-scoped; a `synth notes.md` typed in
/// a terminal Synth never launched falls back to the stable sandbox rather than forgetting.
function statePath(env: NodeJS.ProcessEnv): string {
  const dir = env.SYNTH_MD_STATE_DIR || join(homedir(), "Library", "Application Support", "Synth")
  return join(dir, "md-column")
}

/// A width the reader picked in one document is the width they want in the next one — the
/// alternative is re-pressing ⌃W on every open, which is exactly the papercut the key exists
/// to remove. An unreadable or unrecognised file is not an error worth a word on screen: the
/// default is a perfectly good answer.
export function readColumnSize(env: NodeJS.ProcessEnv = process.env): ColumnSize {
  try {
    const saved = readFileSync(statePath(env), "utf8").trim()
    if ((COLUMN_SIZES as readonly string[]).includes(saved)) return saved as ColumnSize
  } catch {
    // No file yet, or nothing readable there.
  }
  return DEFAULT_COLUMN_SIZE
}

export function writeColumnSize(size: ColumnSize, env: NodeJS.ProcessEnv = process.env): void {
  const path = statePath(env)
  try {
    mkdirSync(join(path, ".."), { recursive: true })
    writeFileSync(path, size + "\n", "utf8")
  } catch {
    // A width that fails to persist still applies to the document on screen; nothing about
    // the reading experience should stop for it.
  }
}
