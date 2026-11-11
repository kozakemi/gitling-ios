import SwiftUI
import UniformTypeIdentifiers

struct ConflictResolutionPage: View {
    @EnvironmentObject private var store: RepoStore
    @Environment(\.scenePhase) private var scenePhase
    let name: String
    @State private var snapshot: GitOperationSnapshot?
    @State private var error: String?
    @State private var confirmAbort = false
    @State private var refresh = 0

    var body: some View {
        List {
            if let error { Text(error).foregroundStyle(.red) }
            if let snapshot {
                Section {
                    Text(snapshot.kind?.title ?? String(localized: "Conflicts"))
                    if let step = snapshot.step, let total = snapshot.total {
                        Text("\(step) / \(total)").font(.caption.monospaced())
                    }
                    if snapshot.kind == .rebase {
                        Text("During rebase, Ours is the branch being rebased onto; Theirs is the commit being replayed.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if snapshot.isExternal {
                        Text("This operation was started outside Gitling. Resolve files here, then use the original Git tool to continue or abort.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if snapshot.kind != nil {
                        ConflictOperationActions(canContinue: snapshot.canContinue, canAbort: snapshot.canAbort,
                            busy: store.isBusy, onContinue: { store.continueOperation(name: name) }, onAbort: { confirmAbort = true })
                    }
                }
                Section("Unresolved files") {
                    if snapshot.conflicts.isEmpty { Text("No unresolved files") }
                    ForEach(snapshot.conflicts) { file in
                        NavigationLink {
                            ConflictFilePage(name: name, conflict: file)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(file.path).font(.body.monospaced())
                                if file.ours == nil || file.theirs == nil {
                                    Text("Deleted on one side").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                Section {
                    Text("Edit each file, then explicitly confirm its resolution. Continue only after every conflict is resolved and your edits are staged.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if !snapshot.needsAttention { Text("No operation in progress") }
                }
            } else if error == nil { ProgressView() }
        }
        .navigationTitle("Resolve conflicts")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { Button("Refresh", systemImage: "arrow.clockwise") { refresh += 1 }.disabled(store.isBusy) }
        .task(id: "\(store.revision):\(refresh)") { await load() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { refresh += 1 } }
        .confirmationDialog("Abort this Git operation?", isPresented: $confirmAbort, titleVisibility: .visible) {
            Button("Abort operation", role: .destructive) { store.abortOperation(name: name) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This restores the branch and tracked files to the state before the operation. Resolution edits will be discarded. Unrelated untracked files are kept.")
        }
    }

    private func load() async {
        let repo = store.repoURL(name)
        do {
            let value = try await Task.detached(priority: .userInitiated) { try GitClient.operation(at: repo) }.value
            guard !Task.isCancelled else { return }
            snapshot = value
            error = nil
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }
}

struct ConflictOperationActions: View {
    let canContinue: Bool
    let canAbort: Bool
    let busy: Bool
    let onContinue: () -> Void
    let onAbort: () -> Void
    var body: some View {
        AdaptiveActionGroup {
            Button("Continue operation", action: onContinue).disabled(busy || !canContinue)
            Button("Abort operation", role: .destructive, action: onAbort).disabled(busy || !canAbort)
        }
        .buttonStyle(.bordered)
    }
}

private struct ConflictFilePage: View {
    @EnvironmentObject private var store: RepoStore
    @Environment(\.dismiss) private var dismiss
    let name: String
    let conflict: ConflictFile
    @State private var side = 1
    @State private var preview: ConflictPreview?
    @State private var error: String?
    @State private var edit: ConflictEdit?
    @State private var exportURL: URL?
    @State private var importFile = false
    @State private var confirming = false
    @State private var deleting = false
    @State private var busy = false
    @State private var previewRevision = 0
    @State private var imported = false
    @Environment(\.scenePhase) private var scenePhase

    private var version: ConflictVersion? { side == 0 ? conflict.ancestor : side == 1 ? conflict.ours : conflict.theirs }
    var body: some View {
        List {
            Section {
                Text(conflict.path).font(.body.monospaced()).textSelection(.enabled)
                Picker("Conflict side", selection: $side) {
                    Text("Base").tag(0)
                    Text("Ours").tag(1)
                    Text("Theirs").tag(2)
                    Text("Working file").tag(3)
                }.pickerStyle(.menu)
                if let preview {
                    if preview.oid == nil { Text("Not present on this side") }
                    else {
                        if side != 3 { Text(preview.oid ?? "").font(.caption.monospaced()).textSelection(.enabled) }
                        if let text = preview.text {
                            Text(verbatim: text).font(.body.monospaced()).textSelection(.enabled)
                        } else {
                            Text("Binary or large content; use an external editor.")
                            Text(ByteCountFormatter.string(fromByteCount: Int64(preview.byteCount), countStyle: .file))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } else { ProgressView() }
            }
            Section("External editing") {
                Text("Export a copy to your editor, save the edited file, then import it here. Exporting alone does not update the repository. You can also edit the working file directly in Files.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("Prepare edit copy") { Task { await prepareEdit() } }.disabled(busy || store.isBusy)
                if let exportURL {
                    ShareLink(item: exportURL) { Label("Open edit copy", systemImage: "square.and.arrow.up") }
                    Button("Import edited file") { importFile = true }.disabled(busy || store.isBusy)
                }
            }
            Section {
                Button("Confirm resolution") { deleting = false; confirming = true }
                    .disabled(busy || store.isBusy)
                Button("Resolve as deletion", role: .destructive) { deleting = true; confirming = true }
                    .disabled(busy || store.isBusy)
                Text("Confirmation stages the current working file. Conflict markers must be removed first. For a deleted file, explicitly choose Resolve as deletion.")
                    .font(.footnote).foregroundStyle(.secondary)
                if imported { Text("Edited file imported. Review the working file, then confirm resolution.").font(.footnote).foregroundStyle(.secondary) }
                if let error { Text(error).foregroundStyle(.red) }
            }
        }
        .navigationTitle("Conflict file")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: "\(side):\(previewRevision)") { await loadPreview() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { previewRevision += 1 } }
        .task(id: store.revision) {
            let repo = store.repoURL(name)
            if let state = try? await Task.detached(operation: { try GitClient.operation(at: repo) }).value,
               !state.conflicts.contains(conflict), !Task.isCancelled { dismiss() }
        }
        .fileImporter(isPresented: $importFile, allowedContentTypes: [.item]) { result in
            guard case .success(let file) = result else {
                if case .failure(let failure) = result { error = failure.localizedDescription }
                return
            }
            Task { await importEdit(file) }
        }
        .confirmationDialog("Confirm conflict resolution?", isPresented: $confirming, titleVisibility: .visible) {
            Button(deleting ? String(localized: "Resolve as deletion") : String(localized: "Confirm resolution"), role: deleting ? .destructive : nil) {
                store.resolveConflict(name: name, conflict: conflict, delete: deleting)
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text(deleting ? String(localized: "The working file will be deleted and its deletion staged.") : String(localized: "The current working file will be staged as the resolution.")) }
        .onDisappear { removeExport() }
    }
    private func loadPreview() async {
        let repo = store.repoURL(name), version = version, conflict = conflict, working = side == 3
        preview = nil
        do {
            let value = try await Task.detached {
                try working ? GitClient.conflictWorkingPreview(at: repo, conflict: conflict) : GitClient.conflictPreview(at: repo, version: version)
            }.value
            guard !Task.isCancelled else { return }
            preview = value
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
    private func prepareEdit() async {
        busy = true
        defer { busy = false }
        let repo = store.repoURL(name), conflict = conflict
        do {
            let (value, file) = try await Task.detached {
                let value = try GitClient.conflictEdit(at: repo, conflict: conflict)
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("conflict-edit-" + UUID().uuidString)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let file = directory.appendingPathComponent(URL(fileURLWithPath: conflict.path).lastPathComponent)
                try value.contents.write(to: file, options: .atomic)
                return (value, file)
            }.value
            removeExport()
            edit = value
            exportURL = file
            error = nil
        } catch { self.error = error.localizedDescription }
    }
    private func importEdit(_ file: URL) async {
        guard let edit else { return }
        busy = true
        defer { busy = false }
        let repo = store.repoURL(name)
        do {
            try await Task.detached {
                let access = file.startAccessingSecurityScopedResource()
                defer { if access { file.stopAccessingSecurityScopedResource() } }
                try GitClient.importConflictEdit(at: repo, edit: edit, contents: GitClient.readConflictEditFile(at: file))
            }.value
            removeExport()
            self.edit = nil
            side = 3
            previewRevision += 1
            imported = true
            error = nil
        } catch { self.error = error.localizedDescription }
    }
    private func removeExport() {
        if let exportURL { try? FileManager.default.removeItem(at: exportURL.deletingLastPathComponent()) }
        exportURL = nil
    }
}
