import { Renderable, RGBA, parseColor, type MouseEvent, type OptimizedBuffer } from "@opentui/core"
import type { CliRenderer, ScrollBoxRenderable } from "@opentui/core"
import type { Palette } from "./theme"

/// A macOS-style overlay scrollbar, replacing OpenTUI's built-in bar.
///
/// The built-in ScrollBar is desktop-toolkit chrome: a permanent full-height column of `█`
/// cells with its own track. Safari's is the opposite — nothing at rest, a slim pill while
/// you scroll, a slightly wider one under the pointer — and that is the look this renders,
/// translated to cell granularity:
///
/// - Invisible at rest. It appears when the document scrolls and folds away shortly after
///   the last movement, so a still page is all page.
/// - The thumb is drawn with right-half-width glyphs (`▐`, capped by `▗`/`▝`), a hairline
///   against the right edge rather than a solid column. Position and length are computed in
///   half-cell units, so it travels smoothly instead of jumping whole rows.
/// - Under the pointer or while dragging it widens to the full cell (`█`, capped by `▄`/`▀`)
///   and brightens — Safari's grab affordance — and it stays put until the pointer leaves.
/// - The whole bar is a live drag target: grab the thumb to scroll, or press anywhere on the
///   track and the thumb comes to the pointer.
///
/// It is an absolutely-positioned sibling of the ScrollBox, glued to the viewport's right
/// edge every frame. Resting is expressed as WIDTH ZERO rather than `visible = false`: an
/// invisible renderable is skipped by the update pass (which is where scroll activity is
/// watched) and a visible-but-idle one would still occupy the hit grid, swallowing the
/// clicks in the margin that mean "click away" to the page behind it. A zero-width box does
/// neither — it keeps updating, hits nothing, draws nothing.
const LINGER_MS = 900
const BAR_WIDTH = 2 // one glyph column plus one silent column of grab area to its left

export class OverlayScrollbar extends Renderable {
  private scrollbox: ScrollBoxRenderable
  private thumbColor!: RGBA
  private thumbHoverColor!: RGBA
  private shown = false
  private lastScrollTop = -1
  private hovered = false
  private dragging = false
  /// Half-cell offset between where the thumb was grabbed and its top edge.
  private grabOffset = 0
  /// When the last press/drag reached us — the liveness signal for a drag the renderer never
  /// captured for us (see onUpdate).
  private lastDragEventAt = 0
  private hideTimer: ReturnType<typeof setTimeout> | null = null

  constructor(renderer: CliRenderer, scrollbox: ScrollBoxRenderable, palette: Palette) {
    super(renderer, {
      id: "overlay-scrollbar",
      position: "absolute",
      width: 0,
      zIndex: 50,
    })
    this.scrollbox = scrollbox
    this.setPalette(palette)

    this.onMouseOver = () => {
      this.hovered = true
      this.cancelHide()
      this.requestRender()
    }
    this.onMouseOut = () => {
      this.hovered = false
      // An `out` during a drag means the drag is LOST, not merely wandering: once the
      // renderer captures the pointer for us (which the first drag event over the bar does),
      // it stops sending us `out` at all. So this only fires when that first drag report
      // already jumped off the bar — a fast flick — and no further event will ever reach us.
      // Without this the bar stays in `dragging` forever and never folds away.
      this.dragging = false
      this.scheduleHide()
      this.requestRender()
    }
    this.onMouseDown = (event: MouseEvent) => {
      event.stopPropagation()
      event.preventDefault()
      this.beginDrag((event.y - this.y) * 2)
    }
    this.onMouseDrag = (event: MouseEvent) => {
      event.stopPropagation()
      // A drag with no drag state is a grab we lost (or never saw the press for) with the
      // pointer back over the bar — re-enter it as a fresh grab rather than ignoring it.
      if (!this.dragging) this.beginDrag((event.y - this.y) * 2)
      else {
        this.lastDragEventAt = Date.now()
        this.dragTo((event.y - this.y) * 2)
      }
    }
    this.onMouseUp = () => {
      if (!this.dragging) return
      this.dragging = false
      if (!this.hovered) this.scheduleHide()
    }
    // The bar sits over the page's edge, so a wheel event that lands on it must scroll the
    // document the same as one that missed it.
    this.onMouseScroll = (event: MouseEvent) => {
      if (!event.scroll) return
      event.stopPropagation()
      const direction = event.scroll.direction === "up" ? -1 : event.scroll.direction === "down" ? 1 : 0
      this.scrollbox.scrollBy(direction * event.scroll.delta)
    }
  }

  setPalette(palette: Palette) {
    this.thumbColor = parseColor(palette.faint)
    this.thumbHoverColor = parseColor(palette.muted)
    this.requestRender()
  }

  /// Called every frame the renderer draws: keeps the bar glued to the viewport's right edge
  /// through resizes and search-bar toggles, and watches scrollTop — every scroll path in the
  /// app funnels through it, so a change IS scroll activity, with no hooks into the callers.
  protected onUpdate() {
    const viewport = this.scrollbox.viewport
    const left = viewport.x + viewport.width - BAR_WIDTH
    if (this.left !== left) this.left = left
    if (this.top !== viewport.y) this.top = viewport.y
    if (this.height !== viewport.height) this.height = viewport.height

    const top = this.scrollbox.scrollTop
    if (top !== this.lastScrollTop) {
      const wasSettled = this.lastScrollTop >= 0
      this.lastScrollTop = top
      if (wasSettled) this.show()
    }
    if (this.shown && !this.scrollable()) this.hide()

    // The last net under a lost drag. A drag is only reliably ours once the renderer has
    // captured the pointer for us, and capture engages on the first drag event that lands on
    // the bar by hit test — a press followed by a fast flick can skip it entirely, and then
    // release happens somewhere we will never hear about. So: dragging, not captured, and
    // nothing has reached us for long enough that a live scrub would have → the drag is dead.
    // A genuine press-and-hold trips this too, harmlessly — the next movement over the bar
    // re-enters the drag through onMouseDrag's beginDrag.
    if (this.dragging && Date.now() - this.lastDragEventAt > 600) {
      const captured = (this.ctx as unknown as { capturedRenderable?: Renderable }).capturedRenderable
      if (captured !== this) {
        this.dragging = false
        if (!this.hovered) this.scheduleHide()
      }
    }
  }

  protected renderSelf(buffer: OptimizedBuffer) {
    if (!this.shown) return
    const metrics = this.metrics()
    if (!metrics) return
    const wide = this.hovered || this.dragging
    const color = wide ? this.thumbHoverColor : this.thumbColor
    const x = this.x + BAR_WIDTH - 1
    const endHalf = metrics.startHalf + metrics.thumbHalf
    const firstRow = Math.floor(metrics.startHalf / 2)
    const lastRow = Math.ceil(endHalf / 2) - 1
    for (let row = firstRow; row <= lastRow; row++) {
      const cellStart = row * 2
      const coversTop = metrics.startHalf <= cellStart
      const coversBottom = endHalf >= cellStart + 2
      const glyph =
        coversTop && coversBottom
          ? wide ? "█" : "▐"
          : coversTop
            ? wide ? "▀" : "▝"
            : wide ? "▄" : "▗"
      buffer.setCellWithAlphaBlending(x, this.y + row, glyph, color, TRANSPARENT)
    }
  }

  /// Start a drag at a pointer position (in half-cells): from the thumb, keep the grip where
  /// the finger landed; from the bare track, bring the thumb to the pointer, centred —
  /// Safari's "jump to here" rather than a page-at-a-time crawl.
  private beginDrag(halfAt: number) {
    const metrics = this.metrics()
    if (!metrics) return
    if (halfAt >= metrics.startHalf && halfAt < metrics.startHalf + metrics.thumbHalf) {
      this.grabOffset = halfAt - metrics.startHalf
    } else {
      this.grabOffset = metrics.thumbHalf / 2
      this.dragTo(halfAt)
    }
    this.dragging = true
    this.lastDragEventAt = Date.now()
    this.cancelHide()
  }

  /// Thumb geometry in half-cell units, or null when the document fits and there is nothing
  /// to scroll by.
  private metrics(): { startHalf: number; thumbHalf: number; trackHalf: number } | null {
    const viewportHeight = this.scrollbox.viewport.height
    const contentHeight = this.scrollbox.scrollHeight
    if (viewportHeight <= 0 || contentHeight <= viewportHeight) return null
    const trackHalf = viewportHeight * 2
    // Never thinner than a full cell: a one-half-cell thumb on a long document is a fleck,
    // not a handle.
    const thumbHalf = Math.min(trackHalf, Math.max(2, Math.round((trackHalf * viewportHeight) / contentHeight)))
    const range = contentHeight - viewportHeight
    const startHalf = Math.round(((trackHalf - thumbHalf) * this.scrollbox.scrollTop) / range)
    return { startHalf, thumbHalf, trackHalf }
  }

  private dragTo(halfAt: number) {
    const metrics = this.metrics()
    if (!metrics) return
    const travel = metrics.trackHalf - metrics.thumbHalf
    if (travel <= 0) return
    const ratio = Math.max(0, Math.min(1, (halfAt - this.grabOffset) / travel))
    this.scrollbox.scrollTop = Math.round(ratio * (this.scrollbox.scrollHeight - this.scrollbox.viewport.height))
    this.requestRender()
  }

  private scrollable(): boolean {
    return this.scrollbox.scrollHeight > this.scrollbox.viewport.height
  }

  private show() {
    if (!this.scrollable()) return
    this.shown = true
    this.width = BAR_WIDTH
    this.scheduleHide()
    this.requestRender()
  }

  private hide() {
    this.shown = false
    this.hovered = false
    this.dragging = false
    this.width = 0
    this.requestRender()
  }

  private scheduleHide() {
    this.cancelHide()
    this.hideTimer = setTimeout(() => {
      this.hideTimer = null
      if (this.hovered || this.dragging) return
      this.hide()
    }, LINGER_MS)
  }

  private cancelHide() {
    if (this.hideTimer === null) return
    clearTimeout(this.hideTimer)
    this.hideTimer = null
  }

  protected destroySelf() {
    this.cancelHide()
    super.destroySelf()
  }
}

const TRANSPARENT = RGBA.fromValues(0, 0, 0, 0)
