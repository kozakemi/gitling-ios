import SwiftUI
import UniformTypeIdentifiers

struct RepoDetailView: View {
    @EnvironmentObject private var store: RepoStore
    let name: String

    @State private var section = 0
    @State private var branch = ""
    @State private var origin = ""
    @State private var files: [WorkEntry] = []
    @State private var history: [CommitInfo] = []
    @State private var changes: [StatusEntry] = []
    @State private var username = ""
    @State private var secret = ""
    @State private var savedAccount: String?
    @State private var message = ""
    @State private var loadError: String?
    @State private var linkedFolder: String?
    @State private var pickFolder = false
    @State private var allBranches = false
    @State private var branches: [BranchInfo] = []
    @State private var remotes: [RemoteInfo] = []
    @State private var sync: SyncCounts?
    @State private var statusText = ""
    @State private var showOperations = false
    @State private var consoleLines: [ConsoleLine] = []
    @State private var command = ""
    @ScaledMetric(relativeTo: .body) private var commitRowHeight: CGFloat = 56

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                if !branch.isEmpty {
                    Text(branch)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let linkedFolder {
                    Text(String(format: String(localized: "Working folder is %@."), linkedFolder))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Picker("Section", selection: $section) {
                    Text("Files").tag(0)
                    Text("Commits").tag(1)
                    Text("Status").tag(2)
                    Text("Console").tag(3)
                }
                .pickerStyle(.segmented)
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 8)

            Group {
                switch section {
                case 0:
                    FileBrowser(repo: repoURL, directory: "", revision: store.revision)
                case 1:
                    historyList
                case 2:
                    statusView
                default:
                    consoleView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let loadError {
                Text(loadError)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button("Operations", systemImage: "ellipsis.circle") { showOperations = true }
                .disabled(store.isBusy)
        }
        .sheet(isPresented: $showOperations) {
            RepoOperationsSheet(
                name: name,
                branch: branch,
                origin: origin,
                branches: branches,
                remotes: remotes,
                username: $username,
                secret: $secret,
                message: $message,
                savedAccount: savedAccount,
                linked: linkedFolder != nil,
                onLink: {
                    showOperations = false
                    pickFolder = true
                }
            )
        }
        .fileImporter(isPresented: $pickFolder, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
            guard case .success(let urls) = result, let url = urls.first else {
                if case .failure(let error) = result {
                    let cocoa = error as NSError
                    if cocoa.domain == NSCocoaErrorDomain && cocoa.code == CocoaError.userCancelled.rawValue { return }
                }
                store.alert = String(localized: "Could not use that folder.")
                return
            }
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            do {
                let bookmark = try WorktreeLink.bookmark(for: url)
                store.link(name: name, bookmark: bookmark)
            } catch {
                store.alert = String(localized: "Could not use that folder.")
            }
        }
        .task(id: store.revision) { await load() }
        .onChange(of: allBranches) { _, _ in
            Task { await load() }
        }
    }

    private var repoURL: URL { store.repoURL(name) }

    private var historyList: some View {
        let rows = CommitGraph.rows(from: history)
        return Group {
            if rows.isEmpty {
                ContentUnavailableView("No commits yet", systemImage: "clock")
            } else {
                List {
                    Section {
                        Picker("Branches", selection: $allBranches) {
                            Text("This branch").tag(false)
                            Text("All branches").tag(true)
                        }
                        .pickerStyle(.segmented)
                        ForEach(branches.filter { !$0.isRemote }) { item in
                            Button {
                                store.checkout(name: name, branch: item.name)
                            } label: {
                                Label(item.name, systemImage: item.isCurrent ? "checkmark" : "arrow.triangle.branch")
                            }
                            .disabled(item.isCurrent || store.isBusy)
                        }
                    }
                    Section {
                        ForEach(rows) { row in
                            NavigationLink {
                                CommitDetailView(repo: repoURL, commit: row.commit)
                            } label: {
                                HStack(alignment: .top, spacing: 8) {
                                    CommitGraphMark(row: row)
                                        .frame(height: commitRowHeight)
                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                                            Text(String(row.commit.id.prefix(7)))
                                                .font(.caption2.monospaced())
                                                .foregroundStyle(.secondary)
                                            Text(row.commit.summary)
                                                .font(.body)
                                                .lineLimit(1)
                                                .truncationMode(.tail)
                                        }
                                        Text("\(row.commit.author) · \(row.commit.date.formatted(date: .abbreviated, time: .shortened))")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    .padding(.vertical, 7)
                                }
                                .frame(height: commitRowHeight)
                            }
                            .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 12))
                            .listRowSeparator(.hidden)
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }
        }
    }

    private var statusView: some View {
        List {
            Section("Status") {
                Text(statusText.isEmpty ? String(localized: "No changes") : statusText)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                if let sync, sync.ahead > 0 || sync.behind > 0 {
                    Text(String(format: String(localized: "Your branch is %@ ahead and %@ behind."), "\(sync.ahead)", "\(sync.behind)"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Section("Changes") {
                if changes.isEmpty {
                    Text("No changes").foregroundStyle(.secondary)
                } else {
                    ForEach(changes) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.path).font(.body.monospaced())
                            Text(label(entry))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    private var consoleView: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if consoleLines.isEmpty {
                        Text("Commands: status, log, diff, branch, help. This is not a shell.")
                            .font(.footnote.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    ForEach(consoleLines) { line in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("$ \(line.command)").font(.body.monospaced())
                            Text(line.output).font(.caption.monospaced()).textSelection(.enabled)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            HStack {
                TextField("git status", text: $command)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.body.monospaced())
                    .onSubmit(runCommand)
                Button("Run", action: runCommand)
                    .disabled(command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }

    private func label(_ entry: StatusEntry) -> String {
        if entry.untracked { return String(localized: "Untracked") }
        if entry.staged && entry.unstaged { return String(localized: "Staged and unstaged") }
        if entry.staged { return String(localized: "Staged") }
        return String(localized: "Unstaged")
    }

    private func runCommand() {
        let line = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return }
        command = ""
        let url = repoURL
        let output = GitClient.commandOutput(at: url, line: line)
        consoleLines.append(ConsoleLine(command: line, output: output))
    }

    private func load() async {
        let url = repoURL
        let everyBranch = allBranches
        let loaded = await Task.detached { () -> Loaded in
            let summary = GitClient.list(root: url.deletingLastPathComponent()).first { $0.name == url.lastPathComponent }
            let history = (try? GitClient.history(at: url, allBranches: everyBranch)) ?? []
            let changes = (try? GitClient.status(at: url)) ?? []
            let branches = (try? GitClient.branches(at: url)) ?? []
            let remotes = (try? GitClient.remotes(at: url)) ?? []
            let sync = GitClient.syncCounts(at: url)
            let statusText = (try? GitClient.statusText(at: url)) ?? ""
            return Loaded(
                branch: summary?.branch ?? "",
                origin: summary?.origin ?? "",
                history: history,
                changes: changes,
                branches: branches,
                remotes: remotes,
                sync: sync,
                statusText: statusText
            )
        }.value
        branch = loaded.branch
        origin = loaded.origin
        history = loaded.history
        changes = loaded.changes
        branches = loaded.branches
        remotes = loaded.remotes
        sync = loaded.sync
        statusText = loaded.statusText
        savedAccount = GitClient.host(of: loaded.origin).flatMap { KeychainStore.load(host: $0)?.username }
        linkedFolder = GitClient.linkedFolderName(at: repoURL)
    }
}

private struct ConsoleLine: Identifiable {
    let id = UUID()
    var command: String
    var output: String
}

private struct Loaded {
    var branch: String
    var origin: String
    var history: [CommitInfo]
    var changes: [StatusEntry]
    var branches: [BranchInfo]
    var remotes: [RemoteInfo]
    var sync: SyncCounts?
    var statusText: String
}

private struct FileBrowser: View {
    let repo: URL
    let directory: String
    var revision: Int = 0
    @State private var entries: [WorkEntry] = []
    @State private var error: String?

    var body: some View {
        Group {
            if let error {
                ContentUnavailableView("Files", systemImage: "doc", description: Text(error))
            } else if entries.isEmpty {
                ContentUnavailableView("Empty folder", systemImage: "doc")
            } else {
                List(entries) { entry in
                    if entry.isDirectory {
                        NavigationLink {
                            FileBrowser(repo: repo, directory: entry.path, revision: revision)
                                .navigationTitle(entry.name)
                        } label: {
                            Label(entry.name, systemImage: "folder")
                        }
                    } else {
                        NavigationLink {
                            FilePreview(repo: repo, relative: entry.path, name: entry.name)
                        } label: {
                            Label(entry.name, systemImage: "doc.text")
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
        .task(id: revision) { load() }
    }

    private func load() {
        do {
            entries = try GitClient.entries(at: repo, directory: directory)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct CommitDetailView: View {
    let repo: URL
    let commit: CommitInfo
    @State private var text = ""
    @State private var error: String?
    @State private var isLoading = true

    var body: some View {
        Group {
            if let error {
                ContentUnavailableView("Commits", systemImage: "clock", description: Text(error))
            } else if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if text.isEmpty {
                Text(commit.summary)
                    .font(.body.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            } else {
                ScrollView([.horizontal, .vertical]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                            Text(line.isEmpty ? " " : line)
                                .font(.caption.monospaced())
                                .fixedSize(horizontal: true, vertical: false)
                                .textSelection(.enabled)
                        }
                    }
                    .padding()
                }
            }
        }
        .navigationTitle(String(commit.id.prefix(7)))
        .navigationBarTitleDisplayMode(.inline)
        .task(id: commit.id) {
            isLoading = true
            error = nil
            defer { isLoading = false }
            do {
                let repo = repo
                let id = commit.id
                // Diff formatting and libgit2 walking can take seconds on a large commit.
                // Never do that on the main actor, or the navigation push appears frozen.
                let result = try await Task.detached(priority: .userInitiated) {
                    try GitClient.show(at: repo, commit: id)
                }.value
                guard !Task.isCancelled else { return }
                text = result
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
        }
    }

    private var lines: [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }
}

private struct RepoOperationsSheet: View {
    @EnvironmentObject private var store: RepoStore
    @Environment(\.dismiss) private var dismiss
    let name: String
    let branch: String
    let origin: String
    let branches: [BranchInfo]
    let remotes: [RemoteInfo]
    @Binding var username: String
    @Binding var secret: String
    @Binding var message: String
    let savedAccount: String?
    let linked: Bool
    let onLink: () -> Void

    @State private var newBranch = ""
    @State private var mergeTarget = ""
    @State private var rebaseTarget = ""
    @State private var cherryPickCommit = ""
    @State private var confirmUnlink = false
    @State private var remoteName = ""
    @State private var remoteURL = ""
    @State private var itemName = ""
    @State private var itemIsDirectory = false
    @State private var confirmReset = false

    var body: some View {
        NavigationStack {
            List {
                Section("Sync") {
                    accountFields
                    Button("Fetch") { saveCredentials(); sync(fetch: true) }
                        .disabled(store.isBusy || origin.isEmpty)
                    Button("Pull") { saveCredentials(); sync(fetch: false) }
                        .disabled(store.isBusy || origin.isEmpty)
                    Button("Push") {
                        saveCredentials()
                        let creds = store.account(for: origin, username: username, secret: secret)
                        store.push(name: name, username: creds.username, secret: creds.secret)
                        dismiss()
                    }
                    .disabled(store.isBusy || origin.isEmpty)
                }
                Section("Changes") {
                    TextField("Commit message", text: $message, axis: .vertical)
                        .lineLimit(2...4)
                    Button("Stage All") { store.stageAll(name: name); dismiss() }
                    Button("Unstage All") { store.unstageAll(name: name); dismiss() }
                    Button("Commit") {
                        store.commit(name: name, message: message)
                        message = ""
                        dismiss()
                    }
                    .disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    NavigationLink("Diff") { DiffPage(repo: store.repoURL(name)) }
                    Button("Reset (HARD)", role: .destructive) { confirmReset = true }
                }
                Section("Branches") {
                    ForEach(branches) { item in
                        Button {
                            guard !item.isRemote, !item.isCurrent else { return }
                            store.checkout(name: name, branch: item.name)
                            dismiss()
                        } label: {
                            LabeledContent(item.name) {
                                if item.isCurrent { Text("Current") }
                                else if item.isRemote { Text("Remote") }
                            }
                        }
                        .disabled(item.isRemote || item.isCurrent)
                    }
                    TextField("New Branch", text: $newBranch)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Create Branch") {
                        store.createBranch(name: name, branch: newBranch)
                        dismiss()
                    }
                    .disabled(newBranch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if branches.contains(where: { !$0.isRemote && !$0.isCurrent }) {
                        Picker("Merge", selection: $mergeTarget) {
                            Text("Choose a branch").tag("")
                            ForEach(branches.filter { !$0.isRemote && !$0.isCurrent }) { item in
                                Text(item.name).tag(item.name)
                            }
                        }
                        Button("Merge") {
                            store.merge(name: name, branch: mergeTarget)
                            dismiss()
                        }
                        .disabled(mergeTarget.isEmpty)
                        Picker("Rebase onto", selection: $rebaseTarget) {
                            Text("Choose a branch").tag("")
                            ForEach(branches.filter { !$0.isRemote && !$0.isCurrent }) { item in
                                Text(item.name).tag(item.name)
                            }
                        }
                        Button("Rebase") {
                            store.rebase(name: name, onto: rebaseTarget)
                            dismiss()
                        }
                        .disabled(rebaseTarget.isEmpty)
                    }
                    TextField("Commit to cherry-pick", text: $cherryPickCommit)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Cherry-pick") {
                        store.cherryPick(name: name, commit: cherryPickCommit)
                        dismiss()
                    }
                    .disabled(cherryPickCommit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Section("Files") {
                    TextField("File name", text: $itemName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Toggle("Directory", isOn: $itemIsDirectory)
                    Button("Create") {
                        store.createWorkItem(name: name, itemName: itemName, directory: itemIsDirectory)
                        dismiss()
                    }
                    .disabled(itemName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Section("Remotes") {
                    ForEach(remotes) { remote in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(remote.name)
                            Text(remote.url).font(.caption).foregroundStyle(.secondary)
                        }
                        .swipeActions {
                            Button("Remove", role: .destructive) {
                                store.removeRemote(name: name, remote: remote.name)
                                dismiss()
                            }
                        }
                    }
                    TextField("Remote name", text: $remoteName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Remote URL", text: $remoteURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    Button("Add Remote") {
                        store.addRemote(name: name, remote: remoteName, url: remoteURL)
                        dismiss()
                    }
                    .disabled(remoteName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || remoteURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Section("Repository") {
                    if !branch.isEmpty {
                        LabeledContent("Branch", value: branch)
                    }
                    if linked {
                        Button("Unlink Folder", role: .destructive) { confirmUnlink = true }
                    } else {
                        Button("Link Folder") {
                            dismiss()
                            onLink()
                        }
                    }
                    NavigationLink("Raw config") {
                        ConfigPage(text: GitClient.configText(at: store.repoURL(name)))
                    }
                }
            }
            .navigationTitle("Operations")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog("Unlink this folder?", isPresented: $confirmUnlink, titleVisibility: .visible) {
                Button("Unlink Folder", role: .destructive) {
                    store.unlink(name: name)
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Gitling keeps the repository. The files stay in the folder you chose.")
            }
            .confirmationDialog("Reset (HARD)?", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("Reset (HARD)", role: .destructive) {
                    store.resetHard(name: name)
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This discards every uncommitted change in the working folder.")
            }
        }
    }

    private var accountFields: some View {
        Group {
            TextField("Username", text: $username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            SecureField("Password or Token", text: $secret)
            if secret.isEmpty, let savedAccount {
                Text(String(format: String(localized: "Saved account %@ is used when these fields are empty."), savedAccount))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func saveCredentials() {
        guard let host = GitClient.host(of: origin), !secret.isEmpty else { return }
        KeychainStore.save(host: host, username: username, secret: secret)
    }

    private func sync(fetch: Bool) {
        let creds = store.account(for: origin, username: username, secret: secret)
        if fetch {
            store.fetch(name: name, username: creds.username, secret: creds.secret)
        } else {
            store.pull(name: name, username: creds.username, secret: creds.secret)
        }
        dismiss()
    }
}

private struct DiffPage: View {
    let repo: URL
    @State private var text = ""

    var body: some View {
        ScrollView {
            Text(text.isEmpty ? String(localized: "No changes") : text)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle("Diff")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            let value = (try? GitClient.diff(at: repo)) ?? ""
            text = value.count > 80_000 ? String(value.prefix(80_000)) : value
        }
    }
}

private struct ConfigPage: View {
    let text: String

    var body: some View {
        ScrollView {
            Text(text.isEmpty ? String(localized: "Could not open repository") : text)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle("Raw config")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct FilePreview: View {
    let repo: URL
    let relative: String
    let name: String
    @State private var text: String?
    @State private var error: String?

    var body: some View {
        ScrollView {
            if let text {
                Text(text)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            } else if let error {
                ContentUnavailableView("Files", systemImage: "doc", description: Text(error))
            }
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            do {
                text = try GitClient.readText(at: repo, relative: relative)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
