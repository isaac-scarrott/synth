import {
  destroyTreeSitterClient,
  getTreeSitterClient,
  type CliRenderer,
  type TreeSitterClient,
} from "@opentui/core"
import { DocumentFile } from "./save"
import { History, openViaSynth, resolveLink } from "./links"
import { readTheme, type Theme } from "./theme"
import { DocumentView } from "./view"

/// Wires the three long-lived things together: the file (bytes + autosave + watcher), the
/// view (pixels + keys), and navigation (which file the view is showing). Kept apart from
/// `main.ts` so the whole app can be driven headlessly by the test renderer — the snapshot
/// suite constructs exactly this, with no PTY and no process.

export interface AppOptions {
  path: string
  theme?: Theme
  /// Injected by tests so a run never touches the real socket.
  openExternal?: (url: string) => Promise<boolean>
  onQuit?: () => void
}

/// The tree-sitter client, ready to highlight.
///
/// Awaited before the first paint rather than deferred: without a client MarkdownRenderable
/// draws no text at all, so "defer it off the first paint" would mean flashing an empty
/// document. It costs ~25ms, which is inside the speed budget.
///
/// The client is a process-wide singleton that `renderer.destroy()` tears down, so a second
/// document opened in the same process can be handed a dead one. That failure is silent in
/// the worst way: `initialize()` still resolves, and the client then answers every highlight
/// request with nothing, so the document renders BLANK rather than erroring. So readiness is
/// established positively — by asking it to highlight something and checking that it did —
/// and a client that fails the check is thrown away and replaced.
async function startTreeSitter(): Promise<TreeSitterClient> {
  for (let attempt = 0; attempt < 2; attempt++) {
    try {
      const client = getTreeSitterClient()
      await client.initialize()
      const probe = await client.highlightOnce("# h", "markdown")
      if (probe.highlights && probe.highlights.length > 0) return client
    } catch {
      // Fall through to the recycle below.
    }
    await destroyTreeSitterClient().catch(() => {})
  }
  // Two failures means something is wrong with the assets, not with our bookkeeping. Return a
  // client anyway: an unhighlighted document is a worse document, not a missing one, and
  // failing the open here would be the wrong trade.
  const client = getTreeSitterClient()
  await client.initialize().catch(() => {})
  return client
}

export class App {
  readonly view: DocumentView
  private file!: DocumentFile
  private history = new History()
  private path: string
  private openExternal: (url: string) => Promise<boolean>
  private onQuit: () => void

  private constructor(renderer: CliRenderer, theme: Theme, options: AppOptions, treeSitter: any) {
    this.path = options.path
    this.openExternal = options.openExternal ?? ((url) => openViaSynth(url))
    this.onQuit = options.onQuit ?? (() => process.exit(0))
    this.view = new DocumentView(renderer, theme, treeSitter, {
      onEdit: (source) => this.file.edit(source),
      onLink: (href) => void this.followLink(href),
      onSave: () => void this.file.flush(),
      onDiscard: () => void this.takeDisk(),
      onBack: () => void this.goBack(),
      onQuit: () => void this.quit(),
    })
  }

  static async start(renderer: CliRenderer, options: AppOptions): Promise<App> {
    const theme = options.theme ?? readTheme()
    const treeSitter = await startTreeSitter()

    const app = new App(renderer, theme, options, treeSitter)
    app.view.mount()

    // Ghostty announces the appearance to the program it runs (DEC 2031) and re-announces it
    // when Synth flips — which is what keeps a document open across a theme change from being
    // left in the other scheme's ink. Only when the app did not pin a theme (the tests do).
    if (!options.theme) {
      renderer.on("theme_mode", (mode) => {
        if (mode === "light" || mode === "dark") app.view.setTheme(readTheme(process.env, mode))
      })
    }

    await app.load(options.path)
    return app
  }

  private async load(path: string) {
    await this.file?.close()
    this.path = path
    this.file = await DocumentFile.open(path, {
      onExternalChange: (text) => {
        this.view.setSource(text, { preserveScroll: true })
        this.view.setFlags({ dirty: false, conflicted: false })
        // Epoch: the adopted text is the other writer's work; an undo reaching past this
        // moment would resurrect our old bytes over it (see DocumentView.clearHistory).
        this.view.clearHistory()
        this.view.flash("reloaded")
      },
      onConflict: () => {
        this.view.setFlags({ dirty: true, conflicted: true })
      },
      onSaved: () => {
        this.view.setFlags({ dirty: false, conflicted: false })
      },
      onError: (error) => this.view.flash(`save failed: ${String(error)}`),
    })
    this.view.setSource(this.file.state.text)
    this.view.setFlags({ dirty: false, conflicted: false })
    // Epoch: the stack belongs to a document. Without this, ⌃Z after following a link would
    // splice the PREVIOUS file's bytes into the one now on screen.
    this.view.clearHistory()
  }

  /// A relative markdown link navigates in place and pushes the current doc onto the back
  /// stack; everything else is the app's problem (see links.ts).
  private async followLink(href: string) {
    const target = resolveLink(href, this.path)
    if (target.kind === "document") {
      if (target.path === this.path) {
        // Same document: the only work is the fragment. Without one there is nowhere to go,
        // and silence would read as a broken key.
        if (target.fragment) this.view.jumpToFragment(target.fragment)
        else this.view.flash("already here")
        return
      }
      this.history.push(this.path, this.view.scrollTop)
      await this.load(target.path)
      // The way back is a chord nobody can guess; teach it at the exact moment it becomes
      // useful. A fragment jump's own failure flash ("no such heading") outranks it.
      this.view.flash("⌃B back")
      if (target.fragment) this.view.jumpToFragment(target.fragment)
      return
    }
    const opened = await this.openExternal(target.url)
    if (!opened) this.view.flash("could not open link")
  }

  /// Resolve a conflict in the DISK's favour: drop the local edits and adopt the file. The
  /// other half of the ⌃S/⌃R pair — save.ts holds the buffer still until one of them is
  /// pressed.
  private async takeDisk() {
    const text = await this.file.discard()
    this.view.setSource(text, { preserveScroll: true })
    this.view.setFlags({ dirty: false, conflicted: false })
    // Epoch, same as an external reload: the user just chose the disk's text — an undo that
    // popped their discarded edits back would unmake the choice a beat after it was made.
    this.view.clearHistory()
    this.view.flash("took the disk version")
  }

  private async goBack() {
    const previous = this.history.pop()
    if (!previous) return
    await this.load(previous.path)
    // The reason the stack exists is to get back to where the reading stopped, not merely to
    // which file it stopped in — landing at the top of a long document loses the place the
    // cross-reference was followed from.
    this.view.restoreScroll(previous.scroll)
  }

  private async quit() {
    // Flush before exit: an autosave debounce in flight must not be what loses the last
    // sentence someone typed.
    await this.file?.close()
    this.onQuit()
  }

  async dispose() {
    this.view.dispose()
    await this.file?.close()
  }

  get currentPath(): string {
    return this.path
  }

  get fileState() {
    return this.file.state
  }
}
