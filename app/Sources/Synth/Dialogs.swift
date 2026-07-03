import SwiftUI

/// New-branch modal: base-branch picker + name field, Create disabled until named,
/// Enter submits, Esc cancels (working.html's dialog).
struct CreateBranchSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let workspace: Workspace

    @State private var base: String = ""
    @State private var name: String = ""

    private var canCreate: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        DialogFrame(title: "New branch") {
            Field(label: "Base branch") {
                Picker("", selection: $base) {
                    ForEach(workspace.branches.map(\.name), id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
            Field(label: "Branch name") {
                TextField("feat/…", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(submit)
            }
        } actions: {
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Button("Create", action: submit)
                .keyboardShortcut(.defaultAction)
                .disabled(!canCreate)
        }
        .onAppear { base = workspace.branches.first?.name ?? "main" }
    }

    private func submit() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        store.newBranch(in: workspace, name: trimmed)
        dismiss()
    }
}

/// Add-workspace modal: a single Repository field.
struct AddWorkspaceSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var path: String = ""

    private var canAdd: Bool { !path.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        DialogFrame(title: "Add workspace") {
            Field(label: "Repository") {
                TextField("~/code/my-repo", text: $path)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(submit)
            }
        } actions: {
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Button("Add", action: submit)
                .keyboardShortcut(.defaultAction)
                .disabled(!canAdd)
        }
    }

    private func submit() {
        guard canAdd else { return }
        store.addWorkspace(pathOrName: path)
        dismiss()
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
