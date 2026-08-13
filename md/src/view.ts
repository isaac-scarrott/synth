import {
  BoxRenderable,
  MarkdownRenderable,
  ScrollBoxRenderable,
  TextRenderable,
  TextareaRenderable,
  defaultTextareaKeyBindings,
  type CliRenderer,
  type KeyEvent,
  type MouseEvent,
  type Renderable,
  type TreeSitterClient,
} from "@opentui/core"
import { blockAt, nextEditable, outline, segment, splice, toggleTask, type Block } from "./blocks"
import { splitFrontmatter, type Frontmatter } from "./frontmatter"
import { continueList, indentItem, renumber, renumberPreservingCursor } from "./smartlist"
import { currentOffset, find, matchesWithin, NO_MATCHES, step, type Matches } from "./search"
import { linkAt } from "./links"
import { OverlayScrollbar } from "./scrollbar"
import type { Theme } from "./theme"

/// The reading column's ceiling. Prose stops being comfortable somewhere past 80 columns and
/// the "breathing room" half of the locked look is the margin either side, so the column
/// caps and centres rather than filling a wide terminal.
const COLUMN_MAX = 84
const GUTTER_MIN = 2

/// Geometric, not nerd-font: the gotcha list is explicit that nothing load-bearing may
/// depend on a patched font, and a checkbox is as load-bearing as this document gets.
const BOX_UNCHECKED = "□"
const BOX_CHECKED = "■"
const BULLET = ["•", "◦", "▪"]

/// CUA keys on top of OpenTUI's defaults, which bind undo to `ctrl+-` / `super+z` and would
/// leave `ctrl+Z` — the guaranteed baseline, since ⌘ only reaches the PTY when libghostty
/// forwards it — doing nothing at all.
///
/// Copy/cut/paste are deliberately absent. In a ghostty surface ⌘C/⌘X/⌘V are the terminal's
/// own bindings against the real macOS pasteboard (`clipboard-read`/`clipboard-write` are
/// allowed in TerminalTheme), and a paste arrives here as a bracketed-paste event the editor
/// already handles. Binding them again inside the TUI would fight the terminal for the same
/// keys and lose the system pasteboard in the process.
///
/// ⌘←/→ are deliberately NOT rebound: OpenTUI's defaults already map them to the VISUAL line
/// home/end, which is what a Mac means by them on a wrapped paragraph. Rebinding them to the
/// logical `line-home`/`line-end` here would vault the caret across wrapped lines — the same
/// visual-vs-logical bug the block-edge arrow fix cured.
const CUA_BINDINGS = [
  { name: "z", ctrl: true, action: "undo" },
  { name: "z", ctrl: true, shift: true, action: "redo" },
  { name: "y", ctrl: true, action: "redo" },
  { name: "a", ctrl: true, action: "select-all" },
  { name: "a", super: true, action: "select-all" },
] as const

export interface ViewHost {
  /// Text changed by an edit — the view's only way to report a mutation.
  onEdit(source: string): void
  /// A link was activated. Resolution and routing live outside the view.
  onLink(href: string): void
  onQuit(): void
  onSave(): void
  /// Resolve a conflict in the disk's favour — drop the local edits, take the file.
  onDiscard(): void
  onBack(): void
}

type Mode = "read" | "search" | "outline"

/// Where the caret lands in a freshly revealed block. Beyond the two edges: a screen
/// row/column (a click), an absolute source offset (a search match, a boundary join), or a
/// visual edge plus a goal column (arrowing across blocks).
type RevealAt =
  | "start"
  | "end"
  | { row: number; col: number }
  | { offset: number }
  | { edge: "first" | "last"; col: number }

interface BlockView {
  block: Block
  root: BoxRenderable
  /// Present on a rendered block; null while the block is revealed.
  markdown: MarkdownRenderable | null
  editor: TextareaRenderable | null
  checkbox: TextRenderable | null
}

export class DocumentView {
  private renderer: CliRenderer
  private theme: Theme
  private host: ViewHost
  private treeSitter: TreeSitterClient

  private scroll!: ScrollBoxRenderable
  private scrollbar!: OverlayScrollbar
  private column!: BoxRenderable
  private statusBar!: TextRenderable
  private searchBar!: BoxRenderable
  private searchInput!: TextareaRenderable
  private overlay!: BoxRenderable

  private source = ""
  private front: Frontmatter | null = null
  private blocks: Block[] = []
  private views: BlockView[] = []
  private frontView: BoxRenderable | null = null

  private revealed = -1
  /// The trailing newlines stripped off the revealed block's raw so the editor box hugs its
  /// text. Re-appended verbatim on commit — the document's blank-line structure is the
  /// writer's, not ours to normalise.
  private revealedSuffix = ""
  /// The text the editor opened with, so commit can tell "was deleted" from "was empty".
  private revealedOriginal = ""
  /// The document as it stood when the block was revealed, and the block's range within IT.
  ///
  /// Every keystroke rebuilds the whole document by splicing the editor's current text into
  /// this fixed base. Splicing into the *live* source instead is a subtle disaster: the source
  /// grows with each keystroke while the block's recorded range does not, so from the second
  /// character on, each edit overwrites the wrong span and the text duplicates. Nothing else
  /// resegments while a block is open, so the base stays valid for the life of the reveal.
  private revealBase = ""
  private revealStart = 0
  private revealEnd = 0
  private mode: Mode = "read"
  private matches: Matches = NO_MATCHES
  private outlineIndex = 0
  private dirty = false
  private conflicted = false
  private note = ""
  private noteTimer: ReturnType<typeof setTimeout> | null = null
  private disposed = false

  constructor(renderer: CliRenderer, theme: Theme, treeSitter: TreeSitterClient, host: ViewHost) {
    this.renderer = renderer
    this.theme = theme
    this.treeSitter = treeSitter
    this.host = host
  }

  mount() {
    const p = this.theme.palette
    this.scroll = new ScrollBoxRenderable(this.renderer, {
      id: "scroll",
      flexGrow: 1,
      scrollY: true,
      rootOptions: { backgroundColor: "transparent" },
      wrapperOptions: { backgroundColor: "transparent" },
      viewportOptions: { backgroundColor: "transparent" },
      contentOptions: { backgroundColor: "transparent", flexDirection: "column" },
    })
    // Retire the built-in bar through its SETTER: assigning marks visibility as manual, which
    // is the only thing its auto-show (any overflow → visible) respects. The constructor
    // option is not enough — auto-show overwrites it on the first long document. The overlay
    // scrollbar below is the replacement.
    this.scroll.verticalScrollBar.visible = false
    // Clicking off the text — the margin either side, the space past the last block — folds
    // the open block back, the same as Esc. It is what a click away means everywhere else on
    // a Mac, and without it the only way to stop editing is a key. Block clicks stop
    // propagating before they reach here, so this fires only for a genuine click outside.
    this.scroll.onMouseDown = () => this.commit()
    this.renderer.root.add(this.scroll)

    this.scrollbar = new OverlayScrollbar(this.renderer, this.scroll, p)
    this.renderer.root.add(this.scrollbar)

    this.column = new BoxRenderable(this.renderer, {
      id: "column",
      flexDirection: "column",
      backgroundColor: "transparent",
    })
    this.scroll.content.add(this.column)

    this.statusBar = new TextRenderable(this.renderer, {
      id: "status",
      content: "",
      fg: p.faint,
      height: 1,
    })
    this.renderer.root.add(this.statusBar)

    this.searchBar = new BoxRenderable(this.renderer, {
      id: "searchbar",
      height: 1,
      flexDirection: "row",
      visible: false,
      backgroundColor: "transparent",
    })
    this.searchBar.add(
      new TextRenderable(this.renderer, { content: "search ", fg: p.accent, width: 7 }),
    )
    this.searchInput = new TextareaRenderable(this.renderer, {
      id: "searchinput",
      flexGrow: 1,
      height: 1,
      wrapMode: "none",
      textColor: p.fg,
      cursorColor: p.cursor,
      backgroundColor: "transparent",
      onContentChange: () => this.runSearch(),
    })
    this.searchBar.add(this.searchInput)
    this.renderer.root.add(this.searchBar)

    this.overlay = new BoxRenderable(this.renderer, {
      id: "outline",
      position: "absolute",
      left: 4,
      top: 2,
      width: COLUMN_MAX - 8,
      flexDirection: "column",
      visible: false,
      zIndex: 100,
      border: true,
      borderColor: p.rule,
      backgroundColor: p.overlayBg,
      title: " outline ",
      titleAlignment: "left",
    })
    this.renderer.root.add(this.overlay)

    this.renderer.keyInput.on("keypress", (key: KeyEvent) => this.onKey(key))
    this.renderer.on("resize", () => this.relayout())
    this.relayout()
  }

  // MARK: document

  setSource(source: string, options: { preserveScroll?: boolean } = {}) {
    const scrollTop = this.scroll.scrollTop
    // The rebuild below destroys any open editor, so the reveal bookkeeping must go with it.
    // Leaving `revealed` pointing at a destroyed editor after an external reload made the
    // status line claim "editing" while keystrokes fell into the gap between modes.
    this.revealed = -1
    this.revealedSuffix = ""
    this.source = source
    const { front, body } = splitFrontmatter(source)
    this.front = front
    // Offsets are rebased onto the whole file, so every block range stays an index into the
    // bytes on disk and an edit is a plain splice — nothing downstream tracks frontmatter.
    const base = front?.bodyStart ?? 0
    this.blocks = segment(body).map((b) => ({ ...b, start: b.start + base, end: b.end + base }))
    this.rebuild()
    if (options.preserveScroll) this.scroll.scrollTop = scrollTop
    if (this.matches.query) this.matches = find(this.source, this.matches.query, currentOffset(this.matches) ?? 0)
    this.paintStatus()
  }

  get text(): string {
    return this.source
  }

  get scrollTop(): number {
    return this.scroll.scrollTop
  }

  /// Put a saved scroll position back onto a freshly loaded document. The ScrollBox clamps
  /// its setter against the CURRENT content height, which is zero until the next layout pass
  /// — an immediate set is silently swallowed — so keep trying until the layout exists.
  restoreScroll(top: number) {
    if (top <= 0) return
    let tries = 0
    const apply = () => {
      if (this.disposed) return
      if (this.scroll.scrollHeight <= this.scroll.viewport.height) {
        if (++tries < 25) setTimeout(apply, 8)
        return
      }
      this.scroll.scrollTop = top
      this.renderer.requestRender()
    }
    apply()
  }

  /// Re-theme in place, after ghostty announces a light/dark flip. Every renderable holds
  /// resolved colours rather than reading a palette each frame, so the tree is rebuilt — cheap
  /// next to how rarely appearance changes, and it means no colour can be left behind.
  setTheme(theme: Theme) {
    this.theme = theme
    const p = theme.palette
    this.statusBar.fg = p.faint
    this.searchInput.textColor = p.fg
    this.scrollbar.setPalette(p)
    this.overlay.borderColor = p.rule
    this.overlay.backgroundColor = p.overlayBg
    const revealed = this.revealed
    // A search-stepped reveal is unfocused on purpose; re-revealing it focused would steal
    // the keys from the search bar mid-query.
    const hadFocus = this.focusedEditor() !== null
    this.revealed = -1
    this.rebuild()
    if (revealed >= 0) this.reveal(revealed, "start", { focus: hadFocus })
    this.paintStatus()
  }

  /// Stop the timers the view owns. The renderer outlives none of them: a flash's self-clear
  /// or a deferred caret refinement firing after teardown paints into destroyed renderables
  /// and throws — from a test, into whatever unrelated test is running 2.5 seconds later.
  dispose() {
    this.disposed = true
    if (this.noteTimer) clearTimeout(this.noteTimer)
    this.noteTimer = null
  }

  setFlags(flags: { dirty: boolean; conflicted: boolean }) {
    this.dirty = flags.dirty
    this.conflicted = flags.conflicted
    this.paintStatus()
  }

  /// A transient status note. It clears itself: a "reloaded" or "no headings" that lingers
  /// for the session stops being information and starts burying the dirty/conflict signals
  /// beside it.
  flash(note: string) {
    this.note = note
    this.paintStatus()
    if (this.noteTimer) clearTimeout(this.noteTimer)
    this.noteTimer = setTimeout(() => {
      this.note = ""
      this.noteTimer = null
      this.paintStatus()
    }, 2500)
  }

  private rebuild() {
    for (const view of this.views) view.root.destroyRecursively()
    this.views = []
    this.frontView?.destroyRecursively()
    this.frontView = null

    if (this.front && this.front.entries.length > 0) {
      this.frontView = this.buildFrontmatter(this.front)
      this.column.add(this.frontView)
    }

    // An all-blank document (a new file, or one emptied out) still needs one view: with
    // nothing to click and nothing for Enter to reveal, an empty buffer would be uneditable
    // and `synth newfile.md` a dead end.
    const hasEditable = this.blocks.some((b) => b.kind !== "blank")
    let previousWasListItem = false
    for (let i = 0; i < this.blocks.length; i++) {
      const block = this.blocks[i]
      if (block.kind === "blank" && hasEditable) continue
      const view = this.buildBlock(block, i, previousWasListItem)
      this.views.push(view)
      this.column.add(view.root)
      previousWasListItem = block.kind === "list-item"
      if (block.kind === "blank") break
    }
    this.applyHighlights()
  }

  /// Frontmatter as the locked "styled key/value header": a dim rule, aligned keys, and the
  /// values in body ink. Never markdown — see frontmatter.ts for why it never reaches the lexer.
  private buildFrontmatter(front: Frontmatter): BoxRenderable {
    const p = this.theme.palette
    const box = new BoxRenderable(this.renderer, {
      flexDirection: "column",
      marginBottom: 1,
      backgroundColor: "transparent",
    })
    const width = Math.max(...front.entries.map((e) => e.key.length)) + 2
    for (const entry of front.entries) {
      const row = new BoxRenderable(this.renderer, { flexDirection: "row", backgroundColor: "transparent" })
      row.add(new TextRenderable(this.renderer, { content: entry.key.padEnd(width), fg: p.muted, width }))
      row.add(new TextRenderable(this.renderer, { content: entry.value, fg: p.fg, flexGrow: 1 }))
      box.add(row)
    }
    box.add(new TextRenderable(this.renderer, { content: "─".repeat(COLUMN_MAX - 4), fg: p.rule, height: 1 }))
    return box
  }

  private buildBlock(block: Block, index: number, previousWasListItem: boolean): BlockView {
    const p = this.theme.palette
    const tight = block.kind === "list-item" && previousWasListItem
    const root = new BoxRenderable(this.renderer, {
      flexDirection: "row",
      marginTop: tight ? 0 : index === 0 ? 0 : 1,
      marginLeft: block.listDepth * 2,
      backgroundColor: "transparent",
      // A blank-only document renders no text at all; one cell of height keeps the empty
      // block clickable so the file can be edited into existence.
      minHeight: block.kind === "blank" ? 1 : undefined,
    })

    let checkbox: TextRenderable | null = null
    let markdown: MarkdownRenderable | null = null

    if (block.kind === "list-item") {
      const isTask = block.checked !== undefined
      const glyph = isTask
        ? block.checked
          ? BOX_CHECKED
          : BOX_UNCHECKED
        : block.marker.match(/\d/)
          ? block.marker
          : BULLET[Math.min(block.listDepth, BULLET.length - 1)]
      checkbox = new TextRenderable(this.renderer, {
        content: glyph + " ",
        fg: isTask && block.checked ? p.accent : isTask ? p.muted : p.accent,
        width: glyph.length + 1,
      })
      // Only a task item's box is a control. A bullet is decoration, and making it clickable
      // would put a dead hit target in front of every list in every document.
      if (isTask) {
        const raw = block.raw
        const start = block.start
        checkbox.onMouseDown = (event: MouseEvent) => {
          event.stopPropagation()
          this.toggleCheckbox(raw, start)
        }
      }
      root.add(checkbox)
      markdown = this.markdownFor(listItemContent(block))
      root.add(markdown)
    } else {
      markdown = this.markdownFor(block.raw.replace(/\n+$/, ""))
      root.add(markdown)
    }

    root.onMouseDown = (event: MouseEvent) => this.onBlockClick(index, root, event)
    return { block, root, markdown, editor: null, checkbox }
  }

  private markdownFor(content: string): MarkdownRenderable {
    return new MarkdownRenderable(this.renderer, {
      content,
      syntaxStyle: this.theme.syntax,
      conceal: true,
      concealCode: false,
      treeSitterClient: this.treeSitter,
      fg: this.theme.palette.fg,
      flexGrow: 1,
      // MarkdownRenderable defaults flexShrink to 0, which lets a long paragraph hold its
      // intrinsic single-line width and overflow the column instead of wrapping. Shrinking
      // is what hands it the column's width, and wrapping follows from that.
      flexShrink: 1,
      minWidth: 0,
      tableOptions: {
        style: "grid",
        borderColor: this.theme.palette.rule,
        wrapMode: "word",
      },
    })
  }

  // MARK: reveal

  /// Map a click on a RENDERED block to a caret position in its RAW source.
  ///
  /// The view's own gutter glyph for list items (`□ `, `• `) occupies screen columns the raw
  /// does not have, so it is subtracted here; everything conceal hides — markers, fence
  /// lines, per-line quote prefixes — is added back in `placeCaretAtClick`, which also owns
  /// the visual-to-logical mapping once the editor has laid out its wrap.
  private onBlockClick(index: number, root: BoxRenderable, event: MouseEvent) {
    // A click that lands on a block is that block's business. Without this it would also
    // reach the page behind, whose job is to fold the open block back — so every click would
    // reveal a block and immediately close it again.
    event.stopPropagation()
    if (this.mode !== "read") this.closeOverlays()
    const view = this.views[this.viewIndexOf(index)]
    // A click on the block that is already open: the editor's own selection machinery has
    // placed the caret under the pointer; all that can be missing is the focus a
    // search-stepped reveal deliberately withheld.
    if (index === this.revealed) {
      const editor = view?.editor
      if (editor && !editor.focused) {
        editor.focus()
        this.paintStatus()
      }
      return
    }
    const row = Math.max(0, event.y - root.screenY)
    const gutter = view?.checkbox?.width ?? 0
    const column = Math.max(0, event.x - root.screenX - gutter)
    this.reveal(index, { row, col: column })
  }

  private viewIndexOf(blockIndex: number): number {
    return this.views.findIndex((v) => this.blocks[blockIndex] === v.block)
  }

  /// Swap the rendered block for a focused editor over its raw source.
  ///
  /// The cursor lands where the click aimed, mapped through the editor's own wrap layout
  /// (`placeCaretAtClick`). The remaining approximation is columns only: `conceal` makes the
  /// raw slightly longer than what was on screen, so a click deep into a heavily-marked-up
  /// line lands slightly left of the glyph aimed at — never on the wrong line, and one arrow
  /// key fixes it.
  reveal(index: number, at: RevealAt = "start", options: { focus?: boolean } = {}) {
    if (index < 0 || index >= this.blocks.length) return
    if (this.blocks[index].kind === "blank") {
      const editable = nextEditable(this.blocks, index, 1)
      // No editable block anywhere means an empty document; the blank IS the document, and
      // revealing it is the only way to start typing into a new file.
      if (editable >= 0) index = editable
      else if (this.viewIndexOf(index) < 0) return
    }
    if (this.revealed === index) return
    this.commit()

    const viewIndex = this.viewIndexOf(index)
    if (viewIndex < 0) return
    const view = this.views[viewIndex]
    const block = view.block
    const p = this.theme.palette

    const raw = block.raw
    const trailing = /\n+$/.exec(raw)
    this.revealedSuffix = trailing?.[0] ?? ""
    const text = trailing ? raw.slice(0, raw.length - trailing[0].length) : raw
    this.revealBase = this.source
    this.revealStart = block.start
    this.revealEnd = block.end

    view.markdown?.destroyRecursively()
    view.markdown = null
    view.checkbox?.destroyRecursively()
    view.checkbox = null

    const editor = new TextareaRenderable(this.renderer, {
      initialValue: text,
      flexGrow: 1,
      wrapMode: "word",
      textColor: p.fg,
      cursorColor: p.cursor,
      selectionBg: p.selection,
      backgroundColor: p.revealBg,
      syntaxStyle: this.theme.syntax,
      // Ours last: the lookup map is built in order, so a later binding wins the key.
      keyBindings: [...defaultTextareaKeyBindings, ...CUA_BINDINGS],
      onContentChange: () => this.onEditorChange(),
      // Undo and redo rewrite the buffer WITHOUT raising a content change, so a document
      // synced only from `onContentChange` keeps the text the user just undid — and autosaves
      // it. The cursor always moves when the text does, so this is the general net: any edit
      // path, including ones we don't know about, re-syncs here.
      onCursorChange: () => this.onEditorChange(),
    })
    view.editor = editor
    view.root.add(editor)
    this.revealed = index
    this.revealedOriginal = text
    // Search stepping reveals WITHOUT focus: the block shows its highlight while the search
    // bar (or the reader's n/p) keeps every key. Focus arrives when the reader asks for it —
    // Enter, or a click on the open block.
    if (options.focus !== false) editor.focus()

    if (at === "start") editor.setCursor(0, 0)
    else if (at === "end") editor.gotoBufferEnd()
    else if ("offset" in at)
      editor.cursorOffset = Math.max(0, Math.min(at.offset - block.start, text.length))
    else if ("edge" in at) this.placeCaretAtEdge(editor, at.edge, at.col)
    else this.placeCaretAtClick(editor, block, at)

    // Editing something you cannot see is never right: Enter from a scrolled reader and
    // arrowing across blocks both reveal off-screen, and without this the caret walks out of
    // the viewport while the status line claims "editing".
    this.scrollBlockIntoView(view.root)
    this.paintStatus()
    this.renderer.requestRender()
  }

  /// Put the caret where a click on the RENDERED block aimed, once the editor can say what
  /// the eye was looking at.
  ///
  /// Two corrections, then a mapping. The corrections un-hide what conceal hid: a fence's
  /// opening ``` line occupies a raw row the screen never showed (so the row shifts down),
  /// and a blockquote's `> ` starts every raw line (so continuation columns shift right) —
  /// the first line's own marker is the row-0 case of the same shift. The mapping is
  /// visual→logical through the editor's wrap layout: `setCursor(row, col)` speaks LOGICAL
  /// lines, and handing it a screen row called a wrapped paragraph "row 0" and put the caret
  /// lines away from the aim point.
  ///
  /// The editor has no layout until the next frame — its width, and therefore its wrap, is
  /// unknown here — so the caret parks at the start and the mapping runs when the lines
  /// exist. If the user types or moves before then, their position wins.
  private placeCaretAtClick(editor: TextareaRenderable, block: Block, at: { row: number; col: number }) {
    const rawLines = block.raw.split("\n")
    const y = at.row + hiddenLeadRows(block)
    const line = rawLines[Math.min(y, rawLines.length - 1)] ?? ""
    const x = at.col + concealedLinePrefixWidth(block, y, line)
    // Best effort NOW, so a click-and-type never waits a frame: exact for any unwrapped
    // line, and no worse than the visual row for a wrapped one.
    editor.setCursor(Math.min(y, rawLines.length - 1), x)
    const parked = editor.logicalCursor.offset
    this.whenLaidOut(editor, () => {
      // The user typed or moved before the layout arrived — their position wins.
      if (editor.logicalCursor.offset !== parked) return
      const info = editor.editorView.getLineInfo()
      if (info.lineSources.length === 0) return
      const vy = Math.min(y, info.lineSources.length - 1)
      editor.setCursor(info.lineSources[vy] ?? 0, (info.lineStartCols[vy] ?? 0) + x)
      this.renderer.requestRender()
    })
  }

  /// Park the caret on the first or last VISUAL line of a fresh editor, at a goal column —
  /// stepping across a block boundary should feel like moving down one line, not like tabbing
  /// into the next form field at column zero.
  ///
  /// "first" needs no layout: the first visual line always starts logical row 0 column 0, so
  /// the goal column applies immediately. "last" depends on where the wrap put the final
  /// visual row, which does not exist yet — park at the buffer end now, refine when it does.
  private placeCaretAtEdge(editor: TextareaRenderable, edge: "first" | "last", col: number) {
    if (edge === "first") {
      editor.setCursor(0, col)
      return
    }
    editor.gotoBufferEnd()
    const parked = editor.logicalCursor.offset
    this.whenLaidOut(editor, () => {
      // The user typed or moved before the layout arrived — their position wins.
      if (editor.logicalCursor.offset !== parked) return
      const info = editor.editorView.getLineInfo()
      if (info.lineSources.length === 0) return
      const last = info.lineSources.length - 1
      editor.setCursor(info.lineSources[last] ?? 0, (info.lineStartCols[last] ?? 0) + col)
      this.renderer.requestRender()
    })
  }

  /// Run `fn` once a freshly created editor has a laid-out width — anything reading wrap
  /// geometry has nothing to look at until the next frame. Bails when the reveal has moved on
  /// or the view is being torn down.
  private whenLaidOut(editor: TextareaRenderable, fn: () => void) {
    let tries = 0
    const run = () => {
      if (this.disposed) return
      if (this.views[this.viewIndexOf(this.revealed)]?.editor !== editor) return
      if (editor.width <= 0) {
        if (++tries < 25) setTimeout(run, 8)
        return
      }
      fn()
    }
    setTimeout(run, 0)
  }

  /// Scroll the block into view if it is off-screen, the same landing revealMatch gives a
  /// search hit: upper third, with its context around it.
  ///
  /// Twice, because reveal has two arrival paths. From a rendered document (Enter, a click)
  /// the layout is current and the immediate nudge is exact. But arrowing across blocks goes
  /// through commit, whose rebuild replaces every renderable — the new tree has no layout
  /// until the next frame, screenY reads 0, and the immediate nudge is a no-op. So nudge
  /// again once the layout exists; a block already in view makes the second pass a no-op.
  private scrollBlockIntoView(root: BoxRenderable) {
    this.nudgeScrollTo(root)
    let tries = 0
    const nudge = () => {
      if (this.disposed || root.isDestroyed) return
      if (root.height <= 0) {
        if (++tries < 25) setTimeout(nudge, 8)
        return
      }
      this.nudgeScrollTo(root)
    }
    setTimeout(nudge, 0)
  }

  private nudgeScrollTo(root: BoxRenderable) {
    const top = root.screenY - this.scroll.viewport.screenY + this.scroll.scrollTop
    const height = this.scroll.viewport.height
    if (top < this.scroll.scrollTop || top > this.scroll.scrollTop + height - 2) {
      this.scroll.scrollTop = Math.max(0, top - Math.floor(height / 3))
      this.renderer.requestRender()
    }
  }

  /// Fold the revealed block back into the document. Idempotent, so every path that leaves a
  /// block — clicking away, arrowing out, Esc, search, quit — can just call it.
  commit() {
    if (this.revealed < 0) return
    const viewIndex = this.viewIndexOf(this.revealed)
    const view = viewIndex >= 0 ? this.views[viewIndex] : null
    const editor = view?.editor
    if (!editor) {
      this.revealed = -1
      return
    }
    const text = editor.plainText
    // An untouched reveal folds back byte-neutral, renumber included: search stepping opens
    // blocks just to SHOW them, and merely reading a document must never rewrite an author's
    // as-typed list numbers.
    //
    // A block whose text was deleted must not strand its separators: its trailing newlines
    // go with it, and so does ONE adjacent blank block — the two gaps that used to flank it
    // would otherwise abut into a double blank between its neighbours. Only when content was
    // genuinely removed: folding an untouched blank back must stay byte-exact, or opening an
    // empty file and pressing Esc would eat its blank lines.
    const erased = text.trim() === "" && this.revealedOriginal.trim() !== ""
    let start = this.revealStart
    let end = this.revealEnd
    if (erased) {
      const after = this.blocks[this.revealed + 1]
      const before = this.blocks[this.revealed - 1]
      if (after?.kind === "blank" && after.start === end) end = after.end
      else if (before?.kind === "blank" && before.end === start) start = before.start
    }
    // Renumbering is document-scoped and therefore happens on the fold, not per keystroke:
    // an item inserted into the middle of a list changes the numbers of items in OTHER
    // blocks, which the open editor cannot see.
    const updated =
      text === this.revealedOriginal
        ? this.source
        : renumber(splice(this.revealBase, start, end, erased ? "" : text + this.revealedSuffix))
    this.revealed = -1
    this.revealedSuffix = ""
    this.applyEdit(updated)
  }

  /// The whole document as it would be with the open editor's current text folded back in.
  private documentWithEditor(editor: TextareaRenderable): string {
    return splice(this.revealBase, this.revealStart, this.revealEnd, editor.plainText + this.revealedSuffix)
  }

  private onEditorChange() {
    if (this.revealed < 0) return
    const editor = this.views[this.viewIndexOf(this.revealed)]?.editor
    if (!editor) return
    const updated = this.documentWithEditor(editor)
    // Idempotent, because it is called from cursor movement too — most of which changes
    // nothing and must not mark the document dirty.
    if (updated === this.source) return
    // Live-report the edit so autosave and the dirty indicator track keystrokes, but do NOT
    // resegment: rebuilding the tree under a focused editor would destroy the renderable the
    // user is typing into. The resegment happens on commit.
    this.source = updated
    this.host.onEdit(updated)
    this.paintStatus()
  }

  /// Apply a whole-document change made from outside the focused editor.
  private applyEdit(source: string) {
    this.setSource(source, { preserveScroll: true })
    this.host.onEdit(source)
  }

  /// Toggle the task item whose box was clicked, identified by its source rather than by an
  /// index into `this.blocks`.
  ///
  /// Indices go stale the moment another block is open: typing into it moves `this.source`
  /// forward while the block array still holds offsets from the last segmentation, so a
  /// splice at `blocks[index].start` would land in the wrong place and corrupt the document.
  /// So fold the open block back first — which resegments — and then find the item again by
  /// its text, preferring the occurrence nearest where it used to be, since a checklist may
  /// legitimately hold the same line twice.
  private toggleCheckbox(raw: string, start: number) {
    this.commit()
    const candidates = this.blocks.filter((b) => b.kind === "list-item" && b.raw === raw)
    if (candidates.length === 0) return
    const block = candidates.reduce((a, b) =>
      Math.abs(a.start - start) <= Math.abs(b.start - start) ? a : b,
    )
    const next = toggleTask(this.source, block)
    if (next === null) return
    // Deliberately does NOT reveal: toggling a checkbox is the locked "without entering the
    // block" interaction, and revealing would flip the row to raw under the click.
    this.applyEdit(next)
  }

  // MARK: keys

  private onKey(key: KeyEvent) {
    // ⌘ arrives as `super` when libghostty forwards it through the kitty protocol; ctrl is
    // the guaranteed baseline (see the ADR). Both are bound, always.
    const cmd = key.ctrl || key.super === true

    if (this.mode === "outline") {
      if (this.onOutlineKey(key)) return
    }
    if (this.mode === "search") {
      if (this.onSearchKey(key, cmd)) return
    }

    if (cmd && key.name === "f") {
      key.preventDefault()
      this.openSearch()
      return
    }
    if (cmd && key.name === "o") {
      key.preventDefault()
      this.openOutline()
      return
    }
    if (cmd && key.name === "s") {
      key.preventDefault()
      // Save WITHOUT folding the open block: the document text is live-synced on every
      // keystroke, so the flush needs no commit — and a habitual mid-typing ⌘S that closed
      // the editor would punish the most ingrained Mac reflex there is. Renumbering still
      // happens on the natural fold, exactly as it does for autosave.
      this.host.onSave()
      return
    }
    // Follow the link under the caret. A key rather than a click on the rendered text,
    // because OpenTUI emits no OSC 8 hyperlinks — there is nothing beneath a rendered link
    // for a click to hit. On the revealed raw the href is visible and its offsets are exact,
    // so the key acts on exactly what the reader can see; the status line advertises it while
    // the caret is in a link. ctrl+] because ctrl+Enter is not encodable without the kitty
    // keyboard protocol, which a plain terminal running `synth <file>` will not have.
    if (cmd && key.name === "]") {
      key.preventDefault()
      const href = this.linkUnderCursor()
      if (href) this.host.onLink(href)
      else this.flash("no link under the cursor")
      return
    }
    if (cmd && key.name === "q") {
      key.preventDefault()
      this.host.onQuit()
      return
    }
    // ctrl+B, not the ctrl+[ that would pair with ctrl+]: ctrl+[ IS Escape at the byte
    // level, so binding it would either never fire or hijack every Escape in the app.
    if (cmd && key.name === "b") {
      key.preventDefault()
      this.commit()
      this.host.onBack()
      return
    }
    // The other half of the conflict pair the status line offers beside ⌃S. Gated on the
    // conflict so ⌃R stays inert — and unshadowed — the rest of the time; R for revert,
    // because ⌃E and its neighbours are already the editor's own line motions.
    if (cmd && key.name === "r" && this.conflicted) {
      key.preventDefault()
      this.host.onDiscard()
      return
    }

    if (key.name === "escape") {
      key.preventDefault()
      // Esc never traps: it closes whatever is open, then folds the revealed block, and from
      // a plain reading view it does nothing at all rather than becoming a mode.
      if (this.mode !== "read") this.closeOverlays()
      else this.commit()
      this.paintStatus()
      return
    }

    // While the search bar is open the query input owns every plain key. Falling through
    // would double-act them: the input types the "j" while the reader scrolls a line, and a
    // space in the query pages the document.
    if (this.mode === "search") return

    // Routed on FOCUS, not on the reveal: a block opened by search stepping is on screen raw
    // but unfocused, and the reader behind it is still reading — n/p keep stepping, j/k keep
    // scrolling, and nothing types into a block nobody entered.
    if (this.focusedEditor()) {
      this.onEditorKey(key)
      return
    }
    this.onReaderKey(key)
  }

  private onReaderKey(key: KeyEvent) {
    const page = Math.max(1, this.scroll.viewport.height - 2)
    switch (key.name) {
      case "down":
      case "j":
        this.scroll.scrollBy(1)
        break
      case "up":
      case "k":
        this.scroll.scrollBy(-1)
        break
      case "pagedown":
      case "space":
        this.scroll.scrollBy(page)
        break
      case "pageup":
        this.scroll.scrollBy(-page)
        break
      case "home":
        this.scroll.scrollTop = 0
        break
      case "end":
        this.scroll.scrollTop = this.scroll.scrollHeight
        break
      case "return": {
        // Enter from the reader opens the first VISIBLE block for editing — the keyboard-only
        // way in, so the editor is never mouse-gated. The first block of the file would be
        // wrong the moment the reader has scrolled: it would put the caret pages away from
        // what they are looking at. preventDefault, or the very Enter that revealed the block
        // reaches the editor it just focused and types a newline into it.
        key.preventDefault()
        // A block already open from search stepping: Enter steps INTO it, at the caret
        // parked on the match, rather than revealing a different block.
        const open = this.revealed >= 0 ? this.views[this.viewIndexOf(this.revealed)]?.editor : null
        if (open) {
          open.focus()
          this.paintStatus()
          break
        }
        this.reveal(this.firstVisibleBlockIndex())
        break
      }
      case "n":
        this.stepSearch(1)
        break
      case "p":
        this.stepSearch(-1)
        break
    }
  }

  private onEditorKey(key: KeyEvent) {
    const view = this.views[this.viewIndexOf(this.revealed)]
    const editor = view?.editor
    if (!editor) return

    // Structure edits rewrite the OPEN EDITOR's own text, never the document.
    //
    // The tempting alternative — splice the document, resegment, reveal the new block — tears
    // down the renderable the user is typing into, halfway through the keystroke that asked
    // for it: focus lands nowhere and the next characters go in the bin. Editing in place
    // keeps focus, keeps undo history, and lets the open block temporarily hold several list
    // items. Segmentation catches up on commit, which is the only moment it needs to be right.
    if (key.name === "return" && !key.shift) {
      const smart = continueList(editor.plainText, editor.cursorOffset)
      if (smart) {
        key.preventDefault()
        this.rewriteEditor(editor, smart.source, smart.cursor)
        return
      }
    }

    if (key.name === "tab") {
      key.preventDefault()
      const moved = indentItem(
        editor.plainText,
        editor.cursorOffset,
        key.shift ? -1 : 1,
        this.previousListIndent(),
      )
      // Not in a list, or the move was refused: swallow Tab rather than letting it walk focus
      // out of the document.
      if (moved) this.rewriteEditor(editor, moved.source, moved.cursor)
      return
    }

    const plain = !key.ctrl && !key.meta && !key.super && !key.shift

    // Arrowing off the top or bottom edge steps to the neighbouring block, which is what
    // makes the whole document feel like one field rather than a grid of boxes.
    if (key.name === "up" && !key.shift && this.atVisualEdge(editor, -1)) {
      key.preventDefault()
      this.stepBlock(-1)
      return
    }
    if (key.name === "down" && !key.shift && this.atVisualEdge(editor, 1)) {
      key.preventDefault()
      this.stepBlock(1)
      return
    }

    // ←/→ at the buffer's very ends cross into the neighbouring block too. With ↑/↓ stepping
    // and backspace joining, an arrow that stopped at an invisible wall would be the one hole
    // left in the illusion. At the document's edges the caret simply stays, as on a Mac.
    if (plain && key.name === "right" && editor.cursorOffset >= editor.plainText.length) {
      key.preventDefault()
      const target = nextEditable(this.blocks, this.revealed + 1, 1)
      if (target >= 0) {
        this.commit()
        this.reveal(target, "start")
      }
      return
    }
    if (plain && key.name === "left" && editor.cursorOffset === 0) {
      key.preventDefault()
      const target = nextEditable(this.blocks, this.revealed - 1, -1)
      if (target >= 0) {
        this.commit()
        this.reveal(target, "end")
      }
      return
    }

    // Backspace at the block's start (and ⌦ at its end) reaches across the boundary.
    if (plain && key.name === "backspace" && editor.cursorOffset === 0 && !editor.hasSelection()) {
      key.preventDefault()
      this.joinAcrossBoundary(editor, -1)
      return
    }
    if (
      plain &&
      key.name === "delete" &&
      editor.cursorOffset >= editor.plainText.length &&
      !editor.hasSelection()
    ) {
      key.preventDefault()
      this.joinAcrossBoundary(editor, 1)
      return
    }
  }

  /// Delete the separator newline just outside the revealed block — backspace at its start,
  /// ⌦ at its end. One newline per press, never the whole blank run: that is byte-for-byte
  /// what the key would do were the document one big textarea, so each press is predictable
  /// and a stray join is one Enter away from undone. When the run is exhausted the blocks
  /// fall together at the resegment and the caret rides the join.
  private joinAcrossBoundary(editor: TextareaRenderable, dir: 1 | -1) {
    const current = this.documentWithEditor(editor)
    const at = dir === -1 ? this.revealStart - 1 : this.revealStart + editor.plainText.length
    // Frontmatter is a header, not text: backspacing the first block into its closing fence
    // would quietly turn the whole header back into markdown.
    const floor = this.front?.bodyStart ?? 0
    if (at < floor || at >= current.length) return
    if (current[at] !== "\n") return
    // Joining can fuse two ordered lists, and renumbering may then rewrite marker digits on
    // the caret's own line — anchor the caret from the line's tail so it lands on the join.
    const { source, cursor } = renumberPreservingCursor(splice(current, at, at + 1, ""), at)
    this.applyEdit(source)
    this.reveal(blockAt(this.blocks, cursor), { offset: cursor })
  }

  /// Whether the caret sits on the editor's first or last VISUAL line — the edge the user can
  /// see. The editor word-wraps, so one logical line spans several visual rows; keying the
  /// handoff off `logicalCursor.row` would call a wrapped paragraph "the last line" from its
  /// first row and arrow the cursor out of it past lines that are plainly still below.
  private atVisualEdge(editor: TextareaRenderable, dir: 1 | -1): boolean {
    // visualRow is viewport-relative; scrollY is the viewport's offset in visual rows.
    const row = editor.scrollY + editor.visualCursor.visualRow
    if (dir === -1) return row === 0
    return row >= editor.editorView.getTotalVirtualLineCount() - 1
  }

  /// The revealed block's editor when it actually holds keyboard focus. A block can be
  /// revealed WITHOUT focus — search stepping opens the match's block so its highlight is
  /// visible while the search bar keeps the keys — and that state must behave as "reading",
  /// not "editing".
  private focusedEditor(): TextareaRenderable | null {
    if (this.revealed < 0) return null
    const editor = this.views[this.viewIndexOf(this.revealed)]?.editor ?? null
    return editor?.focused ? editor : null
  }

  /// The href under the caret of the revealed block, if any — what the status line offers to
  /// open.
  private linkUnderCursor(): string | null {
    if (this.revealed < 0) return null
    const editor = this.views[this.viewIndexOf(this.revealed)]?.editor
    if (!editor) return null
    return linkAt(editor.plainText, editor.cursorOffset)
  }

  /// The indent, in columns, of the list item immediately preceding the revealed block —
  /// the sibling a Tab would nest this item under. Null when the block above is not a list
  /// item, which is exactly when indenting must be refused.
  private previousListIndent(): number | null {
    const previous = nextEditable(this.blocks, this.revealed - 1, -1)
    if (previous < 0) return null
    const block = this.blocks[previous]
    if (block.kind !== "list-item") return null
    return block.listDepth * 2
  }

  /// Replace the open editor's text and put the caret back. `replaceText` rather than
  /// `setText`: it keeps undo history, so ctrl+Z steps back through a smart-list rewrite the
  /// same way it steps back through typing.
  private rewriteEditor(editor: TextareaRenderable, text: string, cursor: number) {
    editor.replaceText(text)
    editor.cursorOffset = cursor
    this.onEditorChange()
    this.renderer.requestRender()
  }

  /// Step the reveal to the neighbouring block, carrying the caret's visual column with it —
  /// crossing a boundary should feel like moving down one line, not like tabbing into the
  /// next form field at column zero. At the document's edges macOS semantics apply instead:
  /// ↓ on the last line parks at the end of the text, ↑ on the first at its start.
  private stepBlock(dir: 1 | -1) {
    const editor = this.views[this.viewIndexOf(this.revealed)]?.editor
    const target = nextEditable(this.blocks, this.revealed + dir, dir)
    if (target < 0) {
      if (dir === 1) editor?.gotoBufferEnd()
      else editor?.setCursor(0, 0)
      return
    }
    const goal = editor?.visualCursor.visualCol ?? 0
    this.commit()
    this.reveal(target, dir === 1 ? { edge: "first", col: goal } : { edge: "last", col: goal })
  }

  // MARK: search

  private openSearch() {
    this.commit()
    this.mode = "search"
    this.searchBar.visible = true
    this.searchInput.setText("")
    this.searchInput.focus()
    this.relayout()
    this.paintStatus()
  }

  private onSearchKey(key: KeyEvent, cmd: boolean): boolean {
    if (key.name === "return") {
      key.preventDefault()
      this.stepSearch(key.shift ? -1 : 1)
      return true
    }
    if (cmd && key.name === "g") {
      key.preventDefault()
      this.stepSearch(key.shift ? -1 : 1)
      return true
    }
    return false
  }

  private runSearch() {
    const query = this.searchInput.plainText.replace(/\n/g, "")
    this.matches = find(this.source, query, this.scrollOffsetHint())
    // A block revealed by an earlier step goes stale the moment the query moves on: fold it
    // back unless it still holds the current match, or the reader is left staring at a
    // random block in raw.
    if (this.revealed >= 0) {
      const offset = currentOffset(this.matches)
      const block = this.blocks[this.revealed]
      if (offset === null || offset < block.start || offset >= block.end) this.commit()
    }
    this.applyHighlights()
    this.revealMatch()
    this.paintStatus()
  }

  private stepSearch(dir: 1 | -1) {
    if (this.matches.offsets.length === 0) return
    this.matches = step(this.matches, dir)
    this.revealCurrentMatch()
    this.applyHighlights()
    this.paintStatus()
  }

  /// Show the current match where it can actually be SEEN. Only a revealed block can carry a
  /// highlight (see applyHighlights), so stepping opens the match's block as an UNFOCUSED
  /// editor: the tint lands on the match itself, the search bar (or the reader's n/p) keeps
  /// every key, and the caret parks on the match so Enter or a click starts editing right
  /// there. Typing in the bar deliberately does not reveal — that would rebuild the block
  /// tree per keystroke and flip blocks to raw under the reader mid-query; stepping is the
  /// explicit "take me there" gesture.
  private revealCurrentMatch() {
    const offset = currentOffset(this.matches)
    if (offset === null) return
    // Frontmatter renders as a header, not a block: nothing there can highlight, and blockAt
    // would misfile the offset into the LAST block. Put the header on screen instead.
    if (offset < (this.front?.bodyStart ?? 0)) {
      this.scroll.scrollTop = 0
      return
    }
    const index = blockAt(this.blocks, offset)
    if (this.revealed === index) {
      const editor = this.views[this.viewIndexOf(index)]?.editor
      if (editor && !editor.focused) {
        editor.cursorOffset = Math.max(0, Math.min(offset - this.blocks[index].start, editor.plainText.length))
      }
      this.revealMatch()
      return
    }
    this.reveal(index, { offset }, { focus: false })
  }

  /// Scroll the current match into view by finding the block that contains it. Block
  /// granularity is deliberate — it puts the match's paragraph on screen with its context,
  /// which is what a reader searching a document is actually looking for.
  private revealMatch() {
    const offset = currentOffset(this.matches)
    if (offset === null) return
    const index = blockAt(this.blocks, offset)
    const viewIndex = this.viewIndexOf(index)
    if (viewIndex < 0) return
    const view = this.views[viewIndex]
    const top = view.root.screenY - this.scroll.viewport.screenY + this.scroll.scrollTop
    const height = this.scroll.viewport.height
    if (top < this.scroll.scrollTop || top > this.scroll.scrollTop + height - 2) {
      this.scroll.scrollTop = Math.max(0, top - Math.floor(height / 3))
    }
  }

  /// Paint match ranges into whichever blocks are currently revealed as editors.
  ///
  /// Only revealed blocks can carry a highlight: a rendered block is a MarkdownRenderable,
  /// which has no per-range highlight API. The status line therefore does the work for the
  /// rendered majority — it says which match of how many — and stepping scrolls each one into
  /// view. Inside the block being edited, where the reader is actually looking, the match is
  /// tinted properly.
  private applyHighlights() {
    for (const view of this.views) {
      const editor = view.editor
      if (!editor) continue
      editor.clearAllHighlights()
      for (const m of matchesWithin(this.matches, view.block.start, view.block.end)) {
        editor.addHighlightByCharRange({
          start: m.start,
          end: m.end,
          styleId: m.current ? this.theme.matchCurrentStyleId : this.theme.matchStyleId,
        })
      }
    }
  }

  private scrollOffsetHint(): number {
    // Which block is at the top of the viewport, as a source offset — so ctrl+F starts from
    // what the reader can see rather than from the top of the file.
    for (const view of this.views) {
      if (view.root.screenY >= this.scroll.viewport.screenY) return view.block.start
    }
    return 0
  }

  /// The first block whose top is inside the viewport — what "here" means to a scrolled
  /// reader pressing Enter.
  private firstVisibleBlockIndex(): number {
    for (const view of this.views) {
      if (view.root.screenY >= this.scroll.viewport.screenY) return this.blocks.indexOf(view.block)
    }
    return nextEditable(this.blocks, 0, 1)
  }

  // MARK: outline

  private openOutline() {
    this.commit()
    const headings = outline(this.blocks)
    this.overlay.getChildren().forEach((c) => (c as Renderable).destroyRecursively())
    if (headings.length === 0) {
      this.flash("no headings")
      return
    }
    this.mode = "outline"
    this.outlineIndex = 0
    const p = this.theme.palette
    headings.forEach((h, i) => {
      this.overlay.add(
        new TextRenderable(this.renderer, {
          id: `outline-${i}`,
          content: "  ".repeat(Math.max(0, h.level - 1)) + h.text,
          fg: i === 0 ? p.accent : p.fg,
          height: 1,
        }),
      )
    })
    this.overlay.height = Math.min(headings.length + 2, this.renderer.height - 4)
    this.overlay.visible = true
    this.paintStatus()
  }

  private onOutlineKey(key: KeyEvent): boolean {
    const headings = outline(this.blocks)
    if (headings.length === 0) return false
    if (key.name === "down" || key.name === "j") {
      key.preventDefault()
      this.moveOutline(1, headings.length)
      return true
    }
    if (key.name === "up" || key.name === "k") {
      key.preventDefault()
      this.moveOutline(-1, headings.length)
      return true
    }
    if (key.name === "return") {
      key.preventDefault()
      const target = headings[this.outlineIndex]
      this.closeOverlays()
      this.jumpToBlock(target.index)
      return true
    }
    return false
  }

  private moveOutline(dir: 1 | -1, count: number) {
    const p = this.theme.palette
    const previous = this.overlay.getRenderable(`outline-${this.outlineIndex}`) as TextRenderable | undefined
    if (previous) previous.fg = p.fg
    this.outlineIndex = (this.outlineIndex + dir + count) % count
    const next = this.overlay.getRenderable(`outline-${this.outlineIndex}`) as TextRenderable | undefined
    if (next) next.fg = p.accent
  }

  private jumpToBlock(index: number) {
    const viewIndex = this.viewIndexOf(index)
    if (viewIndex < 0) return
    const view = this.views[viewIndex]
    this.scroll.scrollTop = Math.max(
      0,
      view.root.screenY - this.scroll.viewport.screenY + this.scroll.scrollTop,
    )
  }

  private closeOverlays() {
    this.mode = "read"
    this.overlay.visible = false
    this.searchBar.visible = false
    this.searchInput.blur()
    this.relayout()
    // The status line names the keys of whatever is open, so closing has to repaint it or it
    // keeps offering "⏎ jump" for an overlay that is gone.
    this.paintStatus()
  }

  // MARK: chrome

  private relayout() {
    const width = this.renderer.width
    const columnWidth = Math.max(20, Math.min(COLUMN_MAX, width - GUTTER_MIN * 2))
    const gutter = Math.max(GUTTER_MIN, Math.floor((width - columnWidth) / 2))
    this.column.width = columnWidth
    this.column.marginLeft = gutter
    this.overlay.left = gutter
    this.overlay.width = Math.min(columnWidth, width - gutter * 2)
    this.renderer.requestRender()
  }

  /// One line, and only what changed state: the file's name, whether it has unsaved or
  /// conflicting edits, and the current search position. No persistent chrome is the locked
  /// look, so this is the whole of it.
  private paintStatus() {
    const parts: string[] = []
    const focused = this.focusedEditor()
    if (this.conflicted) parts.push("changed on disk — ⌃S keeps yours · ⌃R takes disk")
    else if (this.dirty) parts.push("unsaved")
    if (this.matches.query && this.matches.offsets.length > 0) {
      const count = `${this.matches.current + 1}/${this.matches.offsets.length}`
      // Matches outlive the search bar so n/p can keep stepping — but a bare count lingering
      // after Esc reads as a stuck indicator unless the keys that explain it ride along.
      const stepping = this.mode === "read" && !focused
      parts.push(stepping ? `${count} · n next · p prev` : count)
    } else if (this.matches.query && this.mode === "search") {
      parts.push(`no match for "${this.matches.query}"`)
    }
    if (this.note) parts.push(this.note)
    if (this.mode === "outline") parts.push("↑↓ pick · ⏎ jump · esc close")
    else if (this.mode === "search") parts.push("⏎ next · ⇧⏎ prev · esc close")
    else if (focused) parts.push(this.linkUnderCursor() ? "⌃] open link · esc to render" : "editing · esc to render")
    // A block opened by search stepping: raw on screen, but no keyboard focus — the reader
    // is still reading, one Enter (or click) away from editing at the match.
    else if (this.revealed >= 0) parts.push("⏎ edit · esc to render")
    else parts.push("⌃F find · ⌃O outline · click to edit")

    this.statusBar.content = parts.join("  ·  ")
    this.statusBar.fg = this.conflicted
      ? this.theme.palette.danger
      : this.dirty
        ? this.theme.palette.muted
        : this.theme.palette.faint
    this.renderer.requestRender()
  }
}

/// Whole raw rows the rendered block never showed. A fence's opening ``` line is concealed,
/// so the screen's first code row is the raw's second row; without this every fence click
/// lands one line high.
function hiddenLeadRows(block: Block): number {
  return block.kind === "code" ? 1 : 0
}

/// How many leading characters of raw line `y` conceal hides from the reader. The inverse of
/// that hiding is what maps a click back onto the source. Markers live on the first line;
/// a blockquote's `> ` starts every line.
function concealedLinePrefixWidth(block: Block, y: number, line: string): number {
  if (block.kind === "blockquote") return /^\s*>\s?/.exec(line)?.[0].length ?? 0
  if (y > 0) return 0
  switch (block.kind) {
    case "heading":
      return /^#{1,6}\s*/.exec(line)?.[0].length ?? 0
    case "list-item":
      return listItemPrefix(line).length
    default:
      return 0
  }
}

function listItemPrefix(line: string): string {
  const m = /^(\s*)([-*+]|\d+[.)])(\s+)(\[[ xX]\]\s*)?/.exec(line)
  return m ? m[0] : ""
}

/// A list item's text with its marker and checkbox removed — what the rendered row shows to
/// the right of the glyph the view draws itself.
function listItemContent(block: Block): string {
  const head = listItemPrefix(block.raw.split("\n")[0]).length
  const rest = block.raw.slice(head).replace(/\n+$/, "")
  // Continuation lines keep their own indentation relative to the item, which is what makes
  // a wrapped multi-line item still read as one item.
  return rest
}
