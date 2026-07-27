import AppKit
import Foundation
import Observation
import SwiftUI

/// A low-frequency derived fact posted by a session's supervisor onto the bus.
/// The firehose (PTY bytes, cursor moves) never appears here — see docs/adr/0001.
enum SessionEvent: Sendable {
    case statusChanged(UUID, SessionStatus)
    case titleChanged(UUID, String)
    /// A new Claude conversation started in an existing row (fresh startup or `/clear`) — drop
    /// the previous conversation's ai-title so the stale name doesn't linger until a new one is
    /// generated. Resume/compact keep their title, so they never emit this.
    case titleReset(UUID)
    case exited(UUID, Int32?)
    /// The session's true exit status, reported over the hook socket (zshexit / the claude
    /// shim) just before the process dies. Needed because macOS `login` — libghostty's PTY
    /// wrapper — exits 0 whatever its child's status was, so `.exited`'s own code is
    /// always 0 and can't carry the clean-vs-failure fact (features 2026-07-06).
    case exitCodeReported(UUID, Int32)
    /// A terminal was detected running a coding agent (or stopped) — flips the row's visual.
    case kindChanged(UUID, SessionKind)
    /// A background session finished a turn — surface it unless it's the one on screen.
    case markUnread(UUID)
    /// The agent reported its own session id (Claude Code via its SessionStart hook, opencode
    /// off `session.created`) — stored so a restored row can resume the conversation (ADR-0010).
    case agentSessionCaptured(UUID, String)
    /// The agent is not merely *starting* but reachable — its supervisor can hand it text.
    /// Only a supervisor posts this: Claude Code is ready the moment its own hook fires from
    /// inside the running process, while opencode is ready only once its event stream connects
    /// (its shim announces the launch a beat before the server binds).
    case agentReady(UUID)
    /// A browser session's address changed — every navigation, including ones the engine's
    /// future CDP clients initiate (ADR-0011). Renames the row and feeds the branch recents.
    case browserNavigated(UUID, URL)
    /// The page's document title — auto-names the session row (URL host+path stands as the
    /// fallback until it arrives) and labels the recents entry.
    case browserPageTitled(UUID, String)
    /// window.open / target=_blank: one page per session, so a popup becomes a NEW
    /// browser session in the same branch, pre-navigated and selected.
    case browserPopupRequested(UUID, URL)
    /// A link clicked in a terminal surface (libghostty OPEN_URL). The UUID is the clicking
    /// session (nil for an app-scoped action → the on-screen session). Scheme + host route
    /// it: loopback dev-server pages open in the in-app browser, everything else to the OS.
    case openURLRequested(UUID?, URL)
}

/// The transient transport carrying derived facts to the single consumer (the store).
/// This is the seam an eventual Claude-Code supervisor plugs into unchanged.
@MainActor final class EventBus {
    let stream: AsyncStream<SessionEvent>
    private let continuation: AsyncStream<SessionEvent>.Continuation

    init() {
        (stream, continuation) = AsyncStream.makeStream(of: SessionEvent.self)
    }

    func post(_ event: SessionEvent) { continuation.yield(event) }
}

/// An agent-requested worktree create awaiting the user's yes/no — the synth-app MCP
/// server's approval gate. Nothing happens unless the user clicks Create; `respond`
/// answers the control-socket connection blocked on the answer (called exactly once,
/// always on the main actor).
struct AgentWorktreePrompt: Identifiable {
    let id = UUID()
    let workspace: Workspace
    let branchName: String
    let base: String?           // nil → the repo's default branch; meaningful only for a new branch
    let handoff: String?        // a brief for a fresh Claude session in the new worktree
    let requesterTitle: String? // the asking agent row's title — the prompt's "who"
    let respond: ([String: Any]) -> Void
}

/// How an agent's worktree request started: answered on the spot (error, or the branch
/// is already a row), or pending as a prompt the user must answer (the id cancels it).
enum AgentPromptStart {
    case immediate([String: Any])
    case pending(UUID)
}

/// The escalated sidebar indicator a background session raises as a toast: needs-input is
/// the slate-blue `?` (`Theme.input`), error the terracotta `!` (`Theme.danger`), and — for
/// any live session settling to idle — the green ✓ `done`, a transient toast that
/// dismisses itself.
enum NotifKind: Sendable {
    /// `.neutral` is the app talking about its own work — a housekeeping digest, a
    /// confirmation. It never wears a session's state colour, so green keeps meaning "your
    /// agent finished" and blue keeps meaning "something is blocked on you".
    case input, error, done, undo, neutral
}

/// Which of the three tiers a card belongs to. The tier decides *presence* — chip size, verb
/// weight, padding — never the chassis: one glass card, one corner, one deck under all of them.
/// It is about demand, not volume: colour is decided separately, so a housekeeping nudge can be
/// sticky in neutral ink while a blocked agent is sticky in blue.
enum NotifTier: String, Sendable {
    /// Tier 1. Sticky — something is waiting on you.
    case attention
    /// Tier 3. Self-dismissing — a result you asked for. (Tier 2, the undo window, is `.undo`.)
    case ambient
}

/// The card's one button. Nil means the card has nothing to offer but dismissal.
struct NotifAction: Sendable, Equatable {
    var label: String
    var danger: Bool = false
}

/// One live in-app notification — a background session escalated to a glass toast. `seq` is
/// a monotonic raise counter so same-kind toasts order newest-first (working.html's
/// `notifState` Map value `{ kind, order }`).
struct InAppNotif: Identifiable {
    let id: UUID        // the session id — one toast per session, like working.html
    var kind: NotifKind
    let seq: Int
    /// Display snapshot captured at raise time. A clean exit closes its session right after
    /// the "done" toast goes up (features 2026-07-06), so the card can't count on a live
    /// session to render from.
    let sessionKind: SessionKind
    let title: String
    let colorIndex: Int?
    /// Only the exit-close "done" toast may outlive its session in `notifOrder`; it always
    /// self-dismisses. Every other toast still drops the moment its session vanishes.
    let outlivesSession: Bool
    /// System toasts (no session behind them — e.g. a failed background worktree op)
    /// carry their own verb line and glyph; session toasts leave these nil and derive
    /// both from the session. A system toast persists until clicked.
    var message: String? = nil
    var iconPath: String? = nil

    var tier: NotifTier = .attention
    /// Evidence under the verb line — an exit code, git's own message, a size. Never a
    /// restatement of what the verb already said.
    var sub: String? = nil
    /// The button, and what ⌘↩ fires on the front card.
    var action: NotifAction? = nil
    /// The one undo whose expiry touches the disk: glyph and countdown both go red, so the
    /// eight seconds read as a fuse rather than a receipt.
    var destructive: Bool = false
    /// Whether this card runs a countdown and dismisses itself. Kind alone can't say — an
    /// archive nudge is `.neutral` and sticky, a sweep digest is `.neutral` and transient.
    var drains: Bool = false

    /// Deck precedence (front first). Not severity — what it costs to miss the card.
    ///
    /// `0` **fused**: an undo. Actionable *and* expiring — when the bar drains the option is
    /// gone for good, so nothing sits in front of one while it burns.
    /// `1` **standing**: sticky and asking — needs-input, an error, a failed op, an update
    /// waiting. It never expires and every other surface (sidebar indicator, unread dot) still
    /// carries it, so nothing is lost by ordering these purely by recency.
    /// `2` **receipt**: self-dismissing and asking nothing — a done toast, a digest, a
    /// confirmation. It leaves on its own.
    ///
    /// Errors used to outrank needs-input. That was a severity judgement the deck can't act on:
    /// both are "an agent stopped and wants you", neither is lost by waiting, and ranking them
    /// buried the toast you were *just* nudged about behind one you had already seen — ⌘↩
    /// included, which fires the front card.
    var band: Int { kind == .undo ? 0 : (drains ? 2 : 1) }

    /// A done toast's life, working.html `NOTIF_DONE_MS`. Sticky toasts (input / error)
    /// never read these.
    static let doneLife: TimeInterval = 6
    /// This toast's full life — done toasts use `doneLife`; an undo card overrides it (8s) so
    /// its longer window drains at the right rate.
    var life: TimeInterval = InAppNotif.doneLife
    /// The pausable countdown (working.html: the `.notif__timer` bar IS the timer, so the
    /// drain and the dismissal share one clock). `remaining` banks the life left while
    /// paused; `armedAt` is the start of the current draining stretch, nil while paused.
    var remaining: TimeInterval = doneLife
    var armedAt: Date? = nil

    /// Life left → 1…0, linear — what the countdown bar shows at `now`.
    func timerFraction(at now: Date) -> Double {
        let left = armedAt.map { max(0, remaining - now.timeIntervalSince($0)) } ?? remaining
        return min(1, max(0, left / life))
    }
}

/// Which focus rule a notification follows: `.inApp` is the frontmost case (deck only),
/// `.notificationCenter` the unfocused one (Notification Center on top of the deck). `nil` at
/// a call site means "the real rule" — branch on `NSApp.isActive`; the DEBUG trigger passes an
/// explicit value so both layers are drivable headless (a driven instance isn't reliably frontmost).
enum NotifRoute { case inApp, notificationCenter }

/// Which tab the full-screen Settings page shows: the app itself, or the project you're
/// currently in. Scope is no longer a place in the sidebar — the tree stays live and the
/// project tab follows it (working.html setTab / setProject).
enum SettingsTab: Equatable { case app, project }

/// The appearance choice (working.html's System / Light / Dark segmented control).
enum ThemePref: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

/// Who is running this Synth, resolved once at launch. The author (git identity matched)
/// gets the feedback→worktree loop; everyone else gets a pre-filled email. `SYNTH_AUTHOR=1`
/// / `=0` forces it (the established env-override idiom), else it's the git `user.email`.
enum FeedbackMode {
    case author, email

    static let recipient = "isaac.scarrott11@gmail.com"
    static let authorEmails: Set<String> = ["isaac@holibob.tech", "isaac.scarrott11@gmail.com"]

    static func resolve() -> FeedbackMode {
        switch ProcessInfo.processInfo.environment["SYNTH_AUTHOR"] {
        case "1": return .author
        case "0": return .email
        default:
            let email = GitService.gitUserEmail()?.lowercased() ?? ""
            return authorEmails.contains(email) ? .author : .email
        }
    }
}

/// The durable, observed source of truth. Holds only the low-frequency facts the
/// UI reads: the tree, per-session status, expansion, and the two selection fields
/// (nav cursor + open session) from docs/adr/0005.
@MainActor @Observable final class AppStore {
    var workspaces: [Workspace] = []
    var expanded: Set<UUID> = []
    var navCursor: UUID?
    var openSessionID: UUID?
    /// The still-materialising branch whose "setting up…" skeleton the content pane is
    /// showing. Set the instant a worktree create is requested (the switch rides the
    /// keystroke, not the async checkout) and cleared the moment the user opens anything
    /// else — so a finished checkout resolves in place only while this still points at it,
    /// and otherwise lands as a quiet unread row instead of yanking the viewport
    /// (last-intent-wins). Never persisted; a pending row can't outlive a quit.
    var openSetupBranchID: UUID?
    /// The view stack (016): every session you look at, most recent last, one entry each. A close
    /// that would leave an empty surface pops it instead (Layout.swift restoreLastViewed) — closing
    /// is an undo of an open, so it puts you back where you were. In-memory like working.html's:
    /// the stack is about this sitting, not something to inherit from a previous launch.
    @ObservationIgnored var viewStack: [UUID] = []
    var sidebarCollapsed = false

    /// The layout spine (009): the pane tree filling the content surface. A lone leaf is today's
    /// single-session case; ≥2 leaves is a split. `openSessionID` / `openSetupBranchID` above are
    /// kept mirroring `activePane` (Layout.swift syncActive), so single-session code is untouched.
    var layout: PaneNode?
    /// The one active leaf — the copper ring and the sidebar "you are here" follow it. Never nil
    /// while `layout` is non-nil.
    var activePane: PaneNode?
    /// The durable split held behind a *transient* full-screen (014). Split-creating ops null it,
    /// committing the current view as the new durable.
    var stashedSplit: PaneNode?
    /// The branch whose layout is on screen — the sole persistence scope (014/005). A branch switch
    /// stashes the one you leave (into its Branch.layout) and restores the target's. nil for the
    /// transient, branchless setup skeleton.
    var currentBranchID: UUID?
    /// On-screen frame of every pane / split node in the content coordinate space, reported by the
    /// views each layout pass (ContentPane). The keyboard's spatial focus (focusDir) and resize
    /// (resizeActive) read real geometry from here — the native stand-in for getBoundingClientRect.
    @ObservationIgnored var paneFrames: [UUID: CGRect] = [:]
    /// The drop-zone highlight painted while a sidebar session is dragged over the content (010) —
    /// the region the new pane will occupy, coloured by kind (split / replace / rim / refuse). nil
    /// when no drag is in flight.
    var dropPreview: DropResolution?
    /// The content area's frame in global (screen-window) coordinates, so a sidebar drag can map the
    /// global pointer into content-local space for the drop-zone resolve. Reported by ContentPane.
    @ObservationIgnored var contentGlobalFrame: CGRect = .zero
    /// Each session row / echo tile's global frame, so a drag can tell which row the pointer is over
    /// for the pair-to-split gesture (012). Reported by the sidebar rows + tiles.
    @ObservationIgnored var sessionRowFrames: [UUID: CGRect] = [:]
    /// Each workspace / branch unit's global frame (header + expanded children — the DOM unit a
    /// row drags as), reported by ReorderLift, so the reorder drop-line can be computed at those
    /// levels the way sessionRowFrames serves the session level.
    @ObservationIgnored var reorderUnitFrames: [UUID: CGRect] = [:]
    /// The session row a drag is squarely over (its centre) — pairs on release into a split (012).
    /// Drives the copper `.session--pair-to` highlight. nil when not pairing.
    var pairTargetID: UUID?

    /// Appearance — System follows the OS, Light/Dark pin it (working.html's global-only
    /// theme setting). Persisted to UserDefaults (the native `localStorage`).
    var themePref: ThemePref = (ThemePref(rawValue: UserDefaults.standard.string(forKey: AppStore.themeKey) ?? "") ?? .system) {
        didSet { UserDefaults.standard.set(themePref.rawValue, forKey: AppStore.themeKey) }
    }
    static let themeKey = "synth-theme"
    /// nil = follow the system; otherwise pin light/dark (drives `.preferredColorScheme`).
    var colorSchemeOverride: ColorScheme? {
        switch themePref { case .system: return nil; case .light: return .light; case .dark: return .dark }
    }

    /// Active in-app notifications (working.html `notifState`). Rendered as a stacked deck by
    /// NotificationDeck while Synth is frontmost; the unfocused path goes through Notification
    /// Center instead (NotificationService). The open session is never in here — opening one
    /// clears its toast, mirroring the `.markUnread` open-guard.
    /// Any raise or dismissal reshuffles the deck, which changes which cards are on screen and
    /// so which clocks may run — settling here means no raise site has to remember to.
    var notifs: [InAppNotif] = [] { didSet { settleDrains() } }
    @ObservationIgnored private var notifSeq = 0
    /// How many cards the deck actually shows before the rest fold under "+N"
    /// (NotificationDeck.peekOpacity has one entry per).
    static let notifDeckDepth = 3

    /// One-shot ambient row-pulse tokens (working.html `session--pulse`). A `done` on an
    /// off-screen live session bumps its token; the sidebar row runs a single soft sweep on
    /// change. Keyed by session id — the value only has to *differ* to re-fire.
    var pulseTokens: [UUID: Int] = [:]

    /// Per-type Notification-Center sound toggles (working.html's per-type sound setting).
    /// Persisted to UserDefaults like `themePref`; defaults needs-input ON, error ON, done OFF.
    /// In-app toasts are always silent — this only gates the unfocused NC path.
    var soundNeedsInput = AppStore.loadBoolPref(AppStore.soundInputKey, default: true) {
        didSet { UserDefaults.standard.set(soundNeedsInput, forKey: AppStore.soundInputKey) }
    }
    var soundError = AppStore.loadBoolPref(AppStore.soundErrorKey, default: true) {
        didSet { UserDefaults.standard.set(soundError, forKey: AppStore.soundErrorKey) }
    }
    var soundDone = AppStore.loadBoolPref(AppStore.soundDoneKey, default: false) {
        didSet { UserDefaults.standard.set(soundDone, forKey: AppStore.soundDoneKey) }
    }
    static let soundInputKey = "synth-sound-input"
    static let soundErrorKey = "synth-sound-error"
    static let soundDoneKey  = "synth-sound-done"
    /// UserDefaults' `bool(forKey:)` can't tell "unset" from `false`, so read the object and
    /// fall back to the type's default only when it's genuinely absent.
    static func loadBoolPref(_ key: String, default def: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? def
    }
    static func loadIntPref(_ key: String, default def: Int) -> Int {
        UserDefaults.standard.object(forKey: key) as? Int ?? def
    }

    /// Which project the Settings project-tab last targeted (working.html's localStorage).
    static let settingsProjectKey = "synth-settings-project"
    static func loadSettingsProject() -> UUID? {
        UserDefaults.standard.string(forKey: settingsProjectKey).flatMap(UUID.init)
    }
    static func saveSettingsProject(_ id: UUID?) {
        if let id { UserDefaults.standard.set(id.uuidString, forKey: settingsProjectKey) }
        else { UserDefaults.standard.removeObject(forKey: settingsProjectKey) }
    }

    /// Per-machine MCP server toggles (Settings → MCP servers): which bundled servers are
    /// registered in every managed worktree's agent config. Both ship on — the app-control
    /// server's one mutating verb is approval-gated behind a native prompt, so an agent
    /// holding the tool still can't create a worktree the user didn't click Create on. A flip
    /// re-syncs every worktree's config immediately — disabled means the entry is REMOVED,
    /// so agents don't even see the tools.
    var mcpBrowserEnabled = AppStore.loadBoolPref(AppStore.mcpBrowserKey, default: true) {
        didSet {
            UserDefaults.standard.set(mcpBrowserEnabled, forKey: AppStore.mcpBrowserKey)
            syncAgentBridge()
        }
    }
    var mcpAppEnabled = AppStore.loadBoolPref(AppStore.mcpAppKey, default: true) {
        didSet {
            UserDefaults.standard.set(mcpAppEnabled, forKey: AppStore.mcpAppKey)
            syncAgentBridge()
        }
    }
    static let mcpBrowserKey = "synth-mcp-browser"
    static let mcpAppKey = "synth-mcp-app"

    /// Anonymous usage analytics (Settings → Privacy). On by default, opt-out: flipping it off
    /// tells PostHog to stop sending straight away and stays off across launches. Read at launch
    /// by `Analytics.bootstrap` too, so the very first event already respects the choice.
    var analyticsEnabled = AppStore.loadBoolPref(AppStore.analyticsKey, default: true) {
        didSet {
            UserDefaults.standard.set(analyticsEnabled, forKey: AppStore.analyticsKey)
            Analytics.setOptOut(!analyticsEnabled)
        }
    }
    static let analyticsKey = "synth-analytics-enabled"

    /// Experimental "Tabs" view mode (working.html `data-tabs`). Presentation-only over the same
    /// branch → pane-tree → session store: on, the sidebar drops to two deep (sessions leave the
    /// tree) and the content surface gains one tab strip per branch. OFF by default, and every
    /// tabs-gated behaviour keys off this, so a tabs-off build is byte-for-byte today's. `@Observable`
    /// re-renders the sidebar and content the instant it flips — the lossless toggle, no migration.
    var tabsMode = AppStore.loadBoolPref(AppStore.tabsModeKey, default: false) {
        didSet { UserDefaults.standard.set(tabsMode, forKey: AppStore.tabsModeKey) }
    }
    static let tabsModeKey = "synth-tabs"

    // MARK: Archive sweep settings

    /// Whether the sweeper may reclaim archived worktrees at all. On by default: an archived
    /// worktree the user never returns to is dead disk, and the conditions are conservative
    /// enough (merged, clean, past the grace, held aside another two weeks before real
    /// deletion, branch never touched) to run unattended. `archive_sweeper_kill` is the
    /// emergency stop.
    var archiveSweepEnabled = AppStore.loadBoolPref(AppStore.archiveSweepKey, default: true) {
        didSet { UserDefaults.standard.set(archiveSweepEnabled, forKey: AppStore.archiveSweepKey) }
    }
    static let archiveSweepKey = "synth-archive-sweep"

    /// Days an archived worktree sits untouched before the sweeper will consider it. 0 means
    /// never — the sweeper is off but Archive still works, which is the point of keeping the
    /// two settings apart. Offered as Never / 7 / 14 / 30.
    var archiveGraceDays = AppStore.loadIntPref(AppStore.archiveGraceKey, default: 7) {
        didSet { UserDefaults.standard.set(archiveGraceDays, forKey: AppStore.archiveGraceKey) }
    }
    static let archiveGraceKey = "synth-archive-grace-days"

    /// Evaluate every condition, log the verdict, delete nothing. Defaults ON for the dev
    /// channel, so the author's own worktrees are never the test subjects.
    var archiveDryRun = AppStore.loadBoolPref(AppStore.archiveDryRunKey, default: isDevChannel) {
        didSet { UserDefaults.standard.set(archiveDryRun, forKey: AppStore.archiveDryRunKey) }
    }
    static let archiveDryRunKey = "synth-archive-dry-run"

    /// The grace, in seconds, with the harness override applied. Waiting seven days is not a
    /// test, so `app/harness/` can compress the clock the same way `SYNTH_STATE_DIR` redirects
    /// the snapshot. Read fresh so a test can set it between ticks.
    var archiveGraceSeconds: TimeInterval {
        if let raw = ProcessInfo.processInfo.environment["SYNTH_ARCHIVE_GRACE_SECONDS"],
           let secs = TimeInterval(raw) { return secs }
        return TimeInterval(archiveGraceDays) * 86_400
    }

    /// Draggable sidebar width, clamped and persisted (working.html's `--sidebar-w`).
    var sidebarWidth: CGFloat = {
        let w = UserDefaults.standard.double(forKey: AppStore.sidebarWidthKey)
        return (w >= Theme.sidebarMinWidth && w <= Theme.sidebarMaxWidth) ? CGFloat(w) : Theme.sidebarWidth
    }() {
        didSet { UserDefaults.standard.set(Double(sidebarWidth), forKey: AppStore.sidebarWidthKey) }
    }
    static let sidebarWidthKey = "synth-sidebar-w"

    /// True only while the keyboard is driving nav — gates the selection ring
    /// (mousemove clears it), mirroring working.html's `.kbd` class.
    var keyboardActive = false

    /// One-shot: the next terminal mount skips the focus-grab `TerminalHost` normally does on
    /// open. A sidebar click opens the session in the content pane but keeps the keyboard on the
    /// tree (working.html handToSidebar), and `TerminalHost`'s mount-focus would fight that — so
    /// `openFromSidebar` raises this and the mount consumes it. Any dive-into-content path
    /// (`focusContent`) clears it, so a normal open focuses the shell as before.
    var suppressShellFocusOnOpen = false

    /// True from the moment a keystroke hides the pointer (`NSCursor.setHiddenUntilMouseMoves`)
    /// until it next genuinely moves. SwiftUI's `onHover`/`onContinuousHover` re-fire from mere
    /// hit-testing whenever a view is laid out under the pointer's last known position — scrolling
    /// the palette list or the sidebar tree during keyboard nav counts, even though the pointer,
    /// hidden and stationary, never moved. Hover-driven state changes must check this first so a
    /// stale, invisible pointer position can't relocate the selection out from under the keyboard.
    var pointerStale = false

    /// Drag-to-reorder (F2): the row being dragged (nil = none) and its live vertical
    /// offset within its slot, so the lifted row tracks the pointer while its siblings
    /// shift. `reorderScrollNonce` is bumped on every reorder step (drag + ⇧J/⇧K) so the
    /// sidebar can keep the moving row in view.
    var draggingRowID: UUID?
    var dragOffset: CGFloat = 0
    var reorderScrollNonce = 0
    /// The copper insertion line of a reorder drag, in global coords (working.html `.drop-line`):
    /// the list never reshuffles mid-drag, so this line IS the drop preview — it marks the slot
    /// the release will land in. nil = hidden: no drag in flight, or the pointer rests in the
    /// dragged unit's own slot (the faded source row already marks that slot).
    var reorderDropLine: CGRect?
    /// The vertical copper insertion line of a tab-strip reorder drag (tabs mode), in global coords —
    /// the horizontal twin of `reorderDropLine`. nil = hidden.
    var tabReorderLine: CGRect?
    /// The tab strip's global frame (tabs mode) — a tab drag only reorders while the pointer is over
    /// it; released anywhere else (a pane handles its own split; the sidebar / off-window) it cancels.
    @ObservationIgnored var tabStripFrame: CGRect = .zero
    /// A free-floating drag ghost for a session drag (010/012) — the session tracks the cursor like
    /// a VS Code file drag while the source row dims in place. nil when no session drag is in flight;
    /// `dragGhostPoint` is the cursor in global (window) coordinates.
    var dragGhostSessionID: UUID?
    var dragGhostPoint: CGPoint = .zero

    /// Sheet drivers.
    var creatingWorktreeIn: Workspace?

    /// Agent-requested worktree prompts (synth-app MCP), oldest first — the ⌘K confirm
    /// frame shows the head; resolving or cancelling it reveals the next.
    var agentPrompts: [AgentWorktreePrompt] = []

    /// The agent prompt (if any) currently driving the palette's confirm frame — set by
    /// `presentAgentPrompt`, cleared the moment it's resolved. Closing the palette while
    /// this is non-nil (Esc, ⌘K, backdrop click) declines that prompt, same as before.
    var presentedAgentPromptID: UUID?

    /// The feedback sheet (⌘⇧F). `feedbackDraft` persists an unsent gripe across reopens,
    /// like working.html. `feedbackTitle` is the author-only name that becomes the
    /// `feedback/<slug>` branch (email mode never shows it). `feedbackMode` is resolved
    /// once at launch (see init).
    var feedbackOpen = false
    var feedbackDraft = ""
    var feedbackTitle = ""
    @ObservationIgnored var feedbackMode: FeedbackMode = .email

    /// The row-action menu currently open (nil = none). Clearing it always drops any
    /// in-progress delete confirmation.
    var activeMenu: ActiveMenu? { didSet { if activeMenu == nil { menuConfirming = false } } }

    /// The open menu is showing its two-step delete confirm (working.html `.menu.confirming`).
    /// Lifted out of RowMenu so the keyboard can drive it: `d` opens straight here, ↵ commits.
    var menuConfirming = false

    /// The sidebar row being renamed inline, and its live text — working.html's
    /// contentEditable name label. nil = nothing renaming.
    var renamingRowID: UUID?
    var renameText = ""

    /// The ⌘K palette (nil = closed). Every frame builder captures the model strongly
    /// (model → stack → PaletteFrame.build → model), so dropping the reference can't free
    /// it — break that cycle on every close/replace here, or each ⌘K, kebab, delete and
    /// ⌘N leaks a whole PaletteModel plus its branch cache and captured session graphs.
    var palette: PaletteModel? {
        didSet { if oldValue !== palette { oldValue?.stack = [] } }
    }

    /// The ⌘? keyboard-shortcuts sheet (working.html's shortcutsEl).
    var shortcutsOpen = false
    /// The scratch terminal (⌘⇧T) — a throwaway shell over the app, deliberately not a Session:
    /// no row, no status, no roll-up, nothing persisted. Nil unless one is up. See ScratchTerminal.
    var scratch: ScratchTerminal?
    /// Dismissing it while a job holds the foreground confirms first (ADR-0013).
    var scratchConfirmOpen = false
    /// The selected category in the shortcuts sheet's sidebar — driven by ↑/↓ / j/k while open.
    var shortcutsCategory = 0

    /// The in-app changelog (Synth → Changelog menu item). Read-only, Esc-dismissed like
    /// the shortcuts sheet; app-only, so no working.html twin.
    var changelogOpen = false
    /// The selected release in the changelog's version rail — driven by ↑/↓ / j/k while open,
    /// the same keyboard-first idiom as the shortcuts sheet's category sidebar.
    var changelogVersion = 0

    /// Full-screen Settings page: a mode layered over the same shell (working.html's
    /// `.app.settings`). The tree stays live throughout; a tab in the pane head picks app
    /// vs the current project.
    var settingsOpen = false
    var settingsTab: SettingsTab = .app
    /// The project the project-tab targets — remembered across visits (working.html
    /// setProject / localStorage). The tree retargets it; entering from a project presets it.
    var settingsProjectID: UUID? = AppStore.loadSettingsProject() {
        didSet { AppStore.saveSettingsProject(settingsProjectID) }
    }

    /// A project's setup script is its DELTA — the extra lines that run AFTER the shared
    /// base (globalScript). Empty = pure inheritance. `wsSkipScript` is the rare opt-out:
    /// run only the project's lines, not the shared base. Design surface only, no runner yet.
    var wsSkipScript: [UUID: Bool] = [:]
    var globalScript = ""
    var wsScripts: [UUID: String] = [:]
    let wsScriptPlaceholder = """
    #!/usr/bin/env bash

    # No extra setup for this workspace yet.
    """

    /// Default flags passed to an agent's binary when one of its sessions starts, per agent.
    /// The raw string is the source of truth, so ANY flag the agent accepts works. A project's
    /// flags are a TAIL appended after these shared ones (working.html's layered model), so the
    /// shell's last-wins resolves any repeat; an empty project tail runs the shared flags alone.
    ///
    /// Both ship empty — each agent's own configured defaults are what a fresh install runs,
    /// and skipping permission prompts is a choice the user makes here, not one Synth makes
    /// for them.
    var globalAgentFlags: [AgentID: String] = [
        .claudeCode: "",
        .opencode: "",
    ]
    var wsAgentFlags: [UUID: [AgentID: String]] = [:]

    /// The effective flags for an agent in a project — the shared base with the project's
    /// tail appended (working.html's layered model). The shell parses the line left-to-right,
    /// so a tail flag that repeats a base one wins naturally; empty tail = the base alone.
    func agentFlags(_ agent: AgentID, for workspace: Workspace?) -> String {
        let base = (globalAgentFlags[agent] ?? "").trimmingCharacters(in: .whitespaces)
        let tail = (workspace.flatMap { wsAgentFlags[$0.id]?[agent] } ?? "")
            .trimmingCharacters(in: .whitespaces)
        return [base, tail].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// The ordered session set every new worktree starts with (working.html TPL_KINDS /
    /// globalTpl). Order is creation order — the first entry is the session that opens.
    var globalSessionTemplate: [SessionTemplateEntry] = []
    var wsSessionTemplates: [UUID: [SessionTemplateEntry]] = [:]

    /// The effective template for a project — the shared base sessions with the project's
    /// own added after (working.html's layered model). The first entry overall is the one
    /// that opens; an empty project list means "just the shared set".
    func sessionTemplate(for workspace: Workspace?) -> [SessionTemplateEntry] {
        globalSessionTemplate + (workspace.flatMap { wsSessionTemplates[$0.id] } ?? [])
    }

    /// Session ids with a LIVE coding agent attached THIS run — asserted only by the supervisor
    /// seam (agent-start / agentSessionCaptured; cleared by agent-end / process exit).
    /// A persisted `.agent` kind is NOT liveness: a restored row whose resume fails drops to a
    /// bare shell, and pasting a browser comment there (page-controlled text submitted with
    /// Enter) would hand the page shell execution. Comment delivery gates on this set
    /// (CommentModeController.deliver).
    private(set) var liveAgentIDs: Set<UUID> = []
    /// True exit statuses reported over the hook socket (`.exitCodeReported`), keyed by
    /// session, consumed by the `.exited` that follows moments later.
    @ObservationIgnored private var reportedExitCodes: [UUID: Int32] = [:]
    /// The in-app browser each terminal/Claude session sends its clicked loopback links to,
    /// so reclicking a dev-server URL reuses one row instead of spawning per click. Keyed by
    /// source session; the entry (and any pointing at a closed browser) is dropped on close.
    @ObservationIgnored private var linkBrowsers: [UUID: UUID] = [:]

    func isLiveAgent(_ id: UUID) -> Bool { liveAgentIDs.contains(id) }

    /// Tear down a session's supervision. Safe to call for a row that never hosted an agent
    /// (nil id) or whose supervisor never attached — both are no-ops.
    private func detachSupervisor(_ agent: AgentID?, _ session: UUID) {
        guard let agent else { return }
        AgentRegistry.supervisor(agent)?.detach(session: session)
    }

    /// The live agent hosted by `session`, if any — the supervisor that can be handed text.
    func liveSupervisor(for session: Session) -> (any AgentSupervisor)? {
        guard isLiveAgent(session.id), let agent = session.kind.agentID else { return nil }
        return AgentRegistry.supervisor(agent)
    }

    let bus = EventBus()
    let hookServer: HookServer
    /// Stage-two control socket (ADR-0011): browser.list / browser.create for the
    /// bundled MCP server. Request/response, so separate from the one-way hook socket.
    @ObservationIgnored private var controlServer: ControlServer!

    /// The single live store. `AppDelegate.applicationShouldTerminate` reaches it here to gate
    /// quit on busy work — it runs outside SwiftUI's environment and can't `@Environment` it in.
    /// Weak: the store's lifetime is the app's; this only borrows it.
    @ObservationIgnored static weak var shared: AppStore?

    init() {
        feedbackMode = FeedbackMode.resolve()
        hookServer = HookServer(bus: bus)
        TerminalManager.shared.bus = bus
        BrowserManager.shared.bus = bus
        TerminalManager.shared.hookSocketPath = hookServer.socketPath
        AgentRegistry.startSupervisors(bus: bus)
        HookEnvironment.setup()
        hookServer.start()
        Task { [weak self] in
            guard let self else { return }
            for await event in self.bus.stream { self.apply(event) }
        }
        if let state = PersistenceStore.load() { restore(from: state) }
        // Stage two (ADR-0011): advertise this instance, listen for control verbs,
        // and install/register the bundled browser MCP server.
        InstanceRegistry.shared.start()
        controlServer = ControlServer(store: self)
        controlServer.start()
        MCPInstaller.refreshServerInstall()
        syncAgentBridge()
        startAutosave()
        refreshPullRequests()
        // The done-toast drain follows focus as well as hover: routeTransition raises the
        // deck even unfocused, and the clock must not run while nobody can see it.
        for (name, active) in [(NSApplication.didBecomeActiveNotification, true),
                               (NSApplication.didResignActiveNotification, false)] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.noteAppActive(active) }
            }
        }
        AppStore.shared = self
    }

    /// Keep the instance file's worktreePaths and every worktree's .mcp.json current.
    /// Runs at init, on the autosave cadence, and when an MCP toggle flips (all skip
    /// unchanged inputs), so no workspace/branch mutation site can forget it — the
    /// autosave model.
    private func syncAgentBridge() {
        let paths = workspaces.flatMap { $0.branches.map(\.worktreeURL.path) }
        // The registry keeps ALL paths, archived included: it is how a sibling Synth learns
        // this instance still manages that folder, and the sibling's sweeper refuses to touch
        // anything another live instance claims. Dropping archived paths here would fail that
        // check open in exactly the case it exists for.
        InstanceRegistry.shared.update(worktreePaths: paths)
        // The config writer takes only live rows: an archived worktree is one the user has
        // stopped working in, and writing into it every 4s would keep dirtying a folder the
        // sweeper is trying to certify as clean.
        let live = workspaces.flatMap { $0.branches.filter { !$0.isArchived }.map(\.worktreeURL.path) }
        MCPInstaller.syncWorktreeConfigs(live, servers: [
            "synth-browser": mcpBrowserEnabled,
            "synth-app": mcpAppEnabled,
        ])
    }

    // MARK: Bus → store

    private func apply(_ event: SessionEvent) {
        // The scratch terminal's session is never in the tree, so every event it raises would
        // fall through below as an unknown id. It gets first refusal.
        if applyScratch(event) { return }
        switch event {
        case let .statusChanged(id, status):
            guard let s = session(id) else { break }
            // A `needsInput` (?) is only legitimate mid-turn: a question / permission / plan
            // block always interrupts work in flight. Claude's ambient "waiting for your input"
            // notification instead fires at end-of-turn and races the `Stop`→idle that ends it —
            // each hook is a separate process applied on its own Task, so order isn't guaranteed.
            // Requiring a still-live prior state drops the nudge once the turn has settled, so the
            // finish is order-independent: whichever of idle/needsInput lands last, the row ends
            // idle. Genuine blocks are preceded by UserPromptSubmit/PostToolUse→working, so the ?
            // still lights.
            if status == .needsInput, !s.status.isLive { break }
            let prev = s.status
            s.status = status
            routeTransition(id, prev: prev, next: status)
        case let .titleChanged(id, title):
            // Claude Code's ai-title, refined each turn — but never clobber a hand-picked name.
            if let s = session(id), !s.titleIsCustom, s.title != title { s.title = title }
        case let .titleReset(id):
            // Keep a hand-picked name; otherwise fall back to the agent's neutral default until
            // the new conversation generates its own title (arriving as .titleChanged).
            if let s = session(id), !s.titleIsCustom { s.title = s.spawnedKind.tplStart }
        case let .exitCodeReported(id, code):
            // Late socket events can arrive after the row closed (closeSession already ran);
            // don't repopulate a map nothing will drain — .exited's removeValue is unreachable
            // once session(id) is gone.
            if session(id) != nil { reportedExitCodes[id] = code }
        case let .exited(id, code):
            guard let s = session(id) else { break }
            let prev = s.status
            liveAgentIDs.remove(id)
            detachSupervisor(s.kind.agentID ?? s.spawnedKind.agentID, id)
            // The PTY's own code is blind on macOS — libghostty wraps the child in `login`,
            // which exits 0 whatever really happened — so prefer the code the session
            // reported over the hook socket just before dying. The user-interrupt statuses
            // (130 SIGINT, 143 SIGTERM) close clean, the same neutrality the per-command
            // reporter applies: a Ctrl-C'd claude mustn't die as an error row.
            let real = reportedExitCodes.removeValue(forKey: id) ?? code ?? 0
            if real == 0 || real == 130 || real == 143 {
                // A clean exit ends the session outright — `exit` in a shell, quitting a
                // spawned claude (which execs, so this is its exit too). Notify first: both
                // notification paths need the live row (features 2026-07-06).
                s.status = .exited(real)
                routeTransition(id, prev: prev, next: .exited(real), closing: true)
                closeSession(s)
            } else {
                // A failure keeps its row — the error should be seen and inspectable,
                // not vanish with the process.
                s.status = .error
                routeTransition(id, prev: prev, next: .error, detail: "exit \(real)")
            }
        case let .kindChanged(id, kind):
            guard let s = session(id) else { break }
            // A browser session never runs an agent, so an agent lifecycle signal carrying its
            // id is spurious — applying it would flip the pane to a terminal while
            // BrowserManager still holds the browser controller, desyncing the two and
            // wedging ⌘K on that row.
            if s.spawnedKind == .browser { break }
            // A session spawned as an agent never reverts to a plain terminal: it exec'd the
            // agent, so an agent-end is either the process about to exit (the child-exited
            // signal closes the row moments later) or a /clear's end/start pair — neither
            // should blip the kind.
            if kind == .terminal, s.spawnedKind.isAgent {
                liveAgentIDs.remove(id)
                detachSupervisor(s.spawnedKind.agentID, id)
                break
            }
            s.kind = kind
            // The supervisor seam's agent lifecycle: agent-start posts .agent(id), agent-end
            // posts .terminal. Liveness is NOT asserted here — an agent that has been *launched*
            // may not yet be reachable, and delivering into a not-yet-listening agent silently
            // drops the text. Its supervisor posts `.agentReady` when it truly is.
            if let agent = kind.agentID {
                AgentRegistry.supervisor(agent)?.attach(session: id)
            } else {
                liveAgentIDs.remove(id)
                detachSupervisor(s.spawnedKind.agentID, id)
            }
        case let .markUnread(id): if openSessionID != id { session(id)?.unread = true }
        case let .agentReady(id):
            // A readiness signal racing a row close must not re-add a UUID nothing removes.
            if session(id) != nil { liveAgentIDs.insert(id) }
        case let .agentSessionCaptured(id, agentSessionID):
            guard let s = session(id) else { break }
            if s.agentSessionID != agentSessionID { s.agentSessionID = agentSessionID }
            liveAgentIDs.insert(id)
        case let .browserNavigated(id, url):
            guard let s = session(id) else { return }
            s.browserURL = url
            if !s.titleIsCustom { s.title = url.browserHostPath }
            noteBrowserRecent(url, for: s)
        case let .browserPageTitled(id, title):
            guard let s = session(id), !title.isEmpty else { return }
            // The page title is the row's auto-name — .browserNavigated already set the
            // host+path fallback, which stands until this arrives (or for untitled pages).
            if !s.titleIsCustom, s.title != title { s.title = title }
            // Also attach it to the current URL's recents entry (the "name" column).
            guard let url = s.browserURL, let br = branch(of: s),
                  let i = br.browserRecents.firstIndex(where: { $0.url == url.absoluteString })
            else { return }
            if br.browserRecents[i].title != title { br.browserRecents[i].title = title }
        case let .browserPopupRequested(id, url):
            guard let s = session(id) else { return }
            // A popup opened from an owned browser inherits the owner (stage four) —
            // it's the same claude's surface, just a second page. Owned means
            // agent-driven (a CDP click looks like a real one), so it announces via
            // the unread bullet; a popup from a browser the user drives opens in front.
            let popupOwner = owner(of: s)
            newBrowser(in: branch(of: s), at: url, ownedBy: popupOwner, focus: popupOwner == nil)
        case let .openURLRequested(sourceID, url):
            openTerminalLink(url, from: sourceID)
        }
    }

    /// A clicked terminal link. Scheme + host decide the target: a loopback dev-server page
    /// opens in the in-app browser (owned by the clicking Claude session, reused across
    /// clicks) so the agent can drive the same page the human sees. Every other web URL and
    /// every non-web scheme goes to the OS default handler — that keeps the user's real
    /// auth/extensions and matches every other macOS terminal (an embedded browser is a
    /// fresh, logged-out profile, wrong for github.com/stripe.com and blank for mailto:).
    func openTerminalLink(_ url: URL, from sourceID: UUID?) {
        let scheme = url.scheme?.lowercased()
        guard scheme == "http" || scheme == "https", url.isLoopbackHost else {
            NSWorkspace.shared.open(url); return
        }
        let source = sourceID.flatMap(session) ?? openSessionID.flatMap(session)
        // Reuse this session's link browser if it's still alive — reclicking a dev-server URL
        // must not mint a row per click.
        if let srcID = source?.id, let bid = linkBrowsers[srcID], let existing = session(bid) {
            existing.browserURL = url
            BrowserManager.shared.existing(bid)?.navigate(to: url)
            open(existing)
            return
        }
        // Only an agent session can own a browser; a plain terminal spawns an unowned one.
        let owner = (source?.kind.isAgent ?? false) ? source : nil
        guard let browser = newBrowser(in: source.flatMap { branch(of: $0) },
                                       at: url, ownedBy: owner, focus: true) else {
            NSWorkspace.shared.open(url); return   // no branch to host it — don't lose the click
        }
        if let srcID = source?.id { linkBrowsers[srcID] = browser.id }
    }

    /// Front of the branch's Recent list, deduped by URL (keeping the known title), capped at 5.
    /// Hostless URLs (about:blank, data:) are engine plumbing, not destinations.
    private func noteBrowserRecent(_ url: URL, for session: Session) {
        guard url.host != nil, let br = branch(of: session) else { return }
        let key = url.absoluteString
        var recents = br.browserRecents
        let title = recents.first(where: { $0.url == key })?.title ?? ""
        recents.removeAll { $0.url == key }
        recents.insert(BrowserRecent(url: key, title: title), at: 0)
        br.browserRecents = Array(recents.prefix(5))
    }

    // MARK: Notifications (working.html notifyOnTransition → the in-app deck / Notification Center)

    /// A background session's status transition, turned into a notification — the single seam
    /// terminals and Claude both reach (`term-*` and Claude signals alike flow through `apply`).
    /// The in-app deck is always raised; focus only gates Notification Center: frontmost → the
    /// deck alone, unfocused → Notification Center *as well*, with the toast waiting in the
    /// deck when focus returns (a banner that slid by while you were away leaves no trace).
    /// The open session never notifies in-app (the user is looking at it), but open ≠ seen
    /// when Synth isn't frontmost — unfocused, it goes to Notification Center like any other.
    /// `force` overrides the focus rule for the DEBUG trigger.
    /// `closing` marks the exit-close transition: the caller removes the row right after,
    /// so the raised done toast must outlive its session.
    /// Harness seam (`SYNTH_AUTOMATION`, ControlServer `automation.notifRoute`): pin the focus
    /// rule a transition follows. Focus normally decides, and a driven instance never holds focus
    /// on a live desktop — other apps take it straight back — so the frontmost (deck-only) branch
    /// is otherwise untestable.
    @ObservationIgnored var automationNotifRoute: NotifRoute?

    /// `detail` is the evidence line the card carries under its verb — currently the real exit
    /// status behind an error, which the app already knows and used to make you jump to find.
    func routeTransition(_ id: UUID, prev: SessionStatus, next: SessionStatus, force: NotifRoute? = nil,
                         closing: Bool = false, detail: String? = nil) {
        let route = force ?? automationNotifRoute
        let toNC = route.map { $0 == .notificationCenter } ?? !NSApp.isActive
        if openSessionID == id, !toNC { clearNotif(id); return }
        switch next.rollup {
        case .input, .error:
            let kind: NotifKind = next.rollup == .error ? .error : .input
            if openSessionID != id {
                session(id)?.unread = true   // working.html notify() marks the row unread too
                raiseInApp(id, kind, sub: detail)
            }
            if toNC { NotificationService.shared.postAttention(store: self, id: id, kind: kind) }
        case .idle where prev.rollup != .idle:
            // A live session settling to idle off-screen → "done": the unread bullet, one
            // soft row sweep, and a transient toast that dismisses itself (a finished session
            // should be seen, but asks for nothing). Unfocused, a banner rides on top.
            if openSessionID != id {
                session(id)?.unread = true   // working.html done also marks the row unread
                pulseTokens[id, default: 0] += 1
                raiseInApp(id, .done, outlivesSession: closing)
            }
            if toNC { NotificationService.shared.postDone(store: self, id: id) }
        default:
            clearNotif(id)   // work / run (and idle-from-idle) clear any standing toast
        }
    }

    /// Raise (or re-raise, bumping it to newest) a background session's toast. A done toast
    /// asks for nothing, so it dismisses itself; the seq check keeps the timer from killing
    /// a newer toast the same session raised in the meantime.
    private func raiseInApp(_ id: UUID, _ kind: NotifKind, outlivesSession: Bool = false,
                            sub: String? = nil) {
        guard let s = session(id) else { return }
        notifSeq += 1
        cancelDismiss(id)   // the replaced toast's clock must not outlive it
        notifs.removeAll { $0.id == id }
        notifs.append(InAppNotif(id: id, kind: kind, seq: notifSeq,
                                 sessionKind: s.kind, title: s.title,
                                 colorIndex: branch(of: s).flatMap { workspace(of: $0) }?.colorIndex,
                                 outlivesSession: outlivesSession,
                                 tier: kind == .done ? .ambient : .attention,
                                 sub: sub, action: NotifAction(label: "Open"),
                                 drains: kind == .done))
    }

    /// True while the pointer rests on the deck: every done toast's drain (bar and dismissal
    /// alike) holds still, single card or fanned (working.html `.notifs:hover .notif__timer
    /// { animation-play-state: paused }`).
    var notifDrainPaused = false
    /// The drain's second brake: Synth not frontmost. A done toast raised (or still up)
    /// unfocused waits in the deck fully banked — standing there for the return is the point
    /// of raising it at all — and gets its seconds on screen once focus is back. Driven by
    /// did{Become,Resign}Active (wired in `init`); starts unfocused, the first activation
    /// releases it.
    @ObservationIgnored private var notifDrainUnfocused = true
    private var drainHeld: Bool { notifDrainPaused || notifDrainUnfocused }
    /// The drain's third brake, and the only per-card one: the card is folded under "+N". A
    /// countdown you cannot see is not being read — the same reason hovering pauses it — and a
    /// receipt with no other surface (a sweep digest, a "Handed to Mail") that expires while
    /// buried delivered nothing at all. Buried cards wait banked and get their seconds once the
    /// cards ahead of them clear.
    private func isBuried(_ id: UUID) -> Bool {
        guard let i = notifOrder.firstIndex(where: { $0.id == id }) else { return false }
        return i >= Self.notifDeckDepth
    }
    @ObservationIgnored private var settlingDrains = false
    /// One armed dismissal per toast, sleeping exactly what its bar shows.
    @ObservationIgnored private var notifDismissTasks: [UUID: Task<Void, Never>] = [:]

    private func cancelDismiss(_ id: UUID) {
        notifDismissTasks[id]?.cancel()
        notifDismissTasks[id] = nil
    }

    /// Start a done toast draining: stamp `armedAt` and sleep out its banked `remaining`.
    /// Under any held brake (deck hovered, Synth unfocused, card buried under "+N") the toast
    /// waits fully banked — release arms it.
    private func armDoneToast(_ id: UUID) {
        cancelDismiss(id)
        guard let i = notifs.firstIndex(where: { $0.id == id && $0.drains }) else { return }
        guard !drainHeld, !isBuried(id) else { notifs[i].armedAt = nil; return }
        notifs[i].armedAt = Date()
        let remaining = notifs[i].remaining
        let seq = notifs[i].seq
        notifDismissTasks[id] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(remaining))
            guard !Task.isCancelled, let self else { return }
            self.notifDismissTasks[id] = nil
            // An undo that drains out commits its removal; every other done toast just clears.
            let action = self.undoActions[id]
            self.undoActions[id] = nil
            self.notifs.removeAll { $0.id == id && $0.seq == seq }
            action?.commit()
        }
    }

    /// Commit every pending undo now, exactly as its window elapsing would. The drain is held
    /// while the app is unfocused (`notifDrainUnfocused` starts true), which is right for a user
    /// — an undo card should still be there when you come back — and means a headless harness
    /// would otherwise wait forever for a soft-delete to become real.
    func drainPendingUndos() {
        for notif in notifs where notif.kind == .undo { commitUndo(notif.id) }
    }

    func setNotifDrainPaused(_ paused: Bool) {
        guard paused != notifDrainPaused else { return }
        applyDrainBrake { notifDrainPaused = paused }
    }

    /// The focus brake, drivable. A headless instance is never frontmost, so the drain is held
    /// forever and no self-dismissing card can be observed dismissing itself — a harness has to
    /// be able to say "focus came back" the same way it says "the undo window elapsed".
    func setAutomationAppActive(_ active: Bool) { noteAppActive(active) }

    /// App (de)activation flips the focus brake through the same bank/arm transition as hover.
    private func noteAppActive(_ active: Bool) {
        guard notifDrainUnfocused == active else { return }
        applyDrainBrake { notifDrainUnfocused = !active }
    }

    /// Flip one brake and settle the clocks. A flip that doesn't change the combined hold (e.g.
    /// unhover while still unfocused) touches nothing.
    private func applyDrainBrake(_ flip: () -> Void) {
        let wasHeld = drainHeld
        flip()
        guard drainHeld != wasHeld else { return }
        settleDrains()
    }

    /// Every draining card re-settled against its brakes: one that should not be running banks
    /// what is left of its life and drops its dismissal, one that should be starts a fresh
    /// stretch. The one place a countdown starts or stops, so hover, focus, burial and a
    /// reshuffled deck all reach it the same way.
    private func settleDrains() {
        guard !settlingDrains else { return }
        settlingDrains = true
        defer { settlingDrains = false }
        let now = Date()
        for id in notifs.filter(\.drains).map(\.id) {
            guard let i = notifs.firstIndex(where: { $0.id == id }) else { continue }
            let shouldRun = !drainHeld && !isBuried(id)
            if let armed = notifs[i].armedAt, !shouldRun {
                notifs[i].remaining = max(0, notifs[i].remaining - now.timeIntervalSince(armed))
                notifs[i].armedAt = nil
                cancelDismiss(id)
            } else if notifs[i].armedAt == nil, shouldRun {
                armDoneToast(id)
            }
        }
    }

    /// Drop a session's toast (opening it, or a work/run/idle transition off it).
    func clearNotif(_ id: UUID) {
        cancelDismiss(id)
        notifActions[id] = nil
        notifs.removeAll { $0.id == id }
    }

    /// What a system card's button does. Session cards jump and undo cards undo, both derivable;
    /// these carry their own verb (Retry, Review, Open), so the closure rides alongside the card.
    @ObservationIgnored private var notifActions: [UUID: @MainActor () -> Void] = [:]

    /// The card's primary action — its button, a click on its body, and ⌘↩ on the front card all
    /// land here, so the three can never mean different things.
    func runNotifAction(_ id: UUID) {
        guard let n = notifs.first(where: { $0.id == id }) else { return }
        if n.kind == .undo { performUndo(id); return }
        if let run = notifActions[id] { clearNotif(id); run(); return }
        if let s = session(id) { jump(to: s); return }
        clearNotif(id)
    }

    /// The × — always "drop this card", never the action. Until now a click on a session card
    /// jumped and a click on a session-less one discarded: same gesture, opposite outcome, and
    /// nothing on the card to tell them apart. On an undo card dismissing means "let it stand",
    /// which is exactly what its countdown draining out already does.
    func dismissNotif(_ id: UUID) {
        guard let n = notifs.first(where: { $0.id == id }) else { return }
        if n.kind == .undo { commitUndo(id); return }
        clearNotif(id)
    }

    /// Commit one parked removal now, exactly as its window elapsing would.
    private func commitUndo(_ id: UUID) {
        cancelDismiss(id)
        let action = undoActions[id]
        undoActions[id] = nil
        notifs.removeAll { $0.id == id }
        action?.commit()
    }

    /// A background worktree op failed after its row already changed — raise a persistent
    /// system toast (no session behind it; it stays until clicked, never self-dismisses).
    /// Unfocused, Notification Center is alerted too, and the in-app card still waits so
    /// the failure is there when focus returns. The full git message goes to the log —
    /// the card is one line.
    func raiseWorktreeError(_ verb: String, branch: String, workspace: String, details: String,
                            retry: (@MainActor () -> Void)? = nil) {
        NSLog("Synth: %@ (%@ · %@): %@", verb, branch, workspace, details)
        notifSeq += 1
        let id = UUID()
        // Git's reason goes on the card — the thing you would otherwise have gone to the log
        // for. Not its *first* line: `git worktree add` narrates progress on stdout
        // ("Preparing worktree…") and puts the reason on stderr, so the first line is chatter
        // and the fatal is what matters. The full text still goes to the log.
        let lines = details.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let reason = lines.first { $0.hasPrefix("fatal:") || $0.hasPrefix("error:") } ?? lines.last
        notifs.append(InAppNotif(id: id, kind: .error, seq: notifSeq,
                                 sessionKind: .terminal, title: "\(branch) · \(workspace)",
                                 colorIndex: nil, outlivesSession: true,
                                 message: verb, iconPath: Phosphor.branch,
                                 tier: .attention, sub: reason,
                                 action: retry == nil ? nil : NotifAction(label: "Retry")))
        if let retry { notifActions[id] = retry }
        if !NSApp.isActive {
            NotificationService.shared.postSystemError(title: verb,
                                                       body: "\(branch) · \(workspace)\n\(details)")
        }
    }

    /// Active toasts, most-urgent first: a burning undo, then standing asks, then receipts —
    /// newest first inside each band (`InAppNotif.band`, working.html `notifOrder`). Drops any
    /// whose session vanished (except the self-dismissing exit-close done toast) or is now the
    /// open one.
    var notifOrder: [InAppNotif] {
        notifs.filter { $0.id != openSessionID && (session($0.id) != nil || $0.outlivesSession) }.sorted { a, b in
            if a.band != b.band { return a.band < b.band }
            return a.seq > b.seq
        }
    }

    /// The ⌘↩ jump target — the most-urgent toast, or nil when the deck is empty (so the chord
    /// stays free otherwise, working.html `notifTop`).
    var topNotif: InAppNotif? { notifOrder.first }

    /// ⌘↩ fires whatever the front card's own button says — Undo, Open, Retry, Review — or, on a
    /// card with nowhere to go, dismisses it.
    func jumpToTopNotif() {
        guard let n = topNotif else { return }
        runNotifAction(n.id)
    }

    // MARK: Lookups

    var openSession: Session? { openSessionID.flatMap(session) }

    /// The branch whose setup skeleton the content pane is showing, or nil.
    var openSetupBranch: Branch? {
        guard let id = openSetupBranchID else { return nil }
        for ws in workspaces {
            if let br = ws.branches.first(where: { $0.id == id }) { return br }
        }
        return nil
    }

    func session(_ id: UUID) -> Session? {
        for ws in workspaces {
            for br in ws.branches {
                if let s = br.sessions.first(where: { $0.id == id }) { return s }
            }
        }
        return nil
    }

    func branch(of session: Session) -> Branch? {
        for ws in workspaces {
            for br in ws.branches where br.sessions.contains(where: { $0.id == session.id }) {
                return br
            }
        }
        return nil
    }

    func workspace(of branch: Branch) -> Workspace? {
        workspaces.first { $0.branches.contains { $0.id == branch.id } }
    }

    /// The branch whose worktree folder is `path` — the control socket's scope key
    /// (the MCP server sends $CLAUDE_PROJECT_DIR). Symlink-resolved on both sides so
    /// /tmp-style aliases still match.
    func branch(forWorktreePath path: String) -> Branch? {
        let target = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        for ws in workspaces {
            for br in ws.branches
            where br.worktreeURL.resolvingSymlinksInPath().standardizedFileURL.path == target {
                return br
            }
        }
        return nil
    }

    /// Working directory for a session: its branch's worktree folder (ADR-0007).
    func cwd(for session: Session) -> URL? {
        branch(of: session)?.worktreeURL
    }

    // MARK: Commands

    func toggleExpanded(_ id: UUID) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
        // The live tree retargets the Settings project tab at whatever project you touch.
        if let wsID = workspaces.first(where: { $0.id == id || $0.branches.contains { $0.id == id } })?.id {
            retargetSettings(toWorkspace: wsID)
        }
    }

    func open(_ session: Session) {
        settingsOpen = false   // jumping to a session leaves settings mode
        // …but it still remembers the project you jumped into, for the next Settings visit.
        if let br = branch(of: session), let ws = workspace(of: br) { retargetSettings(toWorkspace: ws.id) }
        // Take-me-to-it (002), branch-aware and sticky (014). A branch switch stashes the layout you
        // leave into its Branch.layout and restores the target's remembered one; then, within it:
        //  • the target's durable is a split and the session is a member → return to the split;
        //  • the durable is a split and the session is NOT a member → transient full-screen over it
        //    (the split stays remembered underneath, a later member click returns to it);
        //  • no split → the session is the single pane (the degenerate one-leaf case).
        if let br = branch(of: session), br.id != currentBranchID {
            currentBranch?.layout = durableLayout   // stash the branch we leave
            currentBranchID = br.id
            stashedSplit = nil
            layout = br.layout
        }
        let durable = durableLayout
        if let durable, !durable.isLeaf {
            if let member = leafInTree(durable, session: session.id) {
                layout = durable; stashedSplit = nil; activePane = member          // back to the split
            } else {
                if stashedSplit == nil { stashedSplit = layout }
                layout = PaneNode(leafSession: session.id); activePane = layout     // full-screen over it
            }
        } else {
            stashedSplit = nil
            if let existing = leaf(of: session.id) { activePane = existing }        // already the single pane
            else { layout = PaneNode(leafSession: session.id); activePane = layout }
        }
        renderLayout()
        navCursor = session.id
    }

    /// Optimistically move the content pane onto a still-materialising worktree's
    /// "setting up…" skeleton — tying the switch to the create keystroke, so it can never
    /// surprise the user after an async gap. While this skeleton is what's shown the
    /// finished checkout resolves in place; opening anything else clears it, and the
    /// checkout then lands as a quiet unread row instead (applySessionTemplate).
    func openWorktreeSetup(_ branch: Branch) {
        settingsOpen = false
        // The setup skeleton is a transient, branchless single pane — stash the branch we leave so
        // its remembered layout survives, and don't let the skeleton clobber any branch's entry (014).
        currentBranch?.layout = durableLayout
        currentBranchID = nil
        stashedSplit = nil
        layout = PaneNode(leafSetup: branch.id)
        activePane = layout
        syncActive()
        navCursor = branch.id
    }

    // MARK: Settings

    /// The project the project-tab renders — the remembered one if it still exists, else the
    /// open session's workspace, else the first workspace, else nil (no projects yet).
    var settingsProject: Workspace? {
        if let id = settingsProjectID, let ws = workspaces.first(where: { $0.id == id }) { return ws }
        if let open = openSessionID, let s = session(open),
           let b = branch(of: s), let ws = workspace(of: b) { return ws }
        return workspaces.first
    }

    func enterSettings(project: Workspace? = nil) {
        activeMenu = nil
        closePalette()
        shortcutsOpen = false
        sidebarCollapsed = false
        openSetupBranchID = nil   // leaving for settings revokes any armed setup-resolve
        if let project { settingsProjectID = project.id; settingsTab = .project }
        settingsOpen = true
        // The tree stays live; the keyboard cursor rests on the lit Settings foot button.
        navCursor = NavID.settingsFoot
    }

    func exitSettings() {
        settingsOpen = false
        // Cursor returns to the tree — the open session if it's still visible, else the
        // Settings foot button we came from (working.html exitSettings).
        let visible = visibleRows.map(\.id)
        navCursor = openSessionID.flatMap { visible.contains($0) ? $0 : nil } ?? NavID.settingsFoot
    }

    /// Touching a project in the tree points the Settings project tab at it and remembers it
    /// across visits — the tree is the only thing that sets scope (working.html retargetSettings,
    /// which updates the remembered project on every tree click regardless of Settings being open).
    func retargetSettings(toWorkspace id: UUID) {
        guard settingsProjectID != id else { return }
        settingsProjectID = id
    }

    func toggleSettings() { settingsOpen ? exitSettings() : enterSettings() }

    /// Open the in-app changelog, clearing any surface that would sit under it (mirrors how
    /// the shortcuts sheet is raised).
    func openChangelog() {
        activeMenu = nil
        closePalette()
        shortcutsOpen = false
        changelogVersion = 0   // land on the newest release
        changelogOpen = true
    }

    func closeChangelog() { changelogOpen = false }

    /// Walk the changelog's version rail, clamped to its bounds.
    func moveChangelogVersion(_ delta: Int) {
        let n = ChangelogSheet.releaseCount
        guard n > 0 else { return }
        changelogVersion = max(0, min(n - 1, changelogVersion + delta))
    }

    /// Palette jump: reveal the session (expand collapsed ancestors), open it, mark
    /// read — working.html's jumpTo, selection ring shown as if keyboard-driven.
    func jump(to session: Session) {
        if let br = branch(of: session) {
            expanded.insert(br.id)
            if let ws = workspace(of: br) { expanded.insert(ws.id) }
        }
        open(session)
        keyboardActive = true
    }

    func openPalette() {
        guard palette == nil else { return }
        activeMenu = nil
        palette = PaletteModel(store: self)
    }

    /// Closing while an agent prompt owns the confirm frame IS its "Not now" answer — it
    /// can't just vanish on a blocked MCP call (Esc / ⌘K / backdrop click all funnel here).
    func closePalette() {
        palette = nil
        guard let id = presentedAgentPromptID,
              let prompt = agentPrompts.first(where: { $0.id == id }) else {
            presentedAgentPromptID = nil
            return
        }
        resolveAgentPrompt(prompt, approved: false)
    }

    /// A row's ⋯ kebab opens the palette drilled to that row (working.html openRowActions),
    /// rather than the hover popover. Re-drills if the palette is already open.
    func openRowActions(_ ref: RowRef) {
        activeMenu = nil
        if palette == nil { palette = PaletteModel(store: self) }
        palette?.drill(to: ref)
    }

    /// `a` = add the row's natural child, dropping straight into its ⌘K frame: a worktree
    /// under a workspace (fuzzy branch search), a session under a worktree, or — on a
    /// session leaf — a sibling session in that leaf's parent worktree (working.html addToRow).
    /// Opens the palette if closed; if already open, resets to root then pushes the frame.
    func addToRow(_ ref: RowRef) {
        activeMenu = nil
        if palette == nil { palette = PaletteModel(store: self) }
        guard let pal = palette else { return }
        let frame: PaletteFrame?
        switch ref {
        case let .workspace(w): frame = pal.worktreeFrame(in: w)
        case let .branch(b):    frame = pal.newSessionFrame(branch: b)
        case let .session(s):   frame = branch(of: s).map { pal.newSessionFrame(branch: $0) }
        }
        guard let frame else { return }
        pal.stack = [pal.rootFrame()]
        pal.push(frame)
    }

    /// ⌘N — the new-session picker (terminal / agents / browser) for the branch you're in:
    /// the focused sidebar row's branch when the keyboard owns the sidebar, else the open
    /// session's, else the first available (working.html contextBranch → newSessionFrame).
    func newSessionPicker() {
        guard let br = contextBranchForNewSession() else { return }
        activeMenu = nil
        if palette == nil { palette = PaletteModel(store: self) }
        guard let pal = palette else { return }
        pal.stack = [pal.rootFrame()]
        pal.push(pal.newSessionFrame(branch: br))
    }

    /// The branch a context-resolved action lands in: the focused sidebar row's when the keyboard
    /// owns the sidebar, else the open session's, else the first available (working.html
    /// `contextBranch`). Shared by ⌘N and ⌘⇧T so the two can't drift apart.
    func contextBranchForNewSession() -> Branch? {
        let contextual: Branch? = {
            guard keyboardActive, let ref = cursorRef else { return nil }
            switch ref {
            case let .branch(b):    return b
            case let .session(s):   return branch(of: s)
            case let .workspace(w): return w.liveBranches.first { !$0.isPending }
            }
        }()
        return contextual ?? defaultBranch()
    }

    private func defaultBranch() -> Branch? {
        if let open = openSession, let br = branch(of: open) { return br }
        return workspaces.first?.liveBranches.first { !$0.isPending }
    }

    @discardableResult
    func newTerminal(in branch: Branch? = nil) -> Session? {
        // A freshly opened shell sits at a prompt — nothing is running, so it starts idle.
        // Green (.running) is reserved for a terminal actually running a process.
        addSession(kind: .terminal, title: "shell", status: .idle, in: branch)
    }

    /// A coding agent is just a terminal that opened and ran the agent's binary, so it spawns
    /// identically — only the kind, title and starting state differ (working.html
    /// SESSION_KINDS/addSession). It opens straight into the content pane.
    @discardableResult
    func newAgent(_ agent: AgentID, in branch: Branch? = nil) -> Session? {
        let kind = SessionKind.agent(agent)
        return addSession(kind: kind, title: kind.tplStart, status: .working, in: branch)
    }

    /// A browser session (ADR-0011 stage one): titled "Browser" until it navigates, then
    /// named by its page (host+path). `url` non-nil pre-navigates — the popup path.
    /// Browsers carry no liveness of their own, so the row never shows an indicator
    /// and never raises status notifications — it stays .idle for life. `ownedBy` a
    /// claude row in the same branch makes it a contained browser (stage four) —
    /// nested, cascading, the deterministic comment target.
    ///
    /// `focus: false` is the agent-initiated path (MCP browser.create, popups off an
    /// owned browser): the row appears with the unread bullet instead of stealing the
    /// pane, and the engine boots detached so CDP callers can drive it before the
    /// user ever clicks the row — the pane adopts the live engine on first render.
    @discardableResult
    func newBrowser(in branch: Branch? = nil, at url: URL? = nil, ownedBy owner: Session? = nil,
                    focus: Bool = true) -> Session? {
        let session = addSession(kind: .browser,
                                 title: url?.browserHostPath ?? "Browser",
                                 status: .idle, in: branch, ownedBy: owner, focus: focus)
        session?.browserURL = url
        if let session, !focus {
            // Next runloop turn, same beat as a pane render would give it — creating
            // inside this call would nest a SwiftUI render pass in the engine's
            // creation pump (see BrowserManager.creating).
            DispatchQueue.main.async { _ = BrowserManager.shared.controller(for: session) }
        }
        return session
    }

    /// Spawn a session for a split *without* opening it (focus:false), so the pending create
    /// doesn't clobber the layout before it's bound into the new pane (007's keyboard create /
    /// 010's "New …" drag-in). The caller then `splitActiveWith`s the returned session.
    @discardableResult
    func newForSplit(_ kind: SessionKind, in branch: Branch) -> Session? {
        switch kind {
        case .terminal:
            return addSession(kind: .terminal, title: "shell", status: .idle, in: branch, focus: false)
        case let .agent(id):
            return addSession(kind: .agent(id), title: SessionKind.agent(id).tplStart, status: .working,
                              in: branch, focus: false)
        case .browser:
            return newBrowser(in: branch, focus: false)
        }
    }

    @discardableResult
    private func addSession(kind: SessionKind, title: String, status: SessionStatus,
                            in branch: Branch?, ownedBy owner: Session? = nil,
                            focus: Bool = true) -> Session? {
        // A pending branch has no checkout to run in yet — sessions wait for the worktree.
        guard let br = branch ?? defaultBranch(), !br.isPending else { return nil }
        let session = Session(kind: kind, title: title, status: status)
        // Feature-usage signal: which session type, and whether an agent spun it up vs the user.
        Analytics.capture("session_created", ["kind": kind.rawValue, "agent_initiated": !focus])
        br.sessions.append(session)
        if let owner { adopt(session, by: owner) }
        br.markActivity()
        // Either way the row must be visible in the sidebar — expand down to it.
        if let ws = workspace(of: br) { expanded.insert(ws.id) }
        expanded.insert(br.id)
        if focus {
            open(session)
        } else {
            // Agent-initiated: announce with the unread bullet, leave pane and cursor alone.
            session.unread = true
        }
        return session
    }

    func closeSession(_ session: Session) {
        // Containment cascade (ADR-0011 stage four): an owning claude row's browsers
        // live and die with it — the delete confirm names them before this runs.
        for browser in ownedBrowsers(of: session) { closeSession(browser) }
        // Cursor falls up the hierarchy to the branch row (working.html removeUnit fallback).
        if navCursor == session.id { navCursor = branch(of: session)?.id }
        teardownSession(session)
        for br in workspaces.flatMap(\.branches) {
            br.sessions.removeAll { $0.id == session.id }
        }
        // Layout spine (009): closing a live session collapses its pane and reflows the sibling —
        // the existing removeUnit → prune path, no new guard (004 §6).
        pruneLayout()
        syncActive()
        restoreLastViewed()   // nothing left on screen → back to the session you were on before (016)
    }

    /// Release everything a session holds *outside* the tree: its terminal + browser
    /// engines, its agent supervisor (the only path that stops an opencode event stream's
    /// 250ms reconnect-probe loop), and its entries in the per-session maps and the
    /// notification deck. The tree removal itself is the caller's job. Extracted so bulk
    /// removal (removeBranch/removeWorkspace) tears sessions down as fully as closeSession
    /// — terminating the engines while leaking the supervisor, maps and toast is what left
    /// a removed opencode row probing a dead port forever.
    func teardownSession(_ session: Session) {
        TerminalManager.shared.terminate(session.id)
        BrowserManager.shared.terminate(session.id)
        if openSessionID == session.id { openSessionID = nil }
        liveAgentIDs.remove(session.id)
        // Detach EVERY installed agent's supervisor, not just this row's kind: opencode's
        // decorate mints a port for every spawned session (any terminal may become opencode)
        // and only its own detach releases it, so a closed terminal/claude row would otherwise
        // strand that port entry for the app's life. detach is a no-op for a never-attached one.
        for agent in AgentRegistry.installed { detachSupervisor(agent.id, session.id) }
        pulseTokens.removeValue(forKey: session.id)
        reportedExitCodes.removeValue(forKey: session.id)
        // The exit-close "done" toast was raised moments before this teardown precisely to
        // outlive its row (routeTransition `closing:`) — clearing unconditionally here is
        // what silently killed it. Every other toast still dies with its session.
        if let n = notifs.first(where: { $0.id == session.id }), !n.outlivesSession {
            clearNotif(session.id)
        }
        // Drop this row's link-browser mapping whether it's the source terminal or the
        // browser itself that just closed.
        linkBrowsers[session.id] = nil
        linkBrowsers = linkBrowsers.filter { $0.value != session.id }
    }

    // MARK: Containment (ADR-0011 stage four: a browser can belong to an agent session)

    /// The agent row owning `session`, or nil — a dangling owner id (owner deleted out
    /// from under a snapshot) resolves to nil, i.e. the browser is effectively unowned.
    func owner(of session: Session) -> Session? {
        guard let id = session.ownerSessionID else { return nil }
        return branch(of: session)?.sessions.first { $0.id == id && $0.kind.isAgent }
    }

    /// The browsers an agent row owns, in sidebar order.
    func ownedBrowsers(of session: Session) -> [Session] {
        guard session.kind.isAgent, let br = branch(of: session) else { return [] }
        return br.sessions.filter { $0.ownerSessionID == session.id }
    }

    /// Make `browser` belong to `agent` (creation stamping, the kebab's "Attach to…", or a
    /// comment-spawned agent adopting its browser). Ownership keys off the Synth row id,
    /// so it survives agent exits and resumes.
    func adopt(_ browser: Session, by agent: Session) {
        guard browser.kind == .browser, agent.kind.isAgent,
              let br = branch(of: browser),
              br.sessions.contains(where: { $0.id == agent.id })
        else { return }
        browser.ownerSessionID = agent.id
        snapOwned(in: br)
    }

    /// Release `browser` back to an unowned branch-tier sibling — the cascade escape hatch.
    /// It keeps its slot just below the block it left (snapOwned pulls the still-owned
    /// rows up past it).
    func detach(_ browser: Session) {
        guard browser.ownerSessionID != nil, let br = branch(of: browser) else { return }
        browser.ownerSessionID = nil
        snapOwned(in: br)
    }

    /// Containment's array invariant: owned rows sit contiguously right after their owner,
    /// preserving relative order — the flat `br.sessions` order IS the sidebar order, so
    /// nesting is adjacency, not a second tree (working.html's snapOwned).
    private func snapOwned(in br: Branch) {
        var rows = br.sessions
        var ownedByOwner: [UUID: [Session]] = [:]
        let ownerIDs = Set(rows.filter { $0.kind.isAgent }.map(\.id))
        rows.removeAll { row in
            guard let o = row.ownerSessionID, ownerIDs.contains(o) else { return false }
            ownedByOwner[o, default: []].append(row)
            return true
        }
        br.sessions = rows.flatMap { [$0] + (ownedByOwner[$0.id] ?? []) }
    }

    /// Sessions a quit would kill mid-flight — an agent taking a turn or a live process
    /// (ADR-0013 `isBusy`). Quitting Synth is a Close over every session at once, so it wears
    /// the same rule: confirm only while there's work to lose, and name how much.
    var busySessions: [Session] {
        workspaces.flatMap(\.branches).flatMap(\.sessions).filter { $0.status.isBusy }
    }

    /// The command a scratch terminal is holding the foreground with, if any. `busySessions`
    /// walks the tree and a scratch terminal is deliberately not in it — so without this, quit
    /// and Restart would count zero busy work and kill a running `aws sso login` with the dialog
    /// saying nothing about it. It has no row, so this is the only chance to name it.
    var busyScratchCommand: String? {
        guard let s = scratch, s.busy else { return nil }
        return s.runningCommand.isEmpty ? "a command" : s.runningCommand
    }

    /// What "Quit Synth?" says under its title — everything the quit is about to end. Lives here
    /// rather than inline in `applicationShouldTerminate` so the harness can read the sentence
    /// without presenting a modal it would then have to answer.
    var quitInformativeText: String {
        let busy = busySessions.count
        let sessions = switch busy {
        case 0:  "This closes every session."
        case 1:  "A session is still busy — quitting ends it and its work in progress is lost."
        default: "\(busy) sessions are still busy — quitting ends them and their work in progress is lost."
        }
        // A scratch terminal has no row, so this dialog is the only thing that can tell you a
        // command is about to die with it (features 2026-07-27).
        return busyScratchCommand.map {
            "\(sessions) The scratch terminal is running \($0) — quitting ends that too."
        } ?? sessions
    }

    /// Close-confirm copy for a session: closing an owning claude row cascades, so the
    /// confirm names what goes with it (both confirm surfaces — palette + `d` menu — share it).
    func deleteSessionHint(_ session: Session) -> String {
        let owned = ownedBrowsers(of: session)
        guard !owned.isEmpty else { return "Close this session?" }
        let what = owned.count == 1 ? "browser" : "\(owned.count) browsers"
        return "Close this session? This also closes its \(what)."
    }

    // MARK: Soft delete + undo (working.html softRemove)

    /// Destructive gestures fire instantly and raise a session-less `.undo` card into the
    /// notification deck — same chrome, corner, countdown bar and ⌘↩ as any toast, not a bespoke
    /// pill. `restore` puts the detached rows back on undo; `commit` runs the irreversible tail
    /// (process teardown / disk delete) when the bar drains or a fresh removal supersedes it.
    static let undoLife: TimeInterval = 8
    @ObservationIgnored private var undoActions: [UUID: (restore: () -> Void, commit: () -> Void)] = [:]

    /// Park a reversible removal as its own undo card. Several stack in the deck at once — each
    /// keeps its own countdown and commits when its own bar drains (`armDoneToast`), so a fresh
    /// removal never evicts a pending undo (working.html `pendingUndos`).
    /// What the undo card puts in its chip: the thing you just acted on. A session shows its
    /// own mark (Claude, OpenCode, terminal, browser), everything else a glyph.
    enum UndoSubject {
        case session(SessionKind)
        case glyph(String)
    }

    private func softDelete(_ label: String, subject: UndoSubject,
                            destructive: Bool = false, sub: String? = nil,
                            restore: @escaping () -> Void, commit: @escaping () -> Void) {
        notifSeq += 1
        let id = UUID()
        undoActions[id] = (restore, commit)
        // A nil iconPath on an undo card means "render the session mark" — see NotifCard.glyph.
        var kind = SessionKind.terminal
        var path: String?
        switch subject {
        case .session(let k): kind = k
        case .glyph(let g):   path = g
        }
        var n = InAppNotif(id: id, kind: .undo, seq: notifSeq, sessionKind: kind,
                           title: "", colorIndex: nil, outlivesSession: true,
                           message: label, iconPath: path,
                           tier: .attention, sub: sub,
                           action: NotifAction(label: "Undo", danger: destructive),
                           destructive: destructive, drains: true)
        n.life = Self.undoLife
        n.remaining = Self.undoLife
        notifs.append(n)
    }

    /// Bring a specific parked row back (card click, or ⌘↩ on the front undo card). The window
    /// elapsing runs the mirror path inline in `armDoneToast` (drain → commit), keyed the same way.
    func performUndo(_ id: UUID) {
        guard notifs.contains(where: { $0.id == id && $0.kind == .undo }) else { return }
        cancelDismiss(id)
        let action = undoActions[id]
        undoActions[id] = nil
        notifs.removeAll { $0.id == id }
        action?.restore()
    }

    /// Close a session instantly and reversibly. The row and its owned browsers detach from the
    /// tree but keep their live processes; only the undo's commit tears them down (working.html
    /// softRemove of a session leaf + its ADR-0011 browser cascade).
    func softCloseSession(_ session: Session) {
        let victims = [session] + ownedBrowsers(of: session)
        var homes: [(branch: Branch, index: Int, session: Session)] = []
        for v in victims {
            if let br = branch(of: v), let i = br.sessions.firstIndex(where: { $0.id == v.id }) {
                homes.append((br, i, v))
            }
        }
        let wasOpen = openSessionID == session.id
        if navCursor == session.id { navCursor = branch(of: session)?.id }
        let victimIDs = Set(victims.map(\.id))
        for br in workspaces.flatMap(\.branches) { br.sessions.removeAll { victimIDs.contains($0.id) } }
        pruneLayout(); syncActive(); restoreLastViewed()

        softDelete("Closed \(session.title)", subject: .session(session.kind), restore: { [weak self] in
            guard let self else { return }
            for h in homes.sorted(by: { $0.index < $1.index }) {
                h.branch.sessions.insert(h.session, at: min(h.index, h.branch.sessions.count))
            }
            self.pruneLayout(); self.syncActive()
            if wasOpen { self.jump(to: session) }
        }, commit: { [weak self] in
            victims.forEach { self?.teardownSession($0) }
        })
    }

    /// Remove a project from the sidebar instantly and reversibly — nothing on disk is touched
    /// either way; the commit just tears down its sessions' processes.
    func softRemoveWorkspace(_ ws: Workspace) {
        guard let index = workspaces.firstIndex(where: { $0.id == ws.id }) else { return }
        let wasExpanded = expanded.contains(ws.id)
        if cursorInside(.workspace(ws)) {
            navCursor = index > 0 ? workspaces[index - 1].id
                : workspaces.count > 1 ? workspaces[index + 1].id : nil
        }
        workspaces.remove(at: index)
        expanded.remove(ws.id)
        pruneLayout(); syncActive(); restoreLastViewed()

        softDelete("Removed \(ws.name)", subject: .glyph(Phosphor.folder), restore: { [weak self] in
            guard let self else { return }
            self.workspaces.insert(ws, at: min(index, self.workspaces.count))
            if wasExpanded { self.expanded.insert(ws.id) }
            self.pruneLayout(); self.syncActive()
        }, commit: { [weak self] in
            for s in ws.branches.flatMap(\.sessions) { self?.teardownSession(s) }
        })
    }

    /// Remove a worktree row instantly and reversibly. The disk delete (`deleteWorktree`) and
    /// the sessions' teardown are both deferred to the undo's commit, so an undo within the
    /// window leaves the checkout and its processes untouched (working.html archive-with-undo).
    /// Archive a branch row: it leaves the sidebar at once, its folder is untouched, and the
    /// sweeper may reclaim the folder later once the work is provably recoverable from a
    /// remote (see `ArchiveSweeper`). Restorable from ⌘K → Archived for as long as the folder
    /// is still there.
    ///
    /// `archivedAt` is stamped in the *commit*, not here. The undo window must change nothing
    /// — and stamping at the gesture would hide the row behind `visibleRows`' archive filter,
    /// so undo would re-insert a branch the user then couldn't see.
    func softArchiveBranch(_ branch: Branch) {
        let homes = archiveDetach(branch)
        softDelete("Archived \(branch.name)", subject: .glyph(Phosphor.archive),
                   restore: { [weak self] in self?.archiveReattach(branch, to: homes, archived: false) },
                   commit: { [weak self] in
                       guard let self else { return }
                       for s in branch.sessions { self.teardownSession(s) }
                       branch.sessions = []
                       self.archiveReattach(branch, to: homes, archived: true)
                       Analytics.capture("worktree_archived", ["trigger": "gesture"])
                   })
    }

    /// Delete a worktree's folder from disk now, skipping the archive hold entirely. The
    /// deliberate path, reached only from ⌘K's confirm — the branch itself is never touched.
    func deleteWorktreeNow(_ branch: Branch) {
        let ownerWs = workspaces.first { $0.branches.contains { $0.id == branch.id } }
        let homes = archiveDetach(branch)
        softDelete("Deleted \(branch.name)", subject: .glyph(Phosphor.trash),
                   destructive: true, sub: "the folder goes when the bar does",
                   restore: { [weak self] in self?.archiveReattach(branch, to: homes, archived: false) },
                   commit: { [weak self] in
                       for s in branch.sessions { self?.teardownSession(s) }
                       if let ownerWs, branch.worktreeURL != ownerWs.url {
                           self?.deleteWorktreeFolder(repo: ownerWs.url, path: branch.worktreeURL,
                                                      branchName: branch.name, workspaceName: ownerWs.name)
                       }
                   })
    }

    /// Lift a branch row out of the tree, remembering where it sat so undo can put it back.
    private func archiveDetach(_ branch: Branch) -> [(ws: Workspace, index: Int)] {
        var homes: [(ws: Workspace, index: Int)] = []
        for ws in workspaces {
            if let i = ws.branches.firstIndex(where: { $0.id == branch.id }) { homes.append((ws, i)) }
        }
        if cursorInside(.branch(branch)) { navCursor = workspace(of: branch)?.id }
        if openSetupBranchID == branch.id { openSetupBranchID = nil }
        for ws in workspaces { ws.branches.removeAll { $0.id == branch.id } }
        expanded.remove(branch.id)
        pruneLayout(); syncActive(); restoreLastViewed()
        return homes
    }

    /// Put it back where it was — visible on undo, or archived (so the Archived list can
    /// reach it, while `visibleRows` keeps it out of the tree) on commit.
    private func archiveReattach(_ branch: Branch, to homes: [(ws: Workspace, index: Int)],
                                 archived: Bool) {
        branch.archivedAt = archived ? Date() : nil
        branch.lastCleanSweepEval = nil
        for h in homes.sorted(by: { $0.index < $1.index }) {
            h.ws.branches.insert(branch, at: min(h.index, h.ws.branches.count))
        }
        pruneLayout(); syncActive()
    }

    /// Bring an archived row back into the sidebar, moving its folder back if the sweeper
    /// already put it on hold. Returns false when the folder is gone for good.
    @discardableResult
    func restoreArchivedBranch(_ branch: Branch) -> Bool {
        guard branch.isArchived else { return true }
        if !FileManager.default.fileExists(atPath: branch.worktreeURL.path) {
            guard let held = heldFolder(for: branch),
                  GitService.releaseHeldWorktree(from: held, to: branch.worktreeURL)
            else { return false }
        }
        let days = branch.archivedAt.map { Int(Date().timeIntervalSince($0) / 86_400) } ?? 0
        branch.archivedAt = nil
        branch.lastCleanSweepEval = nil
        branch.markActivity()
        syncActive()
        Analytics.capture("worktree_restored", ["days_archived": days])
        return true
    }

    /// The `.archived-…` sibling holding this branch's folder, if the sweeper has moved it.
    func heldFolder(for branch: Branch) -> URL? {
        let parent = branch.worktreeURL.deletingLastPathComponent()
        let stem = GitService.archivePrefix + branch.worktreeURL.lastPathComponent + "-"
        guard let entries = try? FileManager.default.contentsOfDirectory(at: parent,
                                                                        includingPropertiesForKeys: nil)
        else { return nil }
        return entries.first { $0.lastPathComponent.hasPrefix(stem) }
    }

    /// Every archived row in a workspace, most recently archived first.
    func archivedBranches(in ws: Workspace) -> [Branch] {
        ws.branches.filter(\.isArchived)
            .sorted { ($0.archivedAt ?? .distantPast) > ($1.archivedAt ?? .distantPast) }
    }

    // MARK: Archive sweep

    /// The last verdict the sweeper reached for each archived branch, so the ⌘K Archived list
    /// can say *why* something is still on disk. Runtime-only — re-derived every tick.
    @ObservationIgnored private var sweepVerdicts: [UUID: ArchiveSweeper.Verdict] = [:]
    @ObservationIgnored private var sweepTask: Task<Void, Never>?
    @ObservationIgnored private var sweepInFlight = false
    @ObservationIgnored private var sweptThisLaunch = 0

    /// The ⌘K Archived row's ctx line. Deliberately just "when", not "why".
    ///
    /// Archiving is one simple idea to the user: this row is put away, and it can come back.
    /// Whether the folder has yet been reclaimed — and which of two dozen conditions is
    /// currently holding it — is housekeeping, and narrating it here would make a simple
    /// action read like a system report. The reasons still exist and are still logged; they
    /// come out through `archiveReason` for the harness and `os.Logger` for debugging.
    func archiveStatusLine(_ branch: Branch) -> String {
        guard let at = branch.archivedAt else { return "" }
        return "archived " + relativeAge(at, now: Date())
    }

    /// The sweeper's verdict as a stable slug — automation and logs only, never shown.
    func archiveReason(_ branch: Branch) -> String {
        switch sweepVerdicts[branch.id] {
        case .eligible?:           return "eligible"
        case .waiting?:            return "waiting"
        case .needsSecondOpinion?: return "second-opinion"
        case .blocked(let r)?:     return r.rawValue
        case nil:                  return "unchecked"
        }
    }

    /// Start the repeating sweep. Unlike `startAutosave` the handle is retained, so quit can
    /// actually cancel it — autosave's discarded handle makes it permanently uncancellable,
    /// which is a wart to copy from, not a pattern.
    func startArchiveSweep() {
        sweepTask?.cancel()
        sweepTask = Task { [weak self] in
            // Let a cold `gh`, the network, and MCPInstaller's npm install settle first.
            try? await Task.sleep(for: .seconds(90))
            while !Task.isCancelled {
                await self?.sweepTick()
                let interval = await self?.sweepInterval ?? 300
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    func stopArchiveSweep() {
        sweepTask?.cancel()
        sweepTask = nil
    }

    /// 300s foregrounded, 1800s behind an editor. Not foreground-only: the app's normal state
    /// is "open behind something else". The tick is a gate, not a sweep — with nothing archived
    /// it compares a few dates and costs less than one autosave.
    private var sweepInterval: TimeInterval {
        if let raw = ProcessInfo.processInfo.environment["SYNTH_ARCHIVE_TICK_SECONDS"],
           let secs = TimeInterval(raw) { return secs }
        return NSApp.isActive ? 300 : 1800
    }

    /// One pass. Evaluates every archived branch and holds the folders that clear every gate.
    func sweepTick(force: Bool = false) async {
        guard !sweepInFlight else { return }
        // The kill flag is a KILL, never an ENABLE: `isEnabled` returns false when the user has
        // opted out of analytics, so as an enable flag a privacy-conscious user would silently
        // lose the feature. Absent ⇒ false ⇒ the sweeper runs.
        guard !Analytics.isEnabled("archive_sweeper_kill") else { return }
        guard force || (archiveSweepEnabled && archiveGraceDays > 0) else { return }
        // Low Power Mode and thermal pressure gate the *tick*, not a candidate — a laptop
        // permanently in Low Power Mode must not report every worktree as blocked forever.
        let info = ProcessInfo.processInfo
        guard force || (!info.isLowPowerModeEnabled && info.thermalState != .serious
                        && info.thermalState != .critical) else { return }

        sweepInFlight = true
        defer { sweepInFlight = false }

        // Fresh PR state before deciding anything — a stale read is what makes "no open PR"
        // dangerous. Reaping first frees disk even when nothing new qualifies.
        let hold = ArchiveSweeper.holdSeconds
        await Task.detached(priority: .utility) { GitService.reapHeldWorktrees(hold: hold) }.value
        await refreshPullRequestsAndWait()

        guard let cwdPaths = await Task.detached(priority: .utility,
                                                 operation: { ArchiveSweeper.processWorkingDirectories() }).value
        else { return }   // a failed lsof blocks the whole tick rather than passing every candidate

        let foreign = foreignInstanceWorktreePaths()
        let grace = archiveGraceSeconds
        var eligible: [(Workspace, Branch, Int?)] = []

        for ws in workspaces {
            for branch in archivedBranches(in: ws) {
                // A clock that jumped backwards must never manufacture an expired grace.
                if let at = branch.archivedAt, at > Date() { branch.archivedAt = Date() }
                guard let archivedAt = branch.archivedAt else { continue }
                let candidate = ArchiveSweeper.Candidate(
                    branchID: branch.id, name: branch.name, repo: ws.url,
                    worktree: branch.worktreeURL, archivedAt: archivedAt,
                    lastCleanEval: branch.lastCleanSweepEval,
                    hasSessions: !branch.sessions.isEmpty,
                    foreignInstancePaths: foreign)
                let verdict = await runGit(repo: ws.url) {
                    ArchiveSweeper.evaluate(candidate, graceSeconds: grace, cwdPaths: cwdPaths)
                }
                // The row may have been restored or deleted while git was answering.
                guard let live = workspaces.first(where: { $0.id == ws.id })?
                        .branches.first(where: { $0.id == candidate.branchID }), live.isArchived
                else { continue }
                sweepVerdicts[live.id] = verdict
                switch verdict {
                case .needsSecondOpinion:
                    if live.lastCleanSweepEval == nil { live.lastCleanSweepEval = Date() }
                case .eligible(let pr):
                    eligible.append((ws, live, pr))
                case .waiting, .blocked:
                    live.lastCleanSweepEval = nil
                }
            }
        }

        logTick(eligible: eligible.count)
        guard !eligible.isEmpty else { return }

        // The bulk brake: reopening after a long absence with a dozen suddenly-eligible
        // worktrees is exactly where a human belongs.
        guard eligible.count <= ArchiveSweeper.bulkBrake else {
            raiseArchiveReviewCard(count: eligible.count, in: eligible.first?.0)
            return
        }
        guard !archiveDryRun else {
            for (_, branch, _) in eligible {
                ArchiveSweeper.log.info("dry-run: would hold \(branch.name, privacy: .public)")
            }
            return
        }

        var held: [String] = []
        for (ws, branch, pr) in eligible.prefix(ArchiveSweeper.perTickCap) {
            guard sweptThisLaunch < ArchiveSweeper.perLaunchCap else { break }
            let path = branch.worktreeURL
            let moved = await runGit(repo: ws.url) { () -> Bool in
                guard ArchiveSweeper.isSettled(at: path) else { return false }
                return GitService.holdWorktree(repo: ws.url, path: path) != nil
            }
            guard moved else { continue }
            sweptThisLaunch += 1
            held.append(branch.name)
            ArchiveSweeper.log.info("held \(branch.name, privacy: .public) at \(path.path, privacy: .public)")
            Analytics.capture("archive_swept", ["pr_state": pr == nil ? "ancestor" : "merged",
                                                "grace_days": archiveGraceDays])
        }
        if !held.isEmpty { raiseSweepDigest(held) }
    }

    /// Worktree paths claimed by *other* live Synth instances. Archived paths deliberately stay
    /// in our own registry entry (see `syncAgentBridge`) — that's what lets the other instance
    /// see we still manage them.
    private func foreignInstanceWorktreePaths() -> Set<String> {
        InstanceRegistry.otherInstanceWorktreePaths()
    }

    private func raiseSweepDigest(_ names: [String]) {
        raiseArchiveNotif(names.count == 1 ? "Cleaned up \(names[0])"
                                           : "Cleaned up \(names.count) archived worktrees",
                          tier: .ambient, drains: true)
    }

    /// A housekeeping nudge, not a question your agent is blocked on — so it stops wearing the
    /// needs-input costume (blue, breathing, out-ranking a real done toast) and offers the place
    /// it is pointing at instead. Still sticky: it is asking for a decision.
    private func raiseArchiveReviewCard(count: Int, in ws: Workspace?) {
        let what = count == 1 ? "1 worktree" : "\(count) worktrees"
        raiseArchiveNotif("\(what) ready to clean up", tier: .attention, drains: false,
                          action: ws == nil ? nil : NotifAction(label: "Review"),
                          run: ws.map { w in { [weak self] in self?.openArchivedList(w) } })
    }

    /// Open ⌘K straight at a workspace's archived list — where the review card points.
    func openArchivedList(_ ws: Workspace) {
        openPalette()
        if let p = palette { p.push(p.archivedFrame(ws)) }
    }

    /// One coalesced card per sweep that actually did something. Never per item — the deck's
    /// drain pauses while the app is unfocused, so per-item cards pile up invisibly and then
    /// arrive all at once. A blocked candidate is not a failure and raises nothing; it shows as
    /// a ctx line in the Archived list.
    private func raiseArchiveNotif(_ message: String, tier: NotifTier, drains: Bool,
                                   action: NotifAction? = nil,
                                   run: (@MainActor () -> Void)? = nil) {
        notifSeq += 1
        let id = UUID()
        // `title` stays empty and NotifCard now drops the who-line entirely for it — rendering the
        // identity row unconditionally floated a dot and a glyph over nothing at all.
        notifs.append(InAppNotif(id: id, kind: .neutral, seq: notifSeq, sessionKind: .terminal,
                                 title: "", colorIndex: nil, outlivesSession: true,
                                 message: message, iconPath: Phosphor.archive,
                                 tier: tier, action: action, drains: drains))
        if let run { notifActions[id] = run }
    }

    private func logTick(eligible: Int) {
        var blocked: [String: Int] = [:]
        for verdict in sweepVerdicts.values {
            if let reason = verdict.block { blocked[reason.rawValue, default: 0] += 1 }
        }
        var props: [String: Any] = ["archived": sweepVerdicts.count, "eligible": eligible]
        for (reason, n) in blocked { props["blocked_\(reason)"] = n }
        Analytics.capture("archive_sweep_tick", props)
    }

    /// The comment ladder's spawn rung (CommentMode rung 3): an agent row created exactly
    /// like `newAgent` but WITHOUT `open()` — the spawn is silent, focus stays on the
    /// browser pane. The caller mounts the row for a beat so its PTY boots
    /// (GhosttySurfaceView spawns on window attach), then returns to the browser.
    @discardableResult
    func spawnAgent(_ agent: AgentID, in branch: Branch) -> Session? {
        guard !branch.isPending else { return nil }
        let kind = SessionKind.agent(agent)
        let session = Session(kind: kind, title: kind.tplStart, status: .working)
        branch.sessions.append(session)
        branch.markActivity()
        if let ws = workspace(of: branch) { expanded.insert(ws.id) }
        expanded.insert(branch.id)
        return session
    }

    // MARK: The update card (working.html "The update card")

    /// A build Sparkle has already downloaded and staged. It installs itself the next time Synth
    /// quits whatever anyone clicks — everything here is only about saying so.
    struct StagedUpdate: Sendable, Equatable {
        var version: String
        /// When the build arrived, which is what the reminder's sub-line counts from.
        var stagedAt: Date
    }

    /// Set only once we hold a working installer, so the card's `Restart` can never be a button
    /// that does nothing. A staged build restored from a previous launch is deliberately NOT
    /// enough — Sparkle has to offer it again first.
    var stagedUpdate: StagedUpdate?
    /// Sparkle's `immediateInstallationBlock`: install and relaunch, no UI.
    @ObservationIgnored private var updateInstall: (@MainActor () -> Void)?
    @ObservationIgnored private var updateCardID: UUID?
    @ObservationIgnored private var updateReminderTask: Task<Void, Never>?
    /// The stub installer records the ask instead of relaunching, so a harness can prove Restart
    /// reached Sparkle without the instance vanishing mid-suite.
    var updateInstallRequested = false

    static let updateVersionKey  = "synth-update-version"
    static let updateStagedKey   = "synth-update-staged-at"
    static let updateRemindedKey = "synth-update-reminded-at"

    /// Once a day. Waiting a day is not a test, so `app/harness/` can compress this clock the
    /// same way it compresses the archive sweep's.
    var updateRemindInterval: TimeInterval {
        if let raw = ProcessInfo.processInfo.environment["SYNTH_UPDATE_REMIND_SECONDS"],
           let secs = TimeInterval(raw) { return secs }
        return 86_400
    }

    /// Sparkle staged a build. The card goes up now — that first one is news — unless we already
    /// spoke about this same build within the last day: Sparkle re-offers a staged update on
    /// every launch, and announcing it every launch is the nag this feature exists to avoid.
    func updateStaged(version: String, install: @escaping @MainActor () -> Void) {
        // A build that IS this build is not an update. Sparkle should never offer one, but the
        // record outlives the install it describes, so without this a re-signed or rolled-back
        // appcast could resurface "Synth 0.13.1 is ready" to someone already running 0.13.1 —
        // dated, for good measure, from before they installed it.
        guard version != AppStore.currentShortVersion else { forgetUpdateRecord(); return }
        updateInstall = install
        let known = UserDefaults.standard.string(forKey: AppStore.updateVersionKey)
        let stamped = UserDefaults.standard.object(forKey: AppStore.updateStagedKey) as? Date
        // A build we already know keeps the date it arrived, so "Downloaded 3 days ago" survives
        // a relaunch. A different version starts its own clock.
        let stagedAt = (known == version ? stamped : nil) ?? Date()
        UserDefaults.standard.set(version, forKey: AppStore.updateVersionKey)
        UserDefaults.standard.set(stagedAt, forKey: AppStore.updateStagedKey)
        stagedUpdate = StagedUpdate(version: version, stagedAt: stagedAt)
        let spokenAt = UserDefaults.standard.object(forKey: AppStore.updateRemindedKey) as? Date
        if known == version, let spokenAt, Date().timeIntervalSince(spokenAt) < updateRemindInterval {
            armUpdateReminder()
            return
        }
        showUpdateCard()
    }

    /// Raising re-raises: a dismissed card comes back and a card still standing is rebuilt, so the
    /// daily reminder returns to the FRONT of the deck with its waiting time redrawn instead of
    /// ageing quietly behind newer news (working.html `showUpdateCard`).
    func showUpdateCard() {
        guard let update = stagedUpdate else { return }
        if let old = updateCardID { clearNotif(old) }
        UserDefaults.standard.set(Date(), forKey: AppStore.updateRemindedKey)
        notifSeq += 1
        let id = UUID()
        updateCardID = id
        // Attention tier — sticky, no countdown — because the decision stays open until you make
        // it. Neutral ink and no who-line because this is the app talking about its own
        // housekeeping. And it is the one attention card that never posts Notification Center:
        // a version you were not waiting for does not earn a banner over the app you were
        // actually using, so it waits in the deck for focus to come back.
        notifs.append(InAppNotif(id: id, kind: .neutral, seq: notifSeq, sessionKind: .terminal,
                                 title: "", colorIndex: nil, outlivesSession: true,
                                 message: "Synth \(update.version) is ready",
                                 iconPath: Phosphor.arrowCircleDown,
                                 tier: .attention, sub: updateSubline(),
                                 action: NotifAction(label: "Restart"), drains: false))
        notifActions[id] = { [weak self] in
            guard let self else { return }
            // `runNotifAction` spends the card before it runs this, and a restart that stops to
            // ask must not also cost you the reminder — so it goes back up behind the frame.
            // Only here: from Settings no card was spent, and repairing one would be conjuring it.
            if self.busySessions.count > 0 { self.showUpdateCard() }
            self.restartForUpdate()
        }
        armUpdateReminder()
    }

    /// The first card is news; every card after it is a reminder, and by then the only thing that
    /// has changed is how long you have been putting it off — so that is what the line says.
    func updateSubline() -> String {
        guard let update = stagedUpdate else { return "" }
        let days = Int(Date().timeIntervalSince(update.stagedAt) / updateRemindInterval)
        if days < 1 { return "Installs when you quit" }
        return days == 1 ? "Downloaded yesterday" : "Downloaded \(days) days ago"
    }

    private func armUpdateReminder() {
        updateReminderTask?.cancel()
        guard stagedUpdate != nil else { return }
        let spokenAt = UserDefaults.standard.object(forKey: AppStore.updateRemindedKey) as? Date ?? Date()
        let due = max(0, updateRemindInterval - Date().timeIntervalSince(spokenAt))
        updateReminderTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(due))
            guard !Task.isCancelled else { return }
            await self?.showUpdateCard()
        }
    }

    /// Restarting is the shortcut, not the price — the staged build installs itself on the next
    /// quit either way. But it ends every live turn, so it asks first exactly when there is
    /// something to lose, and never otherwise.
    func restartForUpdate() {
        guard stagedUpdate != nil else { return }
        let busy = busySessions.count
        let scratchJob = busyScratchCommand
        // "Something to lose" includes a scratch terminal mid-command: it has no row, so with
        // only that running this used to restart with no confirm at all.
        guard busy > 0 || scratchJob != nil else { applyUpdate(); return }
        if palette == nil { palette = PaletteModel(store: self) }
        guard let pal = palette else { return }
        activeMenu = nil
        pal.stack = [pal.rootFrame()]
        pal.push(pal.confirmRestartForUpdate(busy: busy, scratchJob: scratchJob))
    }

    /// Sparkle installs and relaunches from here. Suppressing the quit confirm belongs to the
    /// installer itself, not to this: the demo and the harness hand over a stub that records the
    /// ask and returns, and a force-quit flag left standing by one of those would disarm the next
    /// real ⌘Q. The fact is dropped before the install so that whoever does come back — the new
    /// build, or this one after a stub — is not still being told a build is waiting.
    func applyUpdate() {
        guard let install = updateInstall else {
            NSLog("Synth: update Restart with no installer — the card should never have been up.")
            return
        }
        if let id = updateCardID { clearNotif(id); updateCardID = nil }
        updateReminderTask?.cancel()
        updateInstall = nil
        stagedUpdate = nil
        forgetUpdateRecord()
        install()
    }

    /// The persisted record of a staged build, dropped once it stops describing anything.
    private func forgetUpdateRecord() {
        for key in [AppStore.updateVersionKey, AppStore.updateStagedKey, AppStore.updateRemindedKey] {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    static var currentShortVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? ""
    }

    /// Stage a build without Sparkle — the ⌥U demo and the harness. The installer records the ask
    /// instead of relaunching, and `daysAgo` back-dates the arrival so the ageing reminder can be
    /// read without waiting days for it. Deliberately does NOT go through `updateStaged`: a demo
    /// must not overwrite the record of a real build this install is genuinely waiting on.
    func stageStubUpdate(version: String, daysAgo: Double = 0) {
        updateInstall = { [weak self] in self?.updateInstallRequested = true }
        stagedUpdate = StagedUpdate(version: version,
                                    stagedAt: Date().addingTimeInterval(-daysAgo * updateRemindInterval))
        showUpdateCard()
    }

    // MARK: Feedback (⌘⇧F)

    /// Resolved by `feedbackMode`: the author names a fix (title) and optionally details it
    /// (body), turning it into a real `feedback/<slug>` worktree with a Claude session already
    /// working it (seeded with title + body + captured context); everyone else gets a pre-filled
    /// email from the one box. Called from the sheet.
    func submitFeedback(_ raw: String) {
        let body = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = feedbackTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        feedbackDraft = ""
        feedbackTitle = ""
        feedbackOpen = false
        // The event records that feedback happened and roughly how much — never the text itself,
        // which stays non-PII on the wire. The actual content still reaches the author via the
        // email / fix-agent paths below.
        Analytics.capture("feedback_submitted", [
            "mode": String(describing: feedbackMode),
            "has_body": !body.isEmpty,
            "length": body.count,
        ])
        switch feedbackMode {
        case .author:
            guard !title.isEmpty else { return }
            startFeedbackFix(title: title, body: body)
        case .email:
            guard !body.isEmpty else { return }
            openFeedbackEmail(body)
        }
    }

    /// Author path: cut a `feedback/<slug>` worktree off the open session's workspace and, once
    /// it lands, spawn a single Claude and seed it with the feedback + context — the comment-mode
    /// delivery loop pointed at Synth itself. Falls back to email if there's nowhere to host it.
    /// The slug is derived from the title the author gave and de-duplicated against existing
    /// branches, so a repeated gripe never collides `git worktree add` (its old failure mode).
    private func startFeedbackFix(title: String, body: String) {
        guard let ws = feedbackWorkspace() else { openFeedbackEmail(body.isEmpty ? title : body); return }
        let repo = ws.url
        let slug = Self.feedbackSlug(from: title)
        let gripe = body.isEmpty ? title : title + "\n\n" + body
        let seed = gripe + "\n\n" + captureFeedbackContext()
        // The "On it" ack is instant; the collision-free branch name needs `git for-each-ref` over
        // heads + remotes, which blocks for hundreds of ms on a big/cold repo — so resolve it (and
        // add the pending row) off the main thread rather than freezing the submit.
        // The branch is the identity, "On it" is what happened, and the mark is the comment
        // glyph: a check would say a session finished, and nothing finished — something started.
        raiseFeedbackToast(.done, message: "On it", title: "feedback/\(slug)",
                           icon: Phosphor.commentMode)
        Task { [weak self] in
            guard let self else { return }
            let (branchName, planned) = await self.runGit(repo: repo) {
                Self.uniqueFeedbackBranch(slug: slug, repo: repo)
            }
            let row = self.addBranchRow(in: ws, name: branchName, worktreeURL: planned, pending: true)
            self.materialize(row, in: ws, spawningTemplate: false, onReady: { [weak self] branch in
                self?.seedAgent(in: branch, seed: seed)
            }) {
                GitService.addWorktree(repo: repo, path: planned, newBranch: branchName, base: nil)
                    .map { .failed($0) } ?? .ready(planned)
            }
        }
    }

    /// Resolve `feedback/<slug>` to a name no existing branch or planned worktree dir already
    /// holds, suffixing `-2`, `-3`… on collision — so a repeated gripe (or the `note` fallback)
    /// can never hard-fail `git worktree add` with "a branch already exists".
    private nonisolated static func uniqueFeedbackBranch(slug: String, repo: URL) -> (branch: String, path: URL) {
        let taken = Set(GitService.allBranches(at: repo).map(\.name))
        var n = 1
        while true {
            let branch = n == 1 ? "feedback/\(slug)" : "feedback/\(slug)-\(n)"
            let path = GitService.plannedWorktreePath(repo: repo, branch: branch)
            if !taken.contains(branch) && !FileManager.default.fileExists(atPath: path.path) {
                return (branch, path)
            }
            n += 1
        }
    }

    /// Spawn a quiet agent in a freshly-materialized branch, mount it for a beat so its PTY
    /// boots (GhosttySurfaceView spawns on window attach), bounce focus back, then boot-and-wait
    /// for the supervisor's liveness signal and hand it the seed — mirroring CommentMode rung 3.
    /// Serves both seeded-worktree flows: the feedback fix and the synth-app handoff.
    private func seedAgent(in branch: Branch, seed: String) {
        guard let agent = AgentRegistry.default?.id,
              let session = spawnAgent(agent, in: branch) else { return }
        let previous = openSessionID
        open(session)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.openSessionID == session.id,
                  let previous, let back = self.session(previous) else { return }
            self.open(back)
        }
        // SECURITY (CommentMode): only ever submit to a supervisor-confirmed-live agent — an
        // agent that never started leaves a bare shell, and Claude Code's delivery is a paste
        // plus Enter, i.e. arbitrary execution. Poll ~20s, settle a beat, re-check.
        Task { [weak self] in
            for _ in 0..<40 {
                try? await Task.sleep(for: .seconds(0.5))
                guard let self, self.isLiveAgent(session.id) else { continue }
                try? await Task.sleep(for: .seconds(1))
                guard self.isLiveAgent(session.id),
                      let supervisor = self.liveSupervisor(for: session) else { continue }
                if supervisor.deliver(seed, to: session.id) { return }
            }
            NSLog("Synth: seed never delivered (agent didn't report in)")
        }
    }

    /// Other path: open the user's mail client with a pre-filled draft. The body attaches only
    /// version/OS (no branch or session names leave the machine), capped for mailto's practical
    /// limit. No mail client → copy to the clipboard and say so.
    private func openFeedbackEmail(_ text: String) {
        let body = String((text + "\n\n— — —\n" + feedbackEnvLine() + "\n\nSent from Synth").prefix(1600))
        var comps = URLComponents()
        comps.scheme = "mailto"
        comps.path = FeedbackMode.recipient
        comps.queryItems = [URLQueryItem(name: "subject", value: "Synth feedback"),
                            URLQueryItem(name: "body", value: body)]
        if let url = comps.url, NSWorkspace.shared.open(url) {
            // One line: the who-row used to carry the literal email subject, the one thing you
            // had just typed yourself.
            raiseFeedbackToast(.neutral, message: "Handed to Mail", title: "", icon: Phosphor.mail)
        } else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(body, forType: .string)
            // Nothing failed: the fallback worked and your text is on the clipboard. It used to
            // raise a red, sticky error that sat in the deck until clicked, and led with the
            // negative.
            raiseFeedbackToast(.neutral, message: "Feedback copied to clipboard", title: "",
                               icon: Phosphor.copy,
                               sub: "no mail app — paste it to \(FeedbackMode.recipient)")
        }
    }

    /// Where a feedback fix lands: author gripes are always about Synth, so target the Synth repo
    /// itself wherever it sits in the sidebar — never whatever workspace happens to be open (that
    /// could be some unrelated client repo). Falls back to the open session's workspace, then the
    /// first, only if Synth isn't among the workspaces at all.
    private func feedbackWorkspace() -> Workspace? {
        if let synth = workspaces.first(where: { Self.isSynthRepo($0.url) }) { return synth }
        if let s = openSession, let b = branch(of: s), let ws = workspace(of: b) { return ws }
        return workspaces.first
    }

    /// True when `repo`'s working tree is Synth's own source — its root carries the design HTML
    /// and the app sources together, a pairing no other repo has. Matches the main checkout or any
    /// of its worktrees (both carry the full tree).
    private static func isSynthRepo(_ repo: URL) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: repo.appendingPathComponent("big-picture-design.html").path)
            && fm.fileExists(atPath: repo.appendingPathComponent("app/Sources/Synth/SynthApp.swift").path)
    }

    /// Structural facts only — what Synth is doing, never what you're building. Attached to the
    /// author seed silently; no file contents, paths, terminal output, env values or clipboard.
    func captureFeedbackContext() -> String {
        var lines: [String] = []
        if let s = openSession {
            let kind: String
            switch s.kind {
            case .agent:    kind = s.kind.tplStart
            case .terminal: kind = "Terminal"
            case .browser:  kind = "Browser"
            }
            lines.append("Here: \(kind) · \(branch(of: s)?.name ?? "—")")
        }
        let wsCount = workspaces.count
        let allSessions = workspaces.flatMap { $0.branches }.flatMap { $0.sessions }
        let working = allSessions.filter { if case .working = $0.status { return true } else { return false } }.count
        let unread = allSessions.filter(\.unread).count
        lines.append("State: \(wsCount) workspace\(wsCount == 1 ? "" : "s") · \(working) working · \(unread) unread")
        lines.append("Env: \(feedbackEnvLine())")
        return lines.joined(separator: "\n")
    }

    private func feedbackEnvLine() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let version = Bundle.main.bundleIdentifier != nil
            ? (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev") : "dev"
        return "Synth \(version) · macOS \(v.majorVersion).\(v.minorVersion) · \(themePref.rawValue) theme"
    }

    /// A title → a filesystem- and ref-safe branch slug: alphanumeric words, dash-joined, then
    /// capped at 48 chars so a pasted URL/hash can't push a single ref component past git's
    /// 255-byte limit (its old "File name too long" failure). Empty input falls back to "note".
    static func feedbackSlug(from text: String) -> String {
        let cleaned = String(text.lowercased().map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : " " })
        let joined = cleaned.split(separator: " ").prefix(6).joined(separator: "-")
        var slug = String(joined.prefix(48))
        while slug.hasSuffix("-") { slug.removeLast() }
        return slug.isEmpty ? "note" : slug
    }

    /// A session-less confirmation card (mirrors `raiseWorktreeError`). Every one of these is
    /// ambient: a result, not a summons, and gone in six seconds.
    private func raiseFeedbackToast(_ kind: NotifKind, message: String, title: String,
                                    icon: String, sub: String? = nil) {
        notifSeq += 1
        let id = UUID()
        notifs.append(InAppNotif(id: id, kind: kind, seq: notifSeq, sessionKind: .terminal,
                                 title: title, colorIndex: nil, outlivesSession: true,
                                 message: message, iconPath: icon,
                                 tier: .ambient, sub: sub, drains: true))
    }

    /// Folder picker → adds the repo with its default branch. Panel runs modally, so
    /// state mutation happens after dismiss.
    func promptAddWorkspace() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add"
        panel.message = "Choose a repository folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        beginAddWorkspace(url: url)
    }

    /// Add the repo with just its default branch — the checkout already at the repo
    /// root — as the sole worktree row. No branch picker: further branches are added
    /// later, one at a time, from the row's "New branch" action. The git read runs off
    /// the main thread (`for-each-ref` on a large/cold repo can take a beat); a non-repo
    /// folder yields a branchless workspace.
    func beginAddWorkspace(url: URL) {
        Task { [weak self] in
            guard let self else { return }
            let seed = await runGit(repo: url) { () -> (name: String, worktree: URL, age: String)? in
                let branches = GitService.branches(at: url)
                guard !branches.isEmpty else { return nil }
                // git lists the main worktree first; the branch checked out there is the
                // repo's default, and its folder (the repo root) is its worktree already.
                let main = GitService.worktrees(at: url).first
                let name = main?.branch ?? branches[0].name
                let age = branches.first { $0.name == name }
                    .map { GitService.compactAge($0.lastCommitUnix) } ?? ""
                return (name, main?.path ?? url, age)
            }
            let rows = seed.map { [Branch(name: $0.name, worktreeURL: $0.worktree, lastActivity: $0.age)] } ?? []
            finishAddWorkspace(url: url, branches: rows)
        }
    }

    private func finishAddWorkspace(url: URL, branches: [Branch]) {
        let ws = Workspace(
            name: url.lastPathComponent,
            url: url,
            branches: branches,
            colorIndex: workspaces.count % Theme.chipColors.count
        )
        workspaces.append(ws)   // collapsed by default
        refreshPullRequests(in: ws)
    }

    // MARK: Pull requests (PRService)

    /// Refresh every workspace's PR state from `gh`. Called at launch and on app activation;
    /// cheap to repeat — a missing `gh` or a non-GitHub repo simply yields no PRs.
    func refreshPullRequests() {
        guard PRService.ghPath != nil else { return }
        for ws in workspaces { refreshPullRequests(in: ws) }
    }

    /// In-flight and last-completed reads, keyed by workspace. `didBecomeActive` fires on
    /// every ⌘-tab back, and without these a burst of activations spawns unbounded `gh`
    /// subprocesses — two network calls each, per workspace.
    @ObservationIgnored private var prRefreshInFlight: Set<UUID> = []
    @ObservationIgnored private var lastPRRefresh: [UUID: Date] = [:]
    private static let prRefreshFloor: TimeInterval = 60

    /// One workspace's read: the blocking `gh pr list` (a cold call hits the network) runs
    /// off the main thread; the result is folded back onto the branches on the main actor.
    @discardableResult
    private func refreshPullRequests(in workspace: Workspace, force: Bool = false) -> Task<Void, Never>? {
        guard PRService.ghPath != nil else { return nil }
        let id = workspace.id
        guard !prRefreshInFlight.contains(id) else { return nil }
        if !force, let last = lastPRRefresh[id], Date().timeIntervalSince(last) < Self.prRefreshFloor {
            return nil
        }
        let repo = workspace.url
        prRefreshInFlight.insert(id)
        return Task { [weak self] in
            let prs = await Task.detached(priority: .utility) {
                PRService.pullRequests(at: repo)
            }.value
            guard let self else { return }
            self.prRefreshInFlight.remove(id)
            // nil is "couldn't ask" — offline, no `gh`, not a GitHub repo. Keep whatever we
            // last knew rather than clearing every badge; a stale PR number is closer to the
            // truth than none, and the sweeper reads this state.
            guard let prs else { return }
            self.lastPRRefresh[id] = Date()
            guard let ws = self.workspaces.first(where: { $0.id == id }) else { return }
            for branch in ws.branches where branch.pr != prs[branch.name] {
                branch.pr = prs[branch.name]
            }
        }
    }

    /// Refresh every workspace and wait for it, so a caller that needs fresh PR state —
    /// the archive sweeper — reads it after the answer lands rather than beside it.
    func refreshPullRequestsAndWait(force: Bool = false) async {
        guard PRService.ghPath != nil else { return }
        let tasks = workspaces.compactMap { refreshPullRequests(in: $0, force: force) }
        for task in tasks { await task.value }
    }

    /// When each workspace's PR state was last successfully read. The sweeper refuses to act
    /// on a workspace whose PR state it has never actually seen this session.
    func prStateFresh(for workspace: Workspace, within: TimeInterval) -> Bool {
        guard let last = lastPRRefresh[workspace.id] else { return false }
        return Date().timeIntervalSince(last) <= within
    }

    // MARK: Worktrees (ADR-0007: every branch row is a real folder)

    /// How a background create resolved: the row's real checkout, or git's message.
    private enum WorktreeOutcome: Sendable {
        case ready(URL)
        case failed(String)
    }

    /// Tail of each repo's background git chain. Worktree mutations on one repo are
    /// serialized — concurrent `git worktree` calls race the repo's locks — while
    /// different repos run independently. Ops run detached so a full checkout or a
    /// multi-GB delete never touches the main thread.
    @ObservationIgnored private var gitTails: [URL: Task<Void, Never>] = [:]
    /// Per-repo generation, so a self-clearing tail only removes its own entry (a newer op
    /// may already have chained on behind it).
    @ObservationIgnored private var gitTailSeq: [URL: Int] = [:]

    /// Run `op` off the main thread, behind any in-flight op on `repo`, returning its
    /// result on the main actor.
    private func runGit<T: Sendable>(repo: URL, _ op: @escaping @Sendable () -> T) async -> T {
        let prev = gitTails[repo]
        let task = Task<T, Never> {
            await prev?.value
            return await Task.detached(priority: .userInitiated) { op() }.value
        }
        let seq = (gitTailSeq[repo] ?? 0) + 1
        gitTailSeq[repo] = seq
        // Self-clear once idle so the map holds only in-flight chains, not one dead Task per
        // repo ever touched. The seq guard leaves a newer op's tail in place.
        gitTails[repo] = Task { [weak self] in
            _ = await task.value
            guard let self, self.gitTailSeq[repo] == seq else { return }
            self.gitTails[repo] = nil
            self.gitTailSeq[repo] = nil
        }
        return await task.value
    }

    /// Run a background create for an already-visible pending row: success activates the
    /// row in place; failure drops it and raises the persistent error toast.
    /// `spawningTemplate` applies the scope's new-worktree session template once the
    /// checkout lands — the Create-worktree flows opt in; adding a workspace doesn't
    /// (those rows import existing branches, and N rows fighting to open a session each
    /// would be noise).
    /// `retry` is the one call that would repeat this create verbatim, offered on the failure
    /// card. The flows that can't be repeated as a single call pass nil and the card carries no
    /// button — an offer that can't be honoured is worse than none.
    private func materialize(_ row: Branch, in ws: Workspace, spawningTemplate: Bool = false,
                             retry: (@MainActor () -> Void)? = nil,
                             onReady: ((Branch) -> Void)? = nil,
                             _ op: @escaping @Sendable () -> WorktreeOutcome) {
        let wsName = ws.name
        Task { [weak self] in
            guard let self else { return }
            switch await runGit(repo: ws.url, op) {
            case .ready(let url):
                row.worktreeURL = url
                row.isPending = false
                row.markActivity()
                Analytics.capture("worktree_created", ["from_template": spawningTemplate])
                if spawningTemplate { applySessionTemplate(to: row, in: ws) }
                onReady?(row)
                saveNow()
            case .failed(let err):
                let name = row.name
                removeBranch(row, deleteWorktree: false)
                raiseWorktreeError("Couldn't create worktree", branch: name,
                                   workspace: wsName, details: err, retry: retry)
            }
        }
    }

    /// Check an existing branch out into a worktree (reusing one if the branch already
    /// has it). The row appears pending immediately; the checkout lands in the background.
    func createWorktree(in ws: Workspace, existingBranch: String) {
        let repo = ws.url
        let planned = GitService.plannedWorktreePath(repo: repo, branch: existingBranch)
        let row = addBranchRow(in: ws, name: existingBranch, worktreeURL: planned, pending: true)
        openWorktreeSetup(row)
        materialize(row, in: ws, spawningTemplate: true,
                    retry: { [weak self] in self?.createWorktree(in: ws, existingBranch: existingBranch) }) {
            if let wt = GitService.worktrees(at: repo).first(where: { $0.branch == existingBranch }) {
                return .ready(wt.path)
            }
            return GitService.addWorktree(repo: repo, path: planned, branch: existingBranch)
                .map { .failed($0) } ?? .ready(planned)
        }
    }

    /// Cut a new branch off `base` (the repo's default branch when nil) into a fresh
    /// worktree — same pending-row shape as the existing-branch path.
    func createWorktree(in ws: Workspace, newBranch: String, base: String?) {
        let repo = ws.url
        let planned = GitService.plannedWorktreePath(repo: repo, branch: newBranch)
        let row = addBranchRow(in: ws, name: newBranch, worktreeURL: planned, pending: true)
        openWorktreeSetup(row)
        materialize(row, in: ws, spawningTemplate: true,
                    retry: { [weak self] in self?.createWorktree(in: ws, newBranch: newBranch, base: base) }) {
            GitService.addWorktree(repo: repo, path: planned, newBranch: newBranch, base: base)
                .map { .failed($0) } ?? .ready(planned)
        }
    }

    // MARK: Agent-requested worktrees (the synth-app MCP server's one verb so far)

    /// Validate an agent's worktree request and, when it needs the user, queue the
    /// approval prompt. Runs on the control connection's main-sync hop, so nothing here
    /// may block: existing-vs-new branch is decided later, inside the background git op.
    func beginAgentWorktreePrompt(_ request: [String: Any],
                                  respond: @escaping ([String: Any]) -> Void) -> AgentPromptStart {
        guard mcpAppEnabled else {
            return .immediate(["ok": false, "error":
                "the Synth app MCP server is turned off — enable it in Synth Settings → MCP servers"])
        }
        guard let worktreePath = request["worktreePath"] as? String,
              let callerBranch = branch(forWorktreePath: worktreePath),
              let ws = workspace(of: callerBranch) else {
            return .immediate(["ok": false, "error":
                "no Synth branch manages worktree \(request["worktreePath"] ?? "<missing>")"])
        }
        guard let name = (request["branch"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            return .immediate(["ok": false, "error": "need branch"])
        }
        // Idempotence: a branch that's already a row needs no prompt and no git — hand
        // back its checkout and let the agent proceed.
        if let row = ws.branches.first(where: { $0.name == name }) {
            return .immediate(["ok": true, "decision": "exists",
                               "worktreePath": row.worktreeURL.path])
        }
        if agentPrompts.contains(where: { $0.workspace === ws && $0.branchName == name }) {
            return .immediate(["ok": false, "error":
                "a prompt for \(name) is already awaiting the user's answer"])
        }
        let requester = (request["ownerSessionId"] as? String)
            .flatMap(UUID.init(uuidString:))
            .flatMap { id in callerBranch.sessions.first { $0.id == id && $0.kind.isAgent } }
        let prompt = AgentWorktreePrompt(
            workspace: ws,
            branchName: name,
            base: (request["base"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            handoff: (request["handoff"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            requesterTitle: requester?.title,
            respond: respond)
        agentPrompts.append(prompt)
        presentAgentPrompt(prompt)
        return .pending(prompt.id)
    }

    /// Surfaces an agent prompt as the ⌘K confirm frame (was a modal sheet) — interrupts
    /// whatever the palette was showing, same as the sheet interrupted the app.
    private func presentAgentPrompt(_ prompt: AgentWorktreePrompt) {
        if palette == nil { palette = PaletteModel(store: self) }
        guard let pal = palette else { return }
        presentedAgentPromptID = prompt.id
        pal.stack = [pal.rootFrame(), pal.confirmAgentWorktree(prompt)]
        pal.query = ""
        pal.activeIndex = 0
    }

    /// After a prompt leaves the queue (resolved or cancelled), keep the palette in sync:
    /// chain to the next pending prompt, or close if none remain — only when the palette's
    /// confirm frame actually belonged to the prompt that just left.
    private func advanceAgentPromptPresentation(from id: UUID) {
        guard presentedAgentPromptID == id else { return }
        presentedAgentPromptID = nil
        if let next = agentPrompts.first { presentAgentPrompt(next) }
        else { closePalette() }
    }

    /// The confirm frame's two items. Approve cuts the worktree exactly like ⌘K
    /// "Create worktree" (pending row, background checkout, pane onto the setup
    /// skeleton — the jump rides the user's Create click) and answers the blocked MCP
    /// call; decline just answers it.
    func resolveAgentPrompt(_ prompt: AgentWorktreePrompt, approved: Bool) {
        guard let i = agentPrompts.firstIndex(where: { $0.id == prompt.id }) else { return }
        agentPrompts.remove(at: i)
        advanceAgentPromptPresentation(from: prompt.id)
        guard approved else {
            prompt.respond(["ok": true, "decision": "declined"])
            return
        }
        let planned = agentCreateWorktree(prompt)
        prompt.respond(["ok": true, "decision": "created",
                        "branch": prompt.branchName, "worktreePath": planned.path])
    }

    /// The MCP server gave up waiting — drop the prompt so a stale question isn't
    /// answered into a dead socket. False when it was already resolved (that race is
    /// the caller's to read).
    @discardableResult
    func cancelAgentPrompt(_ id: UUID) -> Bool {
        guard let i = agentPrompts.firstIndex(where: { $0.id == id }) else { return false }
        agentPrompts.remove(at: i)
        advanceAgentPromptPresentation(from: id)
        return true
    }

    /// The approved create. Existing-vs-new is decided inside the background op (a git
    /// scan mustn't run on the approval click's main hop): a branch with a worktree
    /// reuses it, an existing local/remote branch checks out (`worktree add` DWIMs
    /// remote-tracking names), anything else is cut off `base`. A handoff swaps the
    /// session template for one seeded Claude — the feedback loop's delivery path.
    private func agentCreateWorktree(_ prompt: AgentWorktreePrompt) -> URL {
        let ws = prompt.workspace
        let repo = ws.url
        let name = prompt.branchName
        let base = prompt.base
        let planned = GitService.plannedWorktreePath(repo: repo, branch: name)
        let row = addBranchRow(in: ws, name: name, worktreeURL: planned, pending: true)
        openWorktreeSetup(row)
        let onReady: ((Branch) -> Void)? = prompt.handoff.map { seed in
            { [weak self] branch in self?.seedAgent(in: branch, seed: seed) }
        }
        materialize(row, in: ws, spawningTemplate: prompt.handoff == nil, onReady: onReady) {
            if let wt = GitService.worktrees(at: repo).first(where: { $0.branch == name }) {
                return .ready(wt.path)
            }
            if GitService.allBranches(at: repo).contains(where: { $0.name == name }) {
                return GitService.addWorktree(repo: repo, path: planned, branch: name)
                    .map { .failed($0) } ?? .ready(planned)
            }
            return GitService.addWorktree(repo: repo, path: planned, newBranch: name, base: base)
                .map { .failed($0) } ?? .ready(planned)
        }
        return planned
    }

    /// The fast delete path (features 2026-07-06): the row is already gone; the folder is
    /// renamed aside + pruned (O(1)) behind any in-flight op on the repo, and the real
    /// delete runs afterwards where nobody waits on it. A failed rename falls back to the
    /// blocking `git worktree remove` — still off the main thread.
    func deleteWorktreeFolder(repo: URL, path: URL, branchName: String, workspaceName: String) {
        Task { [weak self] in
            guard let self else { return }
            let err = await runGit(repo: repo) { () -> String? in
                guard FileManager.default.fileExists(atPath: path.path) else {
                    GitService.pruneWorktrees(at: repo)   // gone already — just tidy the entry
                    return nil
                }
                if let trash = GitService.detachWorktree(repo: repo, path: path) {
                    Task.detached(priority: .background) { try? FileManager.default.removeItem(at: trash) }
                    return nil
                }
                return GitService.removeWorktree(repo: repo, path: path)
            }
            if let err {
                raiseWorktreeError("Couldn't delete worktree", branch: branchName,
                                   workspace: workspaceName, details: err,
                                   retry: { [weak self] in
                                       self?.deleteWorktreeFolder(repo: repo, path: path,
                                                                  branchName: branchName,
                                                                  workspaceName: workspaceName)
                                   })
            }
        }
    }

    @discardableResult
    private func addBranchRow(in ws: Workspace, name: String, worktreeURL: URL, pending: Bool = false) -> Branch {
        let branch = Branch(name: name, worktreeURL: worktreeURL,
                            lastActivity: pending ? "" : "now",
                            lastActivityAt: pending ? nil : Date(), isPending: pending)
        ws.branches.append(branch)
        expanded.insert(ws.id)
        navCursor = branch.id
        return branch
    }

    /// Spawn the scope's new-worktree session template into a just-materialized row
    /// (working.html addBranch): entries in creation order, the first one opens; the
    /// rest wait dormant like restored rows — their process starts on first open, so
    /// only the opened session touches the PTY layer. A name differing from the kind's
    /// stock start counts as hand-picked (titleIsCustom), so auto-naming — ai-title,
    /// running command, page title — never overwrites a template name the user chose.
    private func applySessionTemplate(to branch: Branch, in ws: Workspace) {
        // Whether the user is still parked on this row's setup skeleton decides the whole
        // handoff: still here → resolve in place; moved on → don't touch the viewport.
        let watching = openSetupBranchID == branch.id
        let entries = sessionTemplate(for: ws)
        guard !entries.isEmpty else {
            // An emptied template means "start bare": nothing to open. If we're still on
            // the skeleton, drop it so the pane settles onto the now-ready (empty) row.
            if watching { openSetupBranchID = nil }
            return
        }
        let sessions = entries.enumerated().map { i, entry in
            Session(kind: entry.kind, title: entry.name,
                    status: entry.kind.isAgent && i == 0 ? .working : .idle,
                    titleIsCustom: entry.name != entry.kind.tplStart)
        }
        branch.sessions.append(contentsOf: sessions)
        branch.markActivity()
        expanded.insert(ws.id)
        expanded.insert(branch.id)
        if watching, let first = sessions.first {
            open(first)   // last intent still points here — resolve the skeleton in place
        } else {
            // The user moved on after requesting — announce the ready worktree with the
            // quiet unread bullet (browser-ownership idiom) instead of stealing the pane.
            sessions.first?.unread = true
        }
    }

    // MARK: Persistence (ADR-0010)

    /// Snapshot the durable tree for disk — everything that isn't a live-process fact.
    private func snapshot() -> PersistedState {
        PersistedState(
            version: PersistenceStore.schemaVersion,
            workspaces: workspaces.map { ws in
                PersistedWorkspace(
                    id: ws.id, name: ws.name, url: ws.url, colorIndex: ws.colorIndex,
                    // Pending rows are still being created — a quit mid-create must not
                    // restore a row whose checkout may never have landed.
                    branches: ws.branches.filter { !$0.isPending }.map { br in
                        PersistedBranch(
                            id: br.id, name: br.name, worktreeURL: br.worktreeURL,
                            lastActivity: br.lastActivity,
                            lastActivityAt: br.lastActivityAt,
                            sessions: br.sessions.map { s in
                                PersistedSession(id: s.id, kind: s.kind.rawValue, title: s.title,
                                                 titleIsCustom: s.titleIsCustom,
                                                 agentSessionID: s.agentSessionID,
                                                 browserURL: s.browserURL,
                                                 ownerSessionID: s.ownerSessionID)
                            },
                            browserRecents: br.browserRecents.isEmpty ? nil : br.browserRecents,
                            // The branch's remembered split, serialized to session identities;
                            // nil for a single pane (014). Leaves whose session is gone collapse.
                            layout: serializeLayout(br.layout, valid: Set(br.sessions.map(\.id))),
                            archivedAt: br.archivedAt,
                            lastCleanSweepEval: br.lastCleanSweepEval)
                    },
                    setupScript: wsScripts[ws.id],
                    agentFlags: wsAgentFlags[ws.id].map { flags in
                        flags.reduce(into: [:]) { $0[$1.key.rawValue] = $1.value }
                    },
                    // nil when empty: an empty workspace list means "inherit global",
                    // the same fact as having no list at all.
                    sessionTemplate: (wsSessionTemplates[ws.id]?.isEmpty ?? true)
                        ? nil : wsSessionTemplates[ws.id],
                    skipSharedSetup: (wsSkipScript[ws.id] ?? false) ? true : nil)
            },
            // Sorted so an unchanged set always encodes to identical bytes (Set iteration
            // order is per-process nondeterministic) — the skip-if-unchanged check relies on it.
            expanded: expanded.sorted { $0.uuidString < $1.uuidString },
            globalScript: globalScript,
            globalAgentFlags: globalAgentFlags.reduce(into: [:]) { $0[$1.key.rawValue] = $1.value },
            globalSessionTemplate: globalSessionTemplate
        )
    }

    /// Rebuild the tree from a snapshot, reconciling against disk: a workspace or branch
    /// folder that was *confirmed deleted* (see `confirmedMissing`) is dropped — the user
    /// removed it outside Synth. A folder that's merely unreachable (unmounted volume,
    /// offline network path) is kept, so a transient absence never silently and permanently
    /// erases rows. Sessions come back dormant — kind/title/name only, status `.idle`, no
    /// live process; opening one respawns a shell (a Claude row resumes). Stale expansion
    /// ids for pruned rows are discarded.
    private func restore(from state: PersistedState) {
        var restored: [Workspace] = []
        var scripts: [UUID: String] = [:]
        var flags: [UUID: [AgentID: String]] = [:]
        var templates: [UUID: [SessionTemplateEntry]] = [:]
        var skips: [UUID: Bool] = [:]
        for pw in state.workspaces {
            guard !confirmedMissing(pw.url) else { continue }
            let branches: [Branch] = pw.branches.compactMap { pb -> Branch? in
                guard !confirmedMissing(pb.worktreeURL) else { return nil }
                let sessions = pb.sessions.map { ps in
                    Session(id: ps.id, kind: SessionKind(rawValue: ps.kind) ?? .terminal,
                            title: ps.title, status: .idle, titleIsCustom: ps.titleIsCustom,
                            agentSessionID: ps.resumeID, browserURL: ps.browserURL,
                            ownerSessionID: ps.ownerSessionID)
                }
                // Scrub hostless recents (about:blank) recorded before the filter existed.
                let recents = (pb.browserRecents ?? []).filter { URL(string: $0.url)?.host != nil }
                let br = Branch(id: pb.id, name: pb.name, worktreeURL: pb.worktreeURL,
                                sessions: sessions, lastActivity: pb.lastActivity,
                                lastActivityAt: pb.lastActivityAt,
                                browserRecents: recents, archivedAt: pb.archivedAt)
                br.lastCleanSweepEval = pb.lastCleanSweepEval
                // Restore the remembered split, resolving leaves against this branch's sessions;
                // an unresolved leaf (e.g. a runtime browser that didn't come back) collapses (014).
                br.layout = deserializeLayout(pb.layout, valid: Set(sessions.map(\.id)))
                // Migration: a pre-timestamp snapshot carries no activity Date. Seed live branches
                // at load so the relative label decays from here instead of showing a stale string;
                // real activity thereafter stamps and persists its own Date.
                if br.lastActivityAt == nil, !br.sessions.isEmpty { br.markActivity() }
                return br
            }
            restored.append(Workspace(id: pw.id, name: pw.name, url: pw.url,
                                      branches: branches, colorIndex: pw.colorIndex))
            if let s = pw.setupScript { scripts[pw.id] = s }
            if let f = pw.effectiveAgentFlags { flags[pw.id] = f }
            if let t = pw.sessionTemplate, !t.isEmpty { templates[pw.id] = t }
            if pw.skipSharedSetup == true { skips[pw.id] = true }
        }
        workspaces = restored
        wsScripts = scripts
        wsAgentFlags = flags
        wsSessionTemplates = templates
        wsSkipScript = skips
        // Global settings: a nil (pre-settings snapshot) keeps the built-in default. A
        // pre-agents snapshot carries only Claude's flags — merge, don't replace, or the
        // other agents' defaults vanish.
        if let gs = state.globalScript { globalScript = gs }
        if let gf = state.effectiveGlobalAgentFlags { globalAgentFlags.merge(gf) { _, new in new } }
        if let gt = state.globalSessionTemplate { globalSessionTemplate = gt }
        let liveIDs = Set(restored.flatMap { ws in
            [ws.id] + ws.branches.flatMap { [$0.id] + $0.sessions.map(\.id) }
        })
        expanded = Set(state.expanded).intersection(liveIDs)
    }

    /// True only when a folder is *confirmed deleted*: its parent directory exists but the
    /// folder itself doesn't. If the parent is also absent (unmounted volume, missing
    /// ancestor) the answer is false — the path is unreachable, not deleted, so we keep it.
    private func confirmedMissing(_ url: URL) -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) { return false }
        return fm.fileExists(atPath: url.deletingLastPathComponent().path)
    }

    /// Persist on a low cadence (backstop for any mutation) plus a flush on quit — cmux's
    /// timer-over-instrumentation model, so no mutation site can forget to save. The
    /// skip-if-unchanged check in the store keeps the idle case free.
    private func startAutosave() {
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                guard let self else { return }
                self.saveNow()
            }
        }
        // queue: nil so the block runs synchronously on the posting (main) thread — NSApp
        // posts willTerminate then exit()s in the same stack, so an async .main hop would
        // never fire. assumeIsolated is then the correct guard.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                // Synchronous flush, not the async saveNow(): willTerminate runs in the same stack
                // as the imminent exit(), so a queued async write would never reach disk.
                self?.flushSave()
                self?.stopArchiveSweep()
                // Engines must not outlive the app: a surviving instance owns the profile
                // singleton and silently absorbs the next launch (BrowserEngine.shutdown docs).
                BrowserManager.shared.shutdownAll()
                // Neither must session process trees: quitting doesn't route through
                // closeSession, so without this every open login → agent → MCP-server tree
                // orphans to launchd on quit.
                TerminalManager.shared.shutdownAll()
            }
        }
    }

    /// Synchronous state flush for app termination — snapshot on main, then block until the write
    /// queue has drained it to disk (PersistenceStore.flush), so quitting never loses the last edit.
    func flushSave() { PersistenceStore.flush(snapshot()) }

    func saveNow() {
        PersistenceStore.save(snapshot())
        syncAgentBridge()
    }

    #if DEBUG
    // Design-time notification harness (working.html's ⌥N demo). Fires fake transitions on
    // real background sessions so the deck, hover-fan, ⌘↩-jump, "+N" and ambient pulse are
    // observable without live session events. `force` lets a driven (non-frontmost) instance
    // still exercise either surface. Left `#if DEBUG`-gated for the maintainer to keep or cut.
    @ObservationIgnored private var debugCursor = 0

    /// ⌥F — force the deck's hover-fan open (the pointer can't reach an inactive window when
    /// driven headless), so the fanned state is screenshottable.
    var debugDeckSpread = false

    /// Sessions the deck may notify — everything except the open one (working.html demo `bg`).
    private var debugBackground: [Session] {
        workspaces.flatMap { $0.branches.flatMap(\.sessions) }.filter { $0.id != openSessionID }
    }

    private func debugReveal(_ s: Session) {
        guard let br = branch(of: s) else { return }
        expanded.insert(br.id)
        if let ws = workspace(of: br) { expanded.insert(ws.id) }
    }

    /// ⌥N — escalate the next background session; kinds cycle (mostly needs-input, every third
    /// an error) so successive presses grow a deck with real ordering and a "+N" past three.
    func debugRaiseNext(force: NotifRoute) {
        let bg = debugBackground
        guard !bg.isEmpty else { return }
        let s = bg[debugCursor % bg.count]
        debugReveal(s)
        let next: SessionStatus = (debugCursor % 3 == 1) ? .error : .needsInput
        debugCursor += 1
        let prev = s.status
        s.status = next
        routeTransition(s.id, prev: prev, next: next, force: force)
    }

    /// ⌥D — walk the next background session live→idle to fire "done" (row pulse + a transient
    /// toast on a terminal/browser, or a Notification Center banner when forced there).
    func debugFireDone(force: NotifRoute) {
        let bg = debugBackground
        guard !bg.isEmpty else { return }
        let s = bg[debugCursor % bg.count]
        debugReveal(s)
        debugCursor += 1
        s.status = .idle
        routeTransition(s.id, prev: .running, next: .idle, force: force)
    }

    /// ⌥C — clear every standing toast (reset the deck).
    func debugClearNotifs() { notifs.removeAll() }

    /// ⌥U — stage a build. Pressing it again winds the clock back a day and re-raises, so the
    /// daily reminder can be read as it will actually arrive rather than a day from now.
    func debugStageUpdate() {
        guard var update = stagedUpdate else {
            stageStubUpdate(version: AppStore.debugNextVersion())
            return
        }
        update.stagedAt = update.stagedAt.addingTimeInterval(-86_400)
        stagedUpdate = update
        UserDefaults.standard.set(update.stagedAt, forKey: AppStore.updateStagedKey)
        showUpdateCard()
    }

    /// This build's version with its last number bumped — a plausible next release to demo with,
    /// rather than a hardcoded one that ages badly.
    static func debugNextVersion() -> String {
        let short = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
        var parts = short.split(separator: "-")[0].split(separator: ".").map(String.init)
        guard let last = parts.last, let n = Int(last) else { return short + ".1" }
        parts[parts.count - 1] = String(n + 1)
        return parts.joined(separator: ".")
    }
    #endif
}
