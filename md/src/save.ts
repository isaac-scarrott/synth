import { watch, type FSWatcher } from "node:fs"
import { readFile, writeFile } from "node:fs/promises"

/// Autosave + external-change reload, and the rule that decides between them.
///
/// Both directions are live at once because that is the actual working setup: an agent is
/// editing these files while the human reads them. So the locked rule is last-writer-wins
/// EXCEPT that unsaved keystrokes are never thrown away. Concretely:
///
///   - clean buffer + file changed on disk  -> adopt the file, silently. This is the common
///     case (an agent rewrote the plan you were reading) and it must not need a keypress.
///   - dirty buffer + file changed on disk  -> keep what the human typed, raise `conflict`,
///     and stop autosaving until they resolve it. Autosaving through a conflict is how you
///     silently destroy the agent's write; prompting is how you lose the human's.
///
/// The debounce exists so a burst of typing is one write, and so the watcher doesn't see —
/// and try to reload — every intermediate state of the writer's own sentence.

export interface FileState {
  path: string
  text: string
  dirty: boolean
  /// Set when disk and buffer have diverged and the buffer won. Cleared by save/discard.
  conflict: boolean
}

export interface DocumentFileEvents {
  /// The file changed underneath a clean buffer and has been adopted.
  onExternalChange?: (text: string) => void
  /// The file changed underneath a DIRTY buffer; the buffer is kept and autosave pauses.
  onConflict?: () => void
  onSaved?: () => void
  onError?: (error: unknown) => void
}

export const AUTOSAVE_DELAY_MS = 400

export class DocumentFile {
  readonly path: string
  private text = ""
  private dirty = false
  private conflict = false
  /// The exact bytes last read from or written to disk. Comparing against this — rather than
  /// against mtime — is what makes our own writes not look like somebody else's edit.
  private onDisk = ""
  private timer: ReturnType<typeof setTimeout> | null = null
  private watcher: FSWatcher | null = null
  private closed = false
  private events: DocumentFileEvents

  constructor(path: string, events: DocumentFileEvents = {}) {
    this.path = path
    this.events = events
  }

  static async open(path: string, events: DocumentFileEvents = {}): Promise<DocumentFile> {
    const file = new DocumentFile(path, events)
    await file.load()
    file.startWatching()
    return file
  }

  get state(): FileState {
    return { path: this.path, text: this.text, dirty: this.dirty, conflict: this.conflict }
  }

  private async load() {
    try {
      this.text = await readFile(this.path, "utf8")
    } catch {
      // A path that does not exist yet is a new document, not an error: `synth notes.md` on
      // a missing file should open an empty buffer that autosave then creates.
      this.text = ""
    }
    this.onDisk = this.text
    this.dirty = false
    this.conflict = false
  }

  /// Record an edit and schedule the write.
  edit(text: string) {
    if (text === this.text) return
    this.text = text
    this.dirty = text !== this.onDisk
    if (this.timer) clearTimeout(this.timer)
    // A conflicted buffer holds still until it is explicitly saved: writing now would
    // overwrite the change we already decided not to adopt. Re-checked when the timer
    // actually fires, not only here — a conflict usually appears DURING the debounce window
    // (that is what the window is for), and a timer armed before it would otherwise land
    // afterwards and overwrite the very write that caused it.
    if (this.conflict) return
    this.timer = setTimeout(() => {
      this.timer = null
      if (this.conflict) return
      void this.flush()
    }, AUTOSAVE_DELAY_MS)
  }

  /// Write now, whatever the debounce was doing. Also how a conflict is resolved in the
  /// buffer's favour — an explicit save is the user saying which side wins.
  async flush(): Promise<void> {
    if (this.timer) {
      clearTimeout(this.timer)
      this.timer = null
    }
    if (this.text === this.onDisk) {
      this.dirty = false
      return
    }
    const writing = this.text
    try {
      await writeFile(this.path, writing, "utf8")
      this.onDisk = writing
      // Only the bytes we wrote are clean; anything typed while the write was in flight
      // keeps the buffer dirty and schedules its own.
      this.dirty = this.text !== this.onDisk
      this.conflict = false
      this.events.onSaved?.()
    } catch (error) {
      this.events.onError?.(error)
    }
  }

  /// Throw away local edits and take the file. The other half of resolving a conflict.
  async discard(): Promise<string> {
    await this.load()
    return this.text
  }

  private startWatching() {
    try {
      this.watcher = watch(this.path, () => void this.reload())
    } catch {
      // Watching is an enhancement — a file on a filesystem that can't deliver events still
      // opens, edits and autosaves. It just won't live-reload.
    }
  }

  private async reload() {
    if (this.closed) return
    let next: string
    try {
      next = await readFile(this.path, "utf8")
    } catch {
      // Editors that write by rename briefly unlink the path; the following event carries
      // the new file, so a failed read here is noise rather than a change.
      return
    }
    if (next === this.onDisk) return // our own write echoing back
    this.onDisk = next
    if (this.dirty) {
      if (next === this.text) {
        // Disk independently arrived at exactly what the buffer holds. Nothing is in
        // conflict; the buffer is simply clean now.
        this.dirty = false
        return
      }
      this.conflict = true
      if (this.timer) {
        clearTimeout(this.timer)
        this.timer = null
      }
      this.events.onConflict?.()
      return
    }
    this.text = next
    this.events.onExternalChange?.(next)
  }

  async close() {
    this.closed = true
    this.watcher?.close()
    this.watcher = null
    // Quitting is not choosing. A conflicted buffer means the human's keystrokes and an
    // agent's write both exist and nobody has said which wins; flushing here would destroy
    // the agent's version silently, at the exact moment no one is looking at the file. So a
    // conflicted close keeps the DISK bytes — the explicit ⌃S (flush) / ⌃R (discard) pair is
    // the only resolution, and the cost of closing without choosing falls on the unsaved
    // local edits rather than on the other writer's completed work.
    if (this.conflict) {
      if (this.timer) {
        clearTimeout(this.timer)
        this.timer = null
      }
      return
    }
    await this.flush()
  }
}
