import SwiftUI
import AppKit

/// A throwaway shell summoned by ⌘⇧T, for the errand you finish and leave — `aws sso login`,
/// a one-off script. Deliberately **not** a Session: no sidebar row, no status, no roll-up,
/// nothing persisted. It holds a `Session` object only because the whole terminal stack
/// (TerminalManager, the hook environment, the per-command reporter) is keyed by one — but
/// that object is never appended to a branch, and staying out of `ws.branches` is precisely
/// what keeps it out of the tree, the roll-up, ⌘K and `state.json`.
///
/// Dismissing kills it, so every summon is a fresh shell. The rule that buys is that nothing
/// is ever left running that the sidebar doesn't show — which is also why closing it while a
/// job holds the foreground confirms (ADR-0013).
@MainActor @Observable final class ScratchTerminal {
    let session: Session
    let branchName: String
    let cwd: URL

    /// A foreground job is running. Driven by the same zsh preexec/precmd reporter that greens
    /// a terminal row, routed here by `AppStore.applyScratch` because this session isn't in the
    /// tree for `session(id)` to find. It decides two things: whether Esc reaches the shell,
    /// and whether dismissing confirms.
    var busy = false
    /// What that job is, for the confirm's consequence line. The reporter sends the command
    /// line as the row title; a job that outran the 0.5s gate before naming itself is "the
    /// running command".
    var runningCommand = ""

    init(branchName: String, cwd: URL) {
        self.session = Session(kind: .terminal, title: "scratch", status: .idle)
        self.branchName = branchName
        self.cwd = cwd
    }
}

extension AppStore {
    /// ⌘⇧T — summon or dismiss. A pure toggle: a ⌘ chord is the only dismissal a running
    /// process can never swallow.
    func toggleScratchTerminal() {
        if scratch == nil { openScratchTerminal() } else { requestCloseScratchTerminal() }
    }

    /// Where it runs resolves through the ladder ⌘T/⌘N already walk. A pending branch has no
    /// checkout to run in yet, the same guard `addSession` applies — so "creates the worktree
    /// exactly as a session would" (ADR-0004) falls out rather than being reimplemented.
    func openScratchTerminal() {
        guard scratch == nil, let br = contextBranchForNewSession(), !br.isPending else { return }
        if palette != nil { closePalette() }
        activeMenu = nil
        shortcutsOpen = false
        scratch = ScratchTerminal(branchName: br.name, cwd: br.worktreeURL)
        Analytics.capture("scratch_terminal_opened", [:])
    }

    /// The dismissal every route goes through — ⌘⇧T, ⌘W, Esc at an idle prompt.
    func requestCloseScratchTerminal() {
        guard let s = scratch else { return }
        if s.busy { scratchConfirmOpen = true; return }
        closeScratchTerminal()
    }

    /// Kills the PTY. Nothing survives to come back to — that is the whole contract.
    func closeScratchTerminal() {
        guard let s = scratch else { return }
        scratchConfirmOpen = false
        scratch = nil
        TerminalManager.shared.terminate(s.session.id)
    }

    /// The scratch session isn't in the tree, so `session(id)` can't find it and every event it
    /// raises would otherwise fall through `apply` as an unknown id. Route them here instead:
    /// the per-command reporter drives the busy dot and names the running job, and a clean exit
    /// (`exit`, ⌃D) closes the overlay. Returns true when the event was the scratch's.
    func applyScratch(_ event: SessionEvent) -> Bool {
        guard let s = scratch else { return false }
        switch event {
        case let .statusChanged(id, status) where id == s.session.id:
            s.busy = status.isLive
            if !status.isLive { s.runningCommand = "" }
            return true
        case let .titleChanged(id, title) where id == s.session.id:
            s.runningCommand = title
            return true
        case let .exited(id, _) where id == s.session.id:
            closeScratchTerminal()
            return true
        // Everything else this session can raise — unread marks, exit codes, agent detection —
        // is meaningless for a row that doesn't exist. Swallow it rather than let it look up a
        // session that isn't there.
        case let .markUnread(id) where id == s.session.id,
             let .exitCodeReported(id, _) where id == s.session.id,
             let .kindChanged(id, _) where id == s.session.id,
             let .agentSessionCaptured(id, _) where id == s.session.id,
             let .agentReady(id) where id == s.session.id,
             let .titleReset(id) where id == s.session.id:
            return true
        default:
            return false
        }
    }
}

// MARK: - Overlay

/// working.html `.scr--overlay` — a centred card over a 0.5 dim. The dim runs deeper than a
/// dialog's 0.16 because this is a detour out of the app rather than a step within it, so the
/// work behind should read as parked. No chrome but the branch name: with no sidebar row, the
/// foot is the only place it can say where it is.
struct ScratchTerminalOverlay: View {
    @Environment(AppStore.self) private var store
    let scratch: ScratchTerminal
    @State private var shown = false

    var body: some View {
        ZStack {
            Rectangle().fill(Color.black.opacity(0.5))
                .ignoresSafeArea()
                .opacity(shown ? 1 : 0)

            GeometryReader { geo in
                card
                    .frame(width: min(680, geo.size.width - 120),
                           height: min(400, geo.size.height - 200))
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
            }
            .scaleEffect(shown ? 1 : 0.96)
            .opacity(shown ? 1 : 0)

            if store.scratchConfirmOpen { confirm }
        }
        .onAppear { withAnimation(.easeOut(duration: 0.2)) { shown = true } }
    }

    private var card: some View {
        VStack(spacing: 0) {
            TerminalHost(terminal: TerminalManager.shared.view(for: scratch.session, cwd: scratch.cwd))
                .padding(.top, 11).padding(.horizontal, 14)
            foot
        }
        .background(Theme.tuiBg)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.tuiHair, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.26), radius: 22, y: 12)
    }

    /// working.html `.scr__foot`. The amber dot is the only non-text signal kept, and it is
    /// load-bearing: with a job in the foreground Esc belongs to the shell, and the dot is
    /// what says so.
    private var foot: some View {
        HStack(spacing: 7) {
            if scratch.busy {
                Circle().fill(Theme.working).frame(width: 6, height: 6)
                    .opacity(shown ? 1 : 0.35)
            }
            Text(scratch.branchName)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.inkMuted)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .frame(height: 30)
        .padding(.horizontal, 14)
        .padding(.bottom, 2)
    }

    /// Closing while busy confirms and states the consequence — the same Close rule every
    /// session wears (ADR-0013). Esc cancels, ⏎ confirms; Close is red because it ends something.
    private var confirm: some View {
        ModalBackdrop(onDismiss: { store.scratchConfirmOpen = false }) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Close scratch terminal?")
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.ink)
                consequence
                    .font(.system(size: 12.5)).foregroundStyle(Theme.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Spacer()
                    Button("Cancel") { store.scratchConfirmOpen = false }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 15).padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.raised))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border, lineWidth: 0.5))
                    Button("Close") { store.closeScratchTerminal() }
                        .buttonStyle(.plain)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 15).padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.danger))
                }
            }
            .padding(20)
            .frame(width: 340)
            .background(Theme.panel)
        }
    }

    /// The command is set in mono, working.html's `<code>` chip — it's a thing you typed, not prose.
    private var consequence: Text {
        let job = scratch.runningCommand.isEmpty ? "the running command" : scratch.runningCommand
        return Text("Closing ends ")
            + Text(job).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.ink)
            + Text(". Nothing in a scratch terminal is saved.")
    }
}
