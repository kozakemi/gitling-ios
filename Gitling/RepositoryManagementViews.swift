import SwiftUI

struct StashPage: View {
    @EnvironmentObject private var store: RepoStore
    let name: String
    @State private var entries: [StashEntry] = []
    @State private var message = ""
    @State private var includeUntracked = true
    @State private var loading = true
    @State private var error: String?
    @State private var pendingDelete: StashEntry?

    var body: some View {
        List {
            Section("Save Stash") {
                TextField("Stash message", text: $message)
                Toggle("Include untracked files", isOn: $includeUntracked)
                Button("Save Stash") {
                    store.saveStash(name: name, message: message, includeUntracked: includeUntracked)
                    message = ""
                }
                .disabled(store.isBusy)
            }
            Section("Saved Stashes") {
                if loading { ProgressView() }
                if let error = error ?? store.alert { Text(error).foregroundStyle(.secondary) }
                else if !loading && entries.isEmpty { Text("No stashes").foregroundStyle(.secondary) }
                ForEach(entries) { entry in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(verbatim: "stash@{\(entry.index)}").font(.caption.monospaced()).foregroundStyle(.secondary)
                        Text(entry.message)
                        AdaptiveActionGroup {
                            Button("Apply Stash") { store.applyStash(name: name, oid: entry.oid, pop: false) }
                            Button("Pop Stash") { store.applyStash(name: name, oid: entry.oid, pop: true) }
                            Button("Delete", role: .destructive) { pendingDelete = entry }
                        }
                        .buttonStyle(.bordered)
                        .disabled(store.isBusy)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .navigationTitle("Stash")
        .toolbar { if store.isBusy { ProgressView() } }
        .task(id: store.revision) {
            let url = store.repoURL(name)
            loading = true
            do {
                let loaded = try await Task.detached(priority: .userInitiated) { try GitClient.stashes(at: url) }.value
                guard !Task.isCancelled else { return }
                entries = loaded
                error = nil
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
            loading = false
        }
        .confirmationDialog("Delete this stash?", isPresented: Binding(
            get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }
        ), titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let pendingDelete { store.dropStash(name: name, oid: pendingDelete.oid) }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("This permanently removes the saved changes in this stash.")
        }
    }
}

struct BranchManagementPage: View {
    @EnvironmentObject private var store: RepoStore
    let name: String
    @State private var branches: [BranchInfo] = []
    @State private var error: String?

    var body: some View {
        List {
            if let error = error ?? store.alert { Text(error).foregroundStyle(.secondary) }
            ForEach(branches.filter { !$0.isRemote }) { branch in
                NavigationLink {
                    BranchSettingsPage(name: name, branch: branch, remoteBranches: branches.filter { $0.isRemote && !$0.name.hasSuffix("/HEAD") })
                } label: {
                    LabeledContent(branch.name) { if branch.isCurrent { Text("Current") } }
                }
            }
        }
        .navigationTitle("Manage Branches and Upstream")
        .task(id: store.revision) {
            let url = store.repoURL(name)
            do {
                let loaded = try await Task.detached(priority: .userInitiated) { try GitClient.branches(at: url) }.value
                guard !Task.isCancelled else { return }
                branches = loaded
                error = nil
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
        }
    }
}

private struct BranchSettingsPage: View {
    @EnvironmentObject private var store: RepoStore
    @Environment(\.dismiss) private var dismiss
    let name: String
    let branch: BranchInfo
    let remoteBranches: [BranchInfo]
    @State private var newName = ""
    @State private var upstream = ""
    @State private var error: String?
    @State private var confirmDelete = false

    var body: some View {
        Form {
            Section("Rename Branch") {
                TextField("Branch name", text: $newName).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Rename Branch") {
                    store.renameBranch(name: name, branch: branch.name, to: newName)
                    dismiss()
                }
                .disabled(store.isBusy || newName == branch.name || !GitClient.isValidBranchName(newName))
            }
            Section("Upstream") {
                Picker("Upstream", selection: $upstream) {
                    Text("None").tag("")
                    if !upstream.isEmpty && !remoteBranches.contains(where: { $0.name == upstream }) {
                        Text(upstream).tag(upstream)
                    }
                    ForEach(remoteBranches) { Text($0.name).tag($0.name) }
                }
                Button("Set Upstream") { store.setUpstream(name: name, branch: branch.name, upstream: upstream.isEmpty ? nil : upstream) }
                    .disabled(store.isBusy)
                if let error = error ?? store.alert { Text(error).foregroundStyle(.secondary) }
            }
            if !branch.isCurrent {
                Section {
                    Button("Delete Branch", role: .destructive) { confirmDelete = true }.disabled(store.isBusy)
                } footer: { Text("Only branches merged into the current branch can be deleted.") }
            }
        }
        .navigationTitle(branch.name)
        .toolbar { if store.isBusy { ProgressView() } }
        .task(id: store.revision) {
            if newName.isEmpty { newName = branch.name }
            let url = store.repoURL(name)
            let branchName = branch.name
            do {
                let loaded = try await Task.detached(priority: .userInitiated) { try GitClient.upstream(at: url, branch: branchName) }.value
                guard !Task.isCancelled else { return }
                upstream = loaded ?? ""
                error = nil
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
        }
        .confirmationDialog("Delete this branch?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Branch", role: .destructive) {
                store.deleteBranch(name: name, branch: branch.name)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}
