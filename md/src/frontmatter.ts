/// YAML frontmatter, split off the document before it ever reaches the markdown lexer.
///
/// Splitting rather than parsing-in-place is what the locked "styled key/value header"
/// requires: to markdown, `---\ntitle: x\n---` is a thematic break followed by a paragraph
/// followed by another break, which is exactly what the spike rendered and exactly what the
/// reader should never see. The body is offset by `bodyStart` so every block offset in the
/// rest of the app stays an offset into the ORIGINAL file — nothing downstream has to know
/// frontmatter existed, and bytes written back are the bytes read.

export interface Frontmatter {
  /// Ordered key/value pairs as written. Values stay strings; this is a header to display,
  /// not a config to interpret, so `[a, b]` renders as typed rather than becoming an array.
  entries: { key: string; value: string }[]
  /// Offset in the original source where the body begins.
  bodyStart: number
  /// The raw frontmatter block including both fences, for byte-exact round-tripping.
  raw: string
}

const FENCE = /^---[ \t]*\r?\n/

export function splitFrontmatter(source: string): { front: Frontmatter | null; body: string } {
  if (!FENCE.test(source)) return { front: null, body: source }

  const open = source.indexOf("\n") + 1
  // The closing fence must start a line, and `---` alone on it.
  const close = /^---[ \t]*(\r?\n|$)/m
  const rest = source.slice(open)
  const m = close.exec(rest)
  if (!m) return { front: null, body: source }

  const inner = rest.slice(0, m.index)
  const bodyStart = open + m.index + m[0].length
  return {
    front: {
      entries: parseEntries(inner),
      bodyStart,
      raw: source.slice(0, bodyStart),
    },
    body: source.slice(bodyStart),
  }
}

/// Flat `key: value` pairs only. Nested YAML is shown as its raw line under the parent key
/// rather than being modelled — the header exists so the reader can see what the file claims
/// about itself, and a partial parse that renders honestly beats a full one that can fail.
function parseEntries(inner: string): { key: string; value: string }[] {
  const entries: { key: string; value: string }[] = []
  for (const line of inner.split("\n")) {
    if (line.trim() === "" || line.trimStart().startsWith("#")) continue
    const m = /^([A-Za-z0-9_.\-]+)\s*:\s*(.*)$/.exec(line)
    if (m) {
      entries.push({ key: m[1], value: m[2].trim() })
    } else if (entries.length > 0) {
      const last = entries[entries.length - 1]
      last.value = last.value ? `${last.value} ${line.trim()}` : line.trim()
    }
  }
  return entries
}
