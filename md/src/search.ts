/// In-document incremental search: match offsets over the source, plus a cursor into them.
///
/// Matching runs over the SOURCE, not the rendered text, and that is a deliberate trade. It
/// means a search for "bold" finds the word inside `**bold**` (good) and a search for "**"
/// finds markup the reader can't see (acceptable). Matching rendered text instead would need
/// a rendered-to-source offset map per block, and would still fail the moment a block is
/// revealed and the raw is what's on screen.

export interface Matches {
  query: string
  /// Source offsets where a match starts; always ascending.
  offsets: number[]
  /// Index into `offsets` of the highlighted match, or -1 when there are none.
  current: number
}

export const NO_MATCHES: Matches = { query: "", offsets: [], current: -1 }

/// Case-insensitive unless the query contains an uppercase letter — the "smart case" rule
/// every editor's search uses, which lets a lowercase query stay broad without a modifier.
export function find(source: string, query: string, near = 0): Matches {
  if (query === "") return NO_MATCHES
  const sensitive = /[A-Z]/.test(query)
  const haystack = sensitive ? source : source.toLowerCase()
  const needle = sensitive ? query : query.toLowerCase()

  const offsets: number[] = []
  let at = haystack.indexOf(needle)
  while (at !== -1) {
    offsets.push(at)
    // Overlapping matches are counted once each from their own start ("aa" in "aaa" is two).
    at = haystack.indexOf(needle, at + 1)
  }
  if (offsets.length === 0) return { query, offsets, current: -1 }

  // Open on the first match at or after the caret, so ctrl+F picks up from where the reader
  // is looking rather than sending them back to the top of the document.
  const forward = offsets.findIndex((o) => o >= near)
  return { query, offsets, current: forward === -1 ? 0 : forward }
}

/// Step to the next/previous match, wrapping. Wrapping rather than stopping is what makes
/// the two keys enough on their own: there is no "no more matches" state to explain.
export function step(matches: Matches, dir: 1 | -1): Matches {
  if (matches.offsets.length === 0) return matches
  const n = matches.offsets.length
  return { ...matches, current: (matches.current + dir + n) % n }
}

export function currentOffset(matches: Matches): number | null {
  if (matches.current < 0 || matches.current >= matches.offsets.length) return null
  return matches.offsets[matches.current]
}

/// Match ranges falling inside `[start, end)`, rebased to be relative to `start` — the shape
/// a single block needs to highlight its own text without knowing where it sits in the file.
export function matchesWithin(
  matches: Matches,
  start: number,
  end: number,
): { start: number; end: number; current: boolean }[] {
  const width = matches.query.length
  if (width === 0) return []
  const out: { start: number; end: number; current: boolean }[] = []
  for (let i = 0; i < matches.offsets.length; i++) {
    const at = matches.offsets[i]
    if (at >= start && at < end) {
      out.push({ start: at - start, end: Math.min(at + width, end) - start, current: i === matches.current })
    }
  }
  return out
}
