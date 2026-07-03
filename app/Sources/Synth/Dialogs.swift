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

/// New-branch modal: base-branch picker + name field, Create disabled until named,
/// Enter submits, Esc/backdrop cancels.
struct CreateBranchSheet: View {
    @Environment(AppStore.self) private var store
    let workspace: Workspace
    let onClose: () -> Void

    @State private var base: String = ""
    @State private var name: String = ""
    @FocusState private var nameFocused: Bool

    private var canCreate: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        DialogFrame(title: "New branch") {
            Field(label: "Base branch") {
                Picker("", selection: $base) {
                    ForEach(workspace.branches.map(\.name), id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden().pickerStyle(.menu)
            }
            Field(label: "Branch name") {
                TextField("feat/…", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .focused($nameFocused)
                    .onSubmit(submit)
            }
        } actions: {
            Button("Cancel", action: onClose).keyboardShortcut(.cancelAction)
            Button("Create", action: submit).keyboardShortcut(.defaultAction).disabled(!canCreate)
        }
        .onAppear {
            base = workspace.branches.first?.name ?? "main"
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { nameFocused = true }
        }
    }

    private func submit() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        store.newBranch(in: workspace, name: trimmed)
        onClose()
    }
}

/// Add-workspace modal: a single Repository field.
struct AddWorkspaceSheet: View {
    @Environment(AppStore.self) private var store
    let onClose: () -> Void

    @State private var path: String = ""
    @FocusState private var focused: Bool

    private var canAdd: Bool { !path.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        DialogFrame(title: "Add workspace") {
            Field(label: "Repository") {
                TextField("~/code/my-repo", text: $path)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit(submit)
            }
        } actions: {
            Button("Cancel", action: onClose).keyboardShortcut(.cancelAction)
            Button("Add", action: submit).keyboardShortcut(.defaultAction).disabled(!canAdd)
        }
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { focused = true } }
    }

    private func submit() {
        guard canAdd else { return }
        store.addWorkspace(pathOrName: path)
        onClose()
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
