import { connect } from "node:net"
import { existsSync } from "node:fs"
import { dirname, isAbsolute, resolve } from "node:path"

/// Where a clicked link goes.
///
/// Exactly two destinations, which is the locked split. A relative link to another markdown
/// file is *navigation* and stays inside the viewer, so following a doc's cross-references
/// never leaves the reader's place. Everything else — http, mailto, a PDF, an absolute path —
/// is handed back to the Synth app over the control socket, so the app's existing routing
/// applies unchanged: loopback pages to the synth browser, other web pages to the default
/// browser, files to `openFileLink`. Re-deciding any of that here would be a second copy of a
/// rule that already exists in Store.swift, free to drift.
///
/// With no socket (the `synth <file>` CLI running in a plain terminal outside the app) the
/// fallback is `open`, which is what that terminal would have done anyway.

export type LinkTarget =
  | { kind: "document"; path: string }
  | { kind: "external"; url: string }

const MARKDOWN = /\.(md|markdown|mdown|mkd)$/i

/// Resolve a link href as written in `fromPath`'s document.
export function resolveLink(href: string, fromPath: string): LinkTarget {
  const trimmed = href.trim()

  // A bare fragment is an in-document jump, not a link out. Treated as a document target
  // pointing at the current file so the caller re-enters the same doc rather than shelling out.
  if (trimmed.startsWith("#")) return { kind: "document", path: fromPath }

  if (/^[a-z][a-z0-9+.-]*:/i.test(trimmed)) {
    // `file:` URLs to markdown still navigate in-viewer — a doc that spells its sibling as a
    // full file URL means the same thing as one that spells it `./sibling.md`.
    if (trimmed.toLowerCase().startsWith("file://")) {
      const path = decodeURIComponent(trimmed.slice("file://".length).replace(/^[^/]*/, ""))
      if (MARKDOWN.test(path) && existsSync(path)) return { kind: "document", path }
    }
    return { kind: "external", url: trimmed }
  }

  const withoutFragment = trimmed.split("#")[0]
  if (withoutFragment === "") return { kind: "document", path: fromPath }

  const path = isAbsolute(withoutFragment)
    ? withoutFragment
    : resolve(dirname(fromPath), decodeURIComponent(withoutFragment))

  // Only an existing markdown file navigates. A relative link to a .png or to a doc that
  // isn't there yet goes to the app, which already knows how to open one and how to say so
  // when the other is missing.
  if (MARKDOWN.test(path) && existsSync(path)) return { kind: "document", path }
  return { kind: "external", url: pathToFileURL(path) }
}

function pathToFileURL(path: string): string {
  return "file://" + encodeURI(path).replace(/[?#]/g, (c) => "%" + c.charCodeAt(0).toString(16))
}

/// Inline link spans in a chunk of markdown source: `[text](href)`, `<autolink>`, and bare
/// URLs. Offsets are relative to `raw`.
///
/// Source spans rather than rendered ones, and that follows from what OpenTUI gives us. It
/// emits no OSC 8 hyperlinks, so neither ghostty nor Synth can route a click on rendered text
/// — there is nothing under the glyphs to route. What the reader clicks instead is the raw
/// `[text](href)` of a revealed block, where the href is visible and its offsets are exact.
export function linksIn(raw: string): { start: number; end: number; href: string }[] {
  const spans: { start: number; end: number; href: string }[] = []
  const inline = /\[([^\]]*)\]\(([^)\s]+)(?:\s+"[^"]*")?\)/g
  for (let m = inline.exec(raw); m; m = inline.exec(raw)) {
    spans.push({ start: m.index, end: m.index + m[0].length, href: m[2] })
  }
  const autolink = /<((?:https?|mailto|file):[^>\s]+)>/g
  for (let m = autolink.exec(raw); m; m = autolink.exec(raw)) {
    spans.push({ start: m.index, end: m.index + m[0].length, href: m[1] })
  }
  const bare = /(?<![("<\w])\b(https?:\/\/[^\s)<>\]]+)/g
  for (let m = bare.exec(raw); m; m = bare.exec(raw)) {
    // Skip anything already covered by a richer form, so `[x](http://y)` yields one span.
    if (spans.some((s) => m!.index >= s.start && m!.index < s.end)) continue
    spans.push({ start: m.index, end: m.index + m[0].length, href: m[1] })
  }
  return spans.sort((a, b) => a.start - b.start)
}

/// The href of the link containing `offset`, or null.
export function linkAt(raw: string, offset: number): string | null {
  for (const span of linksIn(raw)) {
    if (offset >= span.start && offset <= span.end) return span.href
  }
  return null
}

/// Hand a URL to the Synth app over its control socket (`SYNTH_CTL_SOCKET`, the path the
/// launch env carries). Resolves false when there is no app to talk to, so the caller can
/// fall back rather than swallow the click.
export function openViaSynth(url: string, socketPath = process.env.SYNTH_CTL_SOCKET): Promise<boolean> {
  if (!socketPath) return Promise.resolve(false)
  return new Promise((resolveDone) => {
    let settled = false
    const done = (ok: boolean) => {
      if (settled) return
      settled = true
      resolveDone(ok)
    }
    try {
      const socket = connect(socketPath)
      // A click must never hang the reader on an app that stopped answering.
      socket.setTimeout(1500, () => {
        socket.destroy()
        done(false)
      })
      socket.on("error", () => done(false))
      socket.on("connect", () => {
        // Name ourselves, so the app opens whatever this link becomes in the branch this
        // document is being read in rather than in whatever happens to be focused.
        socket.write(
          JSON.stringify({
            verb: "link.open",
            url,
            sessionId: process.env.SYNTH_SESSION_ID,
          }) + "\n",
        )
      })
      let buffer = ""
      socket.on("data", (chunk) => {
        buffer += chunk.toString()
        if (!buffer.includes("\n")) return
        try {
          done(JSON.parse(buffer.split("\n")[0]).ok === true)
        } catch {
          done(false)
        }
        socket.end()
      })
      socket.on("close", () => done(false))
    } catch {
      done(false)
    }
  })
}

/// A bounded back stack for in-viewer navigation. Back only, by design — the locked scope is
/// "a simple back stack and a back keystroke, no forward, no browser chrome", because a
/// reader following a cross-reference wants to get back to where they were reading, and
/// anything more is a browser growing inside a document.
export class History {
  private stack: { path: string; scroll: number }[] = []

  push(path: string, scroll: number) {
    this.stack.push({ path, scroll })
  }

  pop(): { path: string; scroll: number } | null {
    return this.stack.pop() ?? null
  }

  get canGoBack(): boolean {
    return this.stack.length > 0
  }

  get depth(): number {
    return this.stack.length
  }
}
