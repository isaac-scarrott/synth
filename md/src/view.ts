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
import { continueList, indentItem, renumber } from "./smartlist"
import { currentOffset, find, matchesWithin, NO_MATCHES, step, type Matches } from "./search"
import { linkAt } from "./links"
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
const CUA_BINDINGS = [
  { name: "z", ctrl: true, action: "undo" },
  { name: "z", ctrl: true, shift: true, action: "redo" },
  { name: "y", ctrl: true, action: "redo" },
  { name: "a", ctrl: true, action: "select-all" },
  { name: "a", super: true, action: "select-all" },
  { name: "left", super: true, action: "line-home" },
  { name: "right", super: true, action: "line-end" },
  { name: "left", super: true, shift: true, action: "select-line-home" },
  { name: "right", super: true, shift: true, action: "select-line-end" },
] as const

export interface ViewHost {
  /// Text changed by an edit — the view's only way to report a mutation.
  onEdit(source: string): void
  /// A link was activated. Resolution and routing live outside the view.
  onLink(href: string): void
  onQuit(): void
  onSave(): void
  onBack(): void
}

type Mode = "read" | "search" | "outline"

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
      scrollbarOptions: { visible: false },
    })
    // Clicking off the text — the margin either side, the space past the last block — folds
    // the open block back, the same as Esc. It is what a click away means everywhere else on
    // a Mac, and without it the only way to stop editing is a key. Block clicks stop
    // propagating before they reach here, so this fires only for a genuine click outside.
    this.scroll.onMouseDown = () => this.commit()
    this.renderer.root.add(this.scroll)

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

  /// Re-theme in place, after ghostty announces a light/dark flip. Every renderable holds
  /// resolved colours rather than reading a palette each frame, so the tree is rebuilt — cheap
  /// next to how rarely appearance changes, and it means no colour can be left behind.
  setTheme(theme: Theme) {
    this.theme = theme
    const p = theme.palette
    this.statusBar.fg = p.faint
    this.searchInput.textColor = p.fg
    this.overlay.borderColor = p.rule
    this.overlay.backgroundColor = p.overlayBg
    const revealed = this.revealed
    this.revealed = -1
    this.rebuild()
    if (revealed >= 0) this.reveal(revealed, "start")
    this.paintStatus()
  }

  setFlags(flags: { dirty: boolean; conflicted: boolean }) {
    this.dirty = flags.dirty
    this.conflicted = flags.conflicted
    this.paintStatus()
  }

  flash(note: string) {
    this.note = note
    this.paintStatus()
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

    let previousWasListItem = false
    for (let i = 0; i < this.blocks.length; i++) {
      const block = this.blocks[i]
      if (block.kind === "blank") continue
      const view = this.buildBlock(block, i, previousWasListItem)
      this.views.push(view)
      this.column.add(view.root)
      previousWasListItem = block.kind === "list-item"
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
  /// Two shifts separate the two, and both are on the first line only. The view draws its own
  /// gutter glyph for list items (`□ `, `• `), which occupies screen columns the raw does not
  /// have; and `conceal` hides the block's own marker (`# `, `- [ ] `, `> `), which occupies
  /// raw columns the screen does not have. Subtract the first, add the second.
  private onBlockClick(index: number, root: BoxRenderable, event: MouseEvent) {
    // A click that lands on a block is that block's business. Without this it would also
    // reach the page behind, whose job is to fold the open block back — so every click would
    // reveal a block and immediately close it again.
    event.stopPropagation()
    if (this.mode !== "read") this.closeOverlays()
    const view = this.views[this.viewIndexOf(index)]
    const row = Math.max(0, event.y - root.screenY)
    const gutter = view?.checkbox?.width ?? 0
    const column = Math.max(0, event.x - root.screenX - gutter)
    this.reveal(index, { row, col: column + (row === 0 ? concealedPrefixWidth(this.blocks[index]) : 0) })
  }

  private viewIndexOf(blockIndex: number): number {
    return this.views.findIndex((v) => this.blocks[blockIndex] === v.block)
  }

  /// Swap the rendered block for a focused editor over its raw source.
  ///
  /// The cursor lands at the clicked cell's own row/column inside the raw. That is an
  /// approximation on purpose: `conceal` means the raw is strictly longer than what was on
  /// screen, so a click deep into a heavily-marked-up line lands slightly left of the glyph
  /// aimed at. It is never the wrong block or the wrong line, one arrow key fixes it, and the
  /// exact alternative is a rendered-to-source offset map per inline token.
  reveal(index: number, at: { row: number; col: number } | "start" | "end" = "start") {
    if (index < 0 || index >= this.blocks.length) return
    if (this.blocks[index].kind === "blank") {
      const editable = nextEditable(this.blocks, index, 1)
      if (editable < 0) return
      index = editable
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
    editor.focus()

    if (at === "start") editor.setCursor(0, 0)
    else if (at === "end") editor.gotoBufferEnd()
    else editor.setCursor(at.row, at.col)

    this.paintStatus()
    this.renderer.requestRender()
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
    // Renumbering is document-scoped and therefore happens here, not per keystroke: an item
    // inserted into the middle of a list changes the numbers of items in OTHER blocks, which
    // the open editor cannot see.
    const updated = renumber(this.documentWithEditor(editor))
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
      this.commit()
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

    if (key.name === "escape") {
      key.preventDefault()
      // Esc never traps: it closes whatever is open, then folds the revealed block, and from
      // a plain reading view it does nothing at all rather than becoming a mode.
      if (this.mode !== "read") this.closeOverlays()
      else this.commit()
      this.paintStatus()
      return
    }

    if (this.revealed >= 0) {
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
      case "return":
        // Enter from the reader opens the first block for editing — the keyboard-only way in,
        // so the editor is never mouse-gated.
        this.reveal(nextEditable(this.blocks, 0, 1))
        break
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

    // Arrowing off the top or bottom edge steps to the neighbouring block, which is what
    // makes the whole document feel like one field rather than a grid of boxes.
    if (key.name === "up" && !key.shift && editor.logicalCursor.row === 0) {
      key.preventDefault()
      this.stepBlock(-1)
      return
    }
    if (key.name === "down" && !key.shift && editor.logicalCursor.row === editor.lineCount - 1) {
      key.preventDefault()
      this.stepBlock(1)
      return
    }
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

  private stepBlock(dir: 1 | -1) {
    const from = this.revealed
    const target = nextEditable(this.blocks, from + dir, dir)
    if (target < 0) return
    this.commit()
    this.reveal(target, dir === 1 ? "start" : "end")
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
    this.applyHighlights()
    this.revealMatch()
    this.paintStatus()
  }

  private stepSearch(dir: 1 | -1) {
    if (this.matches.offsets.length === 0) return
    this.matches = step(this.matches, dir)
    this.applyHighlights()
    this.revealMatch()
    this.paintStatus()
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
    if (this.conflicted) parts.push("changed on disk — ⌃S keeps yours")
    else if (this.dirty) parts.push("unsaved")
    if (this.matches.query) {
      parts.push(
        this.matches.offsets.length === 0
          ? `no match for "${this.matches.query}"`
          : `${this.matches.current + 1}/${this.matches.offsets.length}`,
      )
    }
    if (this.note) parts.push(this.note)
    if (this.mode === "outline") parts.push("↑↓ pick · ⏎ jump · esc close")
    else if (this.mode === "search") parts.push("⏎ next · ⇧⏎ prev · esc close")
    else if (this.revealed >= 0) parts.push(this.linkUnderCursor() ? "⌃] open link · esc to render" : "editing · esc to render")
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

/// How many leading characters of a block's first raw line `conceal` hides from the reader.
/// The inverse of that hiding is what maps a click back onto the source.
function concealedPrefixWidth(block: Block): number {
  const first = block.raw.split("\n")[0]
  switch (block.kind) {
    case "heading":
      return /^#{1,6}\s*/.exec(first)?.[0].length ?? 0
    case "list-item":
      return listItemPrefix(first).length
    case "blockquote":
      return /^\s*>\s?/.exec(first)?.[0].length ?? 0
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
