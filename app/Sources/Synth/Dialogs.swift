import SwiftUI

/// Centered modal over a dimmed backdrop, scale-in — matches working.html's dialogs
/// (not a native top-attached sheet).
struct ModalBackdrop<Content: View>: View {
    let onDismiss: () -> Void
    @ViewBuilder var content: Content
    @State private var shown = false

    var body: some View {
        ZStack {
            Rectangle().fill(Color.black.opacity(0.16))
                .ignoresSafeArea()
                .opacity(shown ? 1 : 0)
                .onTapGesture(perform: onDismiss)
            content
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .shadow(color: .black.opacity(0.18), radius: 30, y: 14)
                .scaleEffect(shown ? 1 : 0.97)
                .opacity(shown ? 1 : 0)
        }
        .onAppear { withAnimation(.easeOut(duration: 0.18)) { shown = true } }
    }
}

/// Add-workspace step 2: pick which branches to show. Every checked branch becomes
/// a row backed by a real worktree folder — existing worktrees are pre-checked and
/// reused; the rest are created on Add.
struct AddWorktreesSheet: View {
    @Environment(AppStore.self) private var store
    let pending: PendingWorkspace
    let onClose: () -> Void

    @State private var selected: Set<UUID>
    @State private var cursor = 0
    @State private var submitted = false
    @State private var keyMonitor: Any?

    init(pending: PendingWorkspace, onClose: @escaping () -> Void) {
        self.pending = pending
        self.onClose = onClose
        _selected = State(initialValue: Set(pending.candidates.filter { $0.existingWorktree != nil }.map(\.id)))
    }

    var body: some View {
        DialogFrame(title: "Add worktrees — \(pending.url.lastPathComponent)") {
            // Lazy + scroll-tracked: a repo can bring hundreds of branches, so only the
            // visible rows are built and the keyboard cursor stays in view.
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(pending.candidates.enumerated()), id: \.element.id) { index, candidate in
                            CandidateRow(candidate: candidate,
                                         checked: selected.contains(candidate.id),
                                         cursor: cursor == index) {
                                cursor = index
                                toggle(candidate)
                            }
                            .id(candidate.id)
                        }
                    }
                }
                .frame(maxHeight: 264)
                .onChange(of: cursor) { _, i in
                    guard pending.candidates.indices.contains(i) else { return }
                    proxy.scrollTo(pending.candidates[i].id, anchor: .center)
                }
            }
        } actions: {
            Button("Cancel", action: onClose).keyboardShortcut(.cancelAction)
            Button("Add \(selected.count)", action: submit)
                .keyboardShortcut(.defaultAction)
                .disabled(selected.isEmpty)
        }
        // Keyboard-first (like the tree): ↑/↓ move, Space toggles, Enter adds.
        .onAppear {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                switch event.keyCode {
                case 125: cursor = min(cursor + 1, pending.candidates.count - 1); return nil  // ↓
                case 126: cursor = max(cursor - 1, 0); return nil                             // ↑
                case 49:  toggle(pending.candidates[cursor]); return nil                      // space
                case 36:  submit(); return nil                                                // return
                default:  return event
                }
            }
        }
        .onDisappear {
            if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        }
    }

    private func toggle(_ candidate: BranchCandidate) {
        if selected.contains(candidate.id) { selected.remove(candidate.id) }
        else { selected.insert(candidate.id) }
    }

    private func submit() {
        guard !submitted, !selected.isEmpty else { return }
        submitted = true
        store.confirmAddWorkspace(pending, selected: selected)
        onClose()
    }
}

private struct CandidateRow: View {
    let candidate: BranchCandidate
    let checked: Bool
    let cursor: Bool
    let toggle: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 9) {
                Checkbox(on: checked)
                Text(candidate.name)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.repoName)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                Text(candidate.age)
                    .font(.system(size: 10.5)).foregroundStyle(Theme.branchMeta).monospacedDigit()
                Text(candidate.existingWorktree != nil ? "has worktree" : (checked ? "will create" : ""))
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.inkFaint)
                    .frame(width: 74, alignment: .trailing)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(cursor ? Theme.rowSelected : (hovering ? Theme.rowHover : .clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Theme.selRing, lineWidth: 1.5)
                    .opacity(cursor ? 1 : 0)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct Checkbox: View {
    let on: Bool
    var body: some View {
        RoundedRectangle(cornerRadius: 4.5)
            .fill(on ? Theme.input.opacity(0.9) : Theme.raised)
            .overlay(
                RoundedRectangle(cornerRadius: 4.5)
                    .strokeBorder(on ? Color.clear : Theme.line, lineWidth: 1)
            )
            .overlay(
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .opacity(on ? 1 : 0)
            )
            .frame(width: 16, height: 16)
    }
}

/// Kebab "Create worktree…": check an existing branch out into a worktree, or cut
/// a new branch off a base — either way the result is a real folder that becomes a
/// row. Enter submits, Esc/backdrop cancels.
struct CreateWorktreeSheet: View {
    @Environment(AppStore.self) private var store
    let workspace: Workspace
    let onClose: () -> Void

    private enum Mode: String, CaseIterable {
        case existing = "Existing branch"
        case new = "New branch"
    }

    @State private var mode: Mode = .existing
    @State private var available: [String] = []   // branches without a row yet
    @State private var allBranches: [String] = []
    @State private var existing = ""
    @State private var base = ""
    @State private var name = ""
    @State private var submitted = false
    @FocusState private var nameFocused: Bool

    private var canCreate: Bool {
        switch mode {
        case .existing: return !existing.isEmpty
        case .new:      return !name.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    var body: some View {
        DialogFrame(title: "New branch") {
            Picker("", selection: $mode) {
                ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden().pickerStyle(.segmented)

            switch mode {
            case .existing:
                Field(label: "Branch") {
                    if available.isEmpty {
                        Text("All branches are already shown")
                            .font(.system(size: 11.5)).foregroundStyle(Theme.inkFaint)
                    } else {
                        Picker("", selection: $existing) {
                            ForEach(available, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden().pickerStyle(.menu)
                    }
                }
            case .new:
                Field(label: "Base branch") {
                    Picker("", selection: $base) {
                        ForEach(allBranches, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.menu)
                }
                Field(label: "Branch name") {
                    TextField("feat/…", text: Binding(
                        get: { name },
                        set: { name = dashSpaces($0) }))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .focused($nameFocused)
                        .onSubmit(submit)
                }
            }

        } actions: {
            Button("Cancel", action: onClose).keyboardShortcut(.cancelAction)
            Button("Create", action: submit).keyboardShortcut(.defaultAction).disabled(!canCreate)
        }
        .onAppear {
            // for-each-ref off the main thread — a large/cold repo can take a beat.
            let repo = workspace.url
            let shown = Set(workspace.branches.map(\.name))
            Task {
                let names = await Task.detached(priority: .userInitiated) {
                    GitService.branches(at: repo).map(\.name)
                }.value
                allBranches = names
                available = names.filter { !shown.contains($0) }
                existing = available.first ?? ""
                base = names.first ?? ""
                if available.isEmpty { mode = .new }
            }
        }
        .onChange(of: mode) { _, m in
            if m == .new {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { nameFocused = true }
            }
        }
    }

    /// Creation errors surface later through the pending row's toast — the sheet's job
    /// ends the moment the pending row is in the tree, so it just closes.
    private func submit() {
        guard !submitted, canCreate else { return }
        submitted = true
        switch mode {
        case .existing:
            store.createWorktree(in: workspace, existingBranch: existing)
        case .new:
            store.createWorktree(in: workspace,
                                 newBranch: name.trimmingCharacters(in: .whitespaces),
                                 base: base.isEmpty ? nil : base)
        }
        onClose()
    }
}

/// Feedback (⌘⇧F). Send routes on `store.feedbackMode`: the author names a fix (title, required)
/// and optionally details it, spawning a `feedback/<slug>` worktree; everyone else gets a
/// pre-filled email from the one box. Enter is a newline, ⌘↵ sends, Esc dismisses (handled
/// centrally in the key monitor). Title + draft persist across reopens.
struct FeedbackSheet: View {
    @Environment(AppStore.self) private var store
    @FocusState private var focused: Bool
    @FocusState private var titleFocused: Bool
    @State private var submitted = false

    private var isAuthor: Bool { store.feedbackMode == .author }

    /// Author names the fix (title is the branch); everyone else just needs the one box.
    private var canSend: Bool {
        let field = isAuthor ? store.feedbackTitle : store.feedbackDraft
        return !field.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        @Bindable var store = store
        VStack(alignment: .leading, spacing: 13) {
            if isAuthor {
                TextField("Name this fix", text: $store.feedbackTitle)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, weight: .medium))
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .frame(width: 428, alignment: .leading)
                    .background(Theme.raised)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10)
                        .stroke(titleFocused ? Theme.accent : Theme.line, lineWidth: titleFocused ? 2 : 0.5))
                    .focused($titleFocused)
                    .onSubmit { focused = true }
            }
            TextEditor(text: $store.feedbackDraft)
                .font(.system(size: 14))
                .scrollContentBackground(.hidden)
                .padding(7)
                .frame(width: 428, height: 96, alignment: .topLeading)
                .background(Theme.raised)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .stroke(focused ? Theme.accent : Theme.line, lineWidth: focused ? 2 : 0.5))
                .overlay(alignment: .topLeading) {
                    if store.feedbackDraft.isEmpty {
                        Text(isAuthor ? "Add detail (optional)" : "What's off?")
                            .font(.system(size: 14)).foregroundStyle(Theme.inkFaint)
                            .padding(.horizontal, 12).padding(.vertical, 15)
                            .allowsHitTesting(false)
                    }
                }
                .focused($focused)

            HStack {
                Text("esc to dismiss").font(.system(size: 11)).foregroundStyle(Theme.inkFaint)
                Spacer()
                Button(action: send) {
                    HStack(spacing: 6) { Text("Send"); Text("⌘↵").opacity(0.75) }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(!canSend)
            }
        }
        .padding(16)
        .frame(width: 460)
        .background(Theme.panel)
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
            if isAuthor { titleFocused = true } else { focused = true }
        } }
    }

    private func send() {
        guard !submitted, canSend else { return }
        submitted = true
        store.submitFeedback(store.feedbackDraft)
    }
}

// MARK: - Shared chrome

private struct DialogFrame<Content: View, Actions: View>: View {
    let title: String
    @ViewBuilder let content: Content
    @ViewBuilder let actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.ink)
            content
            HStack(spacing: 8) { Spacer(); actions }
        }
        .padding(20)
        .frame(width: 340)
        .background(Theme.panel)
    }
}

private struct Field<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.inkMuted)
            content
        }
    }
}
