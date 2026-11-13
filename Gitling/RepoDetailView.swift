import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct RepoDetailView: View {
    @EnvironmentObject private var store: RepoStore
    @Environment(\.dynamicTypeSize) private var textSize
    let name: String

    @State private var restorePlan: FileRestorePlan?
    @State private var preparingRestore = false
    @State private var pendingSubmodules = false
    @State private var detachedOID: String?
    @State private var operation: GitOperationSnapshot?
    @State private var section = 0
    @State private var branch = ""
    @State private var origin = ""
    @State private var upstream: String?
    @State private var files: [WorkEntry] = []
    @State private var history: [CommitInfo] = []
    @State private var historyHasMore = false
    @State private var historyResetNeeded = true
    @State private var isLoadingHistory = false
    @State private var isLoadingStatus = false
    @State private var isLoadingMoreHistory = false
    private let historyPageSize = 300
    @State private var changes: [StatusEntry] = []
    @State private var username = ""
    @State private var secret = ""
    @State private var savedAccount: String?
    @State private var message = ""
    @State private var loadError: String?
    @State private var linkedFolder: String?
    @State private var pickFolder = false
    @State private var allBranches = true
    @State private var selectedBranch: String?
    @State private var branches: [BranchInfo] = []
    @State private var remotes: [RemoteInfo] = []
    @State private var sync: SyncCounts?
    @State private var statusText = ""
    @State private var showOperations = false
    @State private var spinnerLoads = 0
    @State private var loadGeneration = 0
    @State private var cacheRestored = false
    @State private var consoleLines: [ConsoleLine] = []
    @State private var command = ""
    @State private var isRunningCommand = false
    @State private var refreshTask: Task<Void, Never>?
    @ScaledMetric(relativeTo: .body) private var commitRowHeight: CGFloat = 56

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                if let detachedOID {
                    DetachedHeadNotice(oid: detachedOID)
                    NavigationLink("Create Branch to Keep Work") { DetachedBranchPage(name: name) }
                        .font(.footnote)
                } else if !branch.isEmpty {
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
                if let operation, operation.needsAttention {
                    NavigationLink {
                        ConflictResolutionPage(name: name)
                    } label: {
                        Label(operation.kind?.title ?? String(localized: "Resolve conflicts"), systemImage: "exclamationmark.triangle")
                            .font(.subheadline)
                    }
                }
                if pendingSubmodules {
                    NavigationLink("Resume Submodule Update") { SubmodulePage(name: name) }
                }
                RepositorySectionPicker(selection: $section)
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
        .overlay {
            if !store.isBusy && (spinnerLoads > 0 || preparingRestore) {
                ZStack {
                    Color.black.opacity(0.12)
                        .ignoresSafeArea()
                    ProgressView()
                        .controlSize(.large)
                        .padding(24)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
                }
                .transition(.opacity)
                .allowsHitTesting(true)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: spinnerLoads > 0 || store.isBusy)
        .background(Color(.systemGroupedBackground))
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if section == 1 {
                NavigationLink {
                    let ref = selectedBranchInfo.map { ($0.isRemote ? "refs/remotes/" : "refs/heads/") + $0.name }
                    HistorySearchPage(repo: repoURL, scope: allBranches ? ref.map { .reference($0) } ?? .all : .current, selectedReference: ref)
                } label: { Label("Search History", systemImage: "magnifyingglass") }
                NavigationLink { CommitComparisonPage(repo: repoURL) } label: {
                    Label("Compare Commits", systemImage: "arrow.left.arrow.right")
                }.accessibilityIdentifier("comparison.open")
            } else if section == 0 {
                NavigationLink { FileSearchPage(repo: repoURL) } label: { Label("Search Files", systemImage: "magnifyingglass") }
            }
            Button("Operations", systemImage: "ellipsis.circle") {
                if branches.isEmpty {
                    requestLoad(showSpinner: true)
                }
                showOperations = true
            }
            .disabled(store.isBusy)
        }
        .sheet(item: $restorePlan) { plan in
            FileRestoreConfirmation(plan: plan, external: linkedFolder != nil, busy: store.isBusy) {
                restorePlan = nil
                store.restoreFile(name: name, plan: plan)
            }
        }
        .sheet(isPresented: $showOperations) {
            RepoOperationsSheet(
                name: name,
                branch: branch,
                origin: origin,
                upstream: upstream,
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
                },
                isLoading: spinnerLoads > 0
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
        .task(id: store.revision) {
            refreshTask?.cancel()
            if !cacheRestored {
                cacheRestored = true
                if let cached = RepoDetailCache.load(name) {
                    applyCache(cached)
                } else {
                    historyResetNeeded = true
                }
            } else {
                resetHistory()
            }
            await load(showSpinner: false)
        }
        .onDisappear { refreshTask?.cancel() }
        .onChange(of: allBranches) { _, isAll in
            if isAll {
                resetHistory()
                requestLoad(showSpinner: false)
            } else {
                let sameAsCurrent = selectedBranch == branch
                if selectedBranch != nil { selectedBranch = nil }
                if !sameAsCurrent {
                    resetHistory()
                    requestLoad(showSpinner: false)
                }
            }
        }
        .onChange(of: selectedBranch) { _, _ in
            guard allBranches else { return }
            resetHistory()
            requestLoad(showSpinner: false)
        }
        .onChange(of: section) { _, newSection in
            if newSection == 1 {
                requestLoad(showSpinner: false)
            } else if newSection == 2 {
                requestLoad(showSpinner: false)
            }
        }
    }

    private var repoURL: URL { store.repoURL(name) }

    private var selectedBranchInfo: BranchInfo? {
        guard let selectedBranch else { return nil }
        return branches.first { $0.name == selectedBranch }
    }

    private func checkout(_ branch: BranchInfo) {
        if branch.isRemote {
            let localName = branch.name
                .split(separator: "/", maxSplits: 1)
                .dropFirst()
                .joined(separator: "/")
            store.checkoutRemote(name: name, branch: branch.name)
            if !localName.isEmpty { selectedBranch = localName }
        } else {
            store.checkout(name: name, branch: branch.name)
        }
    }

    private var historyList: some View {
        let rows = CommitGraph.rows(from: history)
        return Group {
            if isLoadingHistory && rows.isEmpty {
                VStack {
                    Spacer()
                    historyLoadingBar
                        .padding(.bottom, 18)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if rows.isEmpty {
                ContentUnavailableView("No commits yet", systemImage: "clock")
            } else {
                List {
                    Section {
                        Picker("Branches", selection: $allBranches) {
                            Text("This branch").tag(false)
                            Text("All branches").tag(true)
                        }
                        .pickerStyle(.segmented)
                        if allBranches {
                            HStack {
                                Text("Branch")
                                Spacer()
                                Menu {
                                    Button {
                                        selectedBranch = nil
                                    } label: {
                                        Label(
                                            "All branches",
                                            systemImage: selectedBranch == nil ? "checkmark" : "rectangle.stack"
                                        )
                                    }
                                    let localBranches = branches.filter { !$0.isRemote }
                                    if !localBranches.isEmpty {
                                        Section("Local branches") {
                                            ForEach(localBranches) { item in
                                                Button {
                                                    selectedBranch = item.name
                                                } label: {
                                                    Label(
                                                        item.name,
                                                        systemImage: selectedBranch == item.name
                                                            ? "checkmark"
                                                            : "arrow.triangle.branch"
                                                    )
                                                }
                                            }
                                        }
                                    }
                                    let remoteBranches = branches.filter {
                                        $0.isRemote && !$0.name.hasSuffix("/HEAD")
                                    }
                                    if !remoteBranches.isEmpty {
                                        Section("Remote branches") {
                                            ForEach(remoteBranches) { item in
                                                Button {
                                                    selectedBranch = item.name
                                                } label: {
                                                    Label(
                                                        item.name,
                                                        systemImage: selectedBranch == item.name
                                                            ? "checkmark"
                                                            : "cloud"
                                                    )
                                                }
                                            }
                                        }
                                    }
                                } label: {
                                    HStack(spacing: 4) {
                                        Text(selectedBranch ?? String(localized: "All branches"))
                                            .lineLimit(1)
                                        Image(systemName: "chevron.up.chevron.down")
                                    }
                                    .foregroundStyle(.tint)
                                }
                            }
                            if let selected = selectedBranchInfo, !selected.isCurrent {
                                Button {
                                    checkout(selected)
                                } label: {
                                    Label("Checkout", systemImage: "arrow.triangle.branch")
                                }
                            }
                        }
                    }
                    Section {
                        ForEach(rows) { row in
                            NavigationLink {
                                CommitDetailView(repo: repoURL, commit: row.commit)
                            } label: {
                                CommitHistoryLabel(row: row, minimumHeight: commitRowHeight) {
                                    branchChips(for: row.commit.id)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 12))
                            .listRowSeparator(.hidden)
                        }
                        if historyHasMore {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text("Loading more…")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .listRowSeparator(.hidden)
                            .id(history.count)
                            .onAppear {
                                Task { await loadMoreHistory() }
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .overlay(alignment: .bottom) {
                    if isLoadingHistory {
                        historyLoadingBar
                            .padding(.bottom, 12)
                    }
                }
            }
        }
    }

    private var historyLoadingBar: some View {
        HStack(spacing: 8) {
            ProgressView()
            Text("Loading history…")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: Capsule())
    }

    private func branchRefs(for commitID: String) -> [BranchInfo] {
        branches
            .filter { $0.target == commitID }
            .sorted { lhs, rhs in
                if lhs.isCurrent != rhs.isCurrent { return lhs.isCurrent }
                if lhs.isRemote != rhs.isRemote { return !lhs.isRemote }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    @ViewBuilder
    private func branchChips(for commitID: String) -> some View {
        let refs = branchRefs(for: commitID)
        if !refs.isEmpty {
            HStack(spacing: 3) {
                ForEach(refs.prefix(2)) { ref in
                    if ref.isCurrent {
                        CommitRefChip(text: "HEAD", kind: .head)
                    }
                    CommitRefChip(text: ref.name, kind: ref.isRemote ? .remote : .local)
                }
                if refs.count > 2 {
                    CommitRefChip(text: "+\(refs.count - 2)", kind: .more)
                }
            }
            .layoutPriority(1)
        }
    }

    private var statusView: some View {
        List {
            Section("Status") {
                NavigationLink("Resolve conflicts") { ConflictResolutionPage(name: name) }
                if isLoadingStatus { ProgressView() }
                Text(statusText.isEmpty ? String(localized: "No changes") : statusText)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                if let sync, sync.ahead > 0 || sync.behind > 0 {
                    Text(String(format: String(localized: "Your branch is %@ ahead and %@ behind."), "\(sync.ahead)", "\(sync.behind)"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Section("Staged Changes") {
                if changes.filter(\.staged).isEmpty {
                    Text("No changes").foregroundStyle(.secondary)
                }
                ForEach(changes.filter(\.staged)) { entry in
                    statusRow(entry, staged: true)
                }
            }
            Section("Unstaged Changes") {
                if !changes.contains(where: { $0.unstaged || $0.untracked }) {
                    Text("No changes").foregroundStyle(.secondary)
                }
                ForEach(changes.filter { $0.unstaged || $0.untracked }) { entry in
                    statusRow(entry, staged: false)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder
    private func statusRow(_ entry: StatusEntry, staged: Bool) -> some View {
        if entry.conflicted == true {
            NavigationLink {
                ConflictResolutionPage(name: name)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.path).font(.body.monospaced())
                    Label("Resolve conflicts", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        } else {
            ordinaryStatusRow(entry, staged: staged)
        }
    }

    private func ordinaryStatusRow(_ entry: StatusEntry, staged: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            NavigationLink {
                DiffPage(repo: repoURL, path: entry.path, scope: staged ? .staged : .worktree)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.path).font(.body.monospaced())
                    Text(label(entry)).font(.caption).foregroundStyle(.secondary)
                }
            }
            FileStatusActions(staged: staged,
                              canRestore: !staged && !entry.untracked && operation?.needsAttention != true,
                              busy: store.isBusy || preparingRestore,
                              onStage: {
                if staged { store.unstage(name: name, entry: entry) }
                else { store.stage(name: name, entry: entry) }
            }, onRestore: { prepareRestore(entry.path) })
        }
    }

    private func prepareRestore(_ path: String) {
        guard !store.isBusy, !preparingRestore else { return }
        preparingRestore = true
        let url = repoURL
        Task {
            defer { preparingRestore = false }
            do {
                restorePlan = try await Task.detached(priority: .userInitiated) {
                    try GitClient.prepareFileRestore(at: url, path: path)
                }.value
            } catch { store.alert = error.localizedDescription }
        }
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
                    .disabled(isRunningCommand || command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }

    private func label(_ entry: StatusEntry) -> String {
        if entry.conflicted == true { return String(localized: "Conflicted") }
        if entry.untracked { return String(localized: "Untracked") }
        if entry.staged && entry.unstaged { return String(localized: "Staged and unstaged") }
        if entry.staged { return String(localized: "Staged") }
        return String(localized: "Unstaged")
    }

    private func runCommand() {
        let line = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty, !isRunningCommand else { return }
        command = ""
        isRunningCommand = true
        let url = repoURL
        Task {
            let output = await Task.detached(priority: .userInitiated) {
                GitClient.commandOutput(at: url, line: line)
            }.value
            consoleLines.append(ConsoleLine(command: line, output: output))
            isRunningCommand = false
        }
    }

    private func applyCache(_ cached: RepoDetailSnapshot) {
        detachedOID = cached.detachedOID
        branch = cached.branch
        origin = cached.origin
        branches = cached.branches
        remotes = cached.remotes
        // Only reuse history/status captured for the default all-branches view.
        if cached.allBranches && cached.selectedBranch == nil {
            history = cached.history
            historyHasMore = cached.history.count >= historyPageSize
            historyResetNeeded = false
            changes = cached.changes
            statusText = cached.statusText
            sync = cached.sync
        }
        savedAccount = store.accountUsername(for: cached.origin, repoName: name)
            ?? GitClient.host(of: cached.origin).flatMap { KeychainStore.load(host: $0)?.username }
        linkedFolder = cached.linkedFolder
        upstream = cached.upstream
    }

    private func requestLoad(showSpinner: Bool) {
        refreshTask?.cancel()
        refreshTask = Task { await load(showSpinner: showSpinner) }
    }

    private func load(showSpinner: Bool) async {
        loadGeneration += 1
        let generation = loadGeneration
        let url = repoURL
        let sectionAtStart = section
        isLoadingStatus = sectionAtStart == 2
        let everyBranch = allBranches
        let branchFilter = selectedBranch
        loadError = nil
        if showSpinner { spinnerLoads += 1 }
        defer {
            if showSpinner { spinnerLoads = max(0, spinnerLoads - 1) }
            if generation == loadGeneration { isLoadingStatus = false }
        }

        let header: RepositoryHeader
        do {
            let loaded = try await Task.detached(priority: .userInitiated) {
                (try GitClient.header(at: url), try GitClient.operation(at: url))
            }.value
            header = loaded.0
            guard generation == loadGeneration, !Task.isCancelled else { return }
            operation = loaded.1
        } catch {
            guard generation == loadGeneration, !Task.isCancelled else { return }
            loadError = error.localizedDescription
            return
        }
        guard generation == loadGeneration, !Task.isCancelled else { return }
        detachedOID = header.detachedOID
        pendingSubmodules = header.pendingSubmodules
        branch = header.branch
        origin = header.origin
        branches = header.branches
        remotes = header.remotes
        savedAccount = store.accountUsername(for: header.origin, repoName: name)
            ?? GitClient.host(of: header.origin).flatMap { KeychainStore.load(host: $0)?.username }
        linkedFolder = header.linkedFolder
        upstream = header.upstream

        var snapshot = RepoDetailCache.load(name) ?? RepoDetailSnapshot()
        snapshot.detachedOID = detachedOID
        snapshot.branch = branch
        snapshot.origin = origin
        snapshot.branches = branches
        snapshot.remotes = remotes
        snapshot.linkedFolder = linkedFolder
        snapshot.upstream = upstream
        snapshot.allBranches = everyBranch
        snapshot.selectedBranch = branchFilter

        if sectionAtStart == 1, history.isEmpty || historyResetNeeded {
            isLoadingHistory = true
            let historyData = await Task.detached { () -> HistoryData in
                do {
                    let commits = try GitClient.history(
                        at: url,
                        limit: historyPageSize,
                        allBranches: everyBranch,
                        ref: everyBranch ? branchFilter : nil
                    )
                    return HistoryData(commits: commits, error: nil)
                } catch {
                    return HistoryData(commits: [], error: error.localizedDescription)
                }
            }.value
            isLoadingHistory = false
            guard generation == loadGeneration, !Task.isCancelled else { return }
            loadError = historyData.error
            if historyData.error == nil {
                history = historyData.commits
                historyHasMore = historyData.commits.count >= historyPageSize
                historyResetNeeded = false
                snapshot.history = historyData.commits
            }
        }

        if sectionAtStart == 2 {
            let branchName = branch
            let detached = detachedOID
            let statusData = await Task.detached(priority: .userInitiated) { () -> StatusData in
                do {
                    let changes = try GitClient.status(at: url)
                    let sync = GitClient.syncCounts(at: url)
                    let text = GitClient.statusText(entries: changes, branch: branchName, sync: sync, detachedOID: detached)
                    return StatusData(changes: changes, sync: sync, text: text, error: nil)
                } catch {
                    return StatusData(changes: [], sync: nil, text: "", error: error.localizedDescription)
                }
            }.value
            guard generation == loadGeneration, !Task.isCancelled else { return }
            if let error = statusData.error {
                loadError = error
                return
            }
            changes = statusData.changes
            sync = statusData.sync
            statusText = statusData.text
            snapshot.changes = statusData.changes
            snapshot.sync = statusData.sync
            snapshot.statusText = statusData.text
        }

        snapshot.savedAt = Date()
        RepoDetailCache.save(snapshot, for: name)
    }

    private func resetHistory() {
        history = []
        historyHasMore = false
        historyResetNeeded = true
        isLoadingMoreHistory = false
    }

    private func loadMoreHistory() async {
        guard !isLoadingMoreHistory, historyHasMore else { return }
        isLoadingMoreHistory = true
        let offset = history.count
        let url = repoURL
        let everyBranch = allBranches
        let branchFilter = selectedBranch
        let page = await Task.detached { () -> HistoryData in
            do {
                let commits = try GitClient.history(
                    at: url,
                    limit: historyPageSize,
                    allBranches: everyBranch,
                    ref: everyBranch ? branchFilter : nil,
                    offset: offset
                )
                return HistoryData(commits: commits, error: nil)
            } catch {
                return HistoryData(commits: [], error: error.localizedDescription)
            }
        }.value
        isLoadingMoreHistory = false
        guard offset == history.count,
              everyBranch == allBranches,
              branchFilter == selectedBranch else { return }
        loadError = page.error
        if page.error == nil {
            if page.commits.isEmpty {
                historyHasMore = false
            } else {
                history.append(contentsOf: page.commits)
                historyHasMore = page.commits.count >= historyPageSize
                if var snapshot = RepoDetailCache.load(name) {
                    snapshot.history = history
                    snapshot.savedAt = Date()
                    RepoDetailCache.save(snapshot, for: name)
                }
            }
        }
    }

    private struct HistoryData {
        var commits: [CommitInfo]
        var error: String?
    }

    private struct StatusData {
        var changes: [StatusEntry]
        var sync: SyncCounts?
        var text: String
        var error: String?
    }
}

private struct ConsoleLine: Identifiable {
    let id = UUID()
    var command: String
    var output: String
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
        .task(id: "\(repo.path):\(directory):\(revision)") { await load() }
    }

    private func load() async {
        let repo = repo
        let directory = directory
        do {
            let loaded = try await Task.detached(priority: .userInitiated) {
                try GitClient.entries(at: repo, directory: directory)
            }.value
            guard !Task.isCancelled else { return }
            entries = loaded
            error = nil
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }
}

private struct CommitRefChip: View {
    enum Kind {
        case head
        case local
        case remote
        case more
    }

    let text: String
    let kind: Kind

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .foregroundStyle(foreground)
            .background(background, in: Capsule())
    }

    private var foreground: Color {
        switch kind {
        case .head: return .white
        case .local: return .accentColor
        case .remote, .more: return .secondary
        }
    }

    private var background: Color {
        switch kind {
        case .head: return .accentColor
        case .local: return .accentColor.opacity(0.14)
        case .remote, .more: return Color(.secondarySystemFill)
        }
    }
}

struct DiffTextView: UIViewRepresentable {
    let text: String
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.adjustsFontForContentSizeCategory = false
        view.backgroundColor = .clear
        view.textAlignment = .left
        view.textContainerInset = UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        view.textContainer.lineFragmentPadding = 0
        view.alwaysBounceVertical = true
        let font = Self.font(for: dynamicTypeSize)
        view.font = font
        view.attributedText = DiffStyler.attributed(text, font: font)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        let font = Self.font(for: dynamicTypeSize)
        if view.attributedText.string != text || view.font?.pointSize != font.pointSize {
            view.font = font
            view.attributedText = DiffStyler.attributed(text, font: font)
        }
    }

    private static func font(for size: DynamicTypeSize) -> UIFont {
        let category: UIContentSizeCategory
        switch size {
        case .xSmall: category = .extraSmall
        case .small: category = .small
        case .medium: category = .medium
        case .large: category = .large
        case .xLarge: category = .extraLarge
        case .xxLarge: category = .extraExtraLarge
        case .xxxLarge: category = .extraExtraExtraLarge
        case .accessibility1: category = .accessibilityMedium
        case .accessibility2: category = .accessibilityLarge
        case .accessibility3: category = .accessibilityExtraLarge
        case .accessibility4: category = .accessibilityExtraExtraLarge
        case .accessibility5: category = .accessibilityExtraExtraExtraLarge
        @unknown default: category = size.isAccessibilitySize ? .accessibilityExtraExtraExtraLarge : .large
        }
        let traits = UITraitCollection(preferredContentSizeCategory: category)
        let pointSize = UIFont.preferredFont(forTextStyle: .caption1, compatibleWith: traits).pointSize
        return UIFont.monospacedSystemFont(ofSize: pointSize, weight: .regular)
    }
}

private enum DiffStyler {
    static func attributed(_ text: String, font: UIFont) -> NSAttributedString {
        let result = NSMutableAttributedString(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: UIColor.label,
            ]
        )
        let ns = text as NSString
        var location = 0
        var inPatch = false
        while location < ns.length {
            let lineRange = ns.lineRange(for: NSRange(location: location, length: 0))
            let line = ns.substring(with: lineRange).trimmingCharacters(in: .newlines)
            if line.hasPrefix("diff --git ")
                || line.hasPrefix("diff --cc ")
                || line.hasPrefix("diff --combined ") {
                inPatch = true
            }
            guard inPatch else {
                location = NSMaxRange(lineRange)
                continue
            }

            var color: UIColor?
            var bold = false
            if line.hasPrefix("@@") {
                color = .systemBlue
                bold = true
            } else if line.hasPrefix("+++") || line.hasPrefix("---") {
                color = .secondaryLabel
            } else if line.hasPrefix("diff --git")
                || line.hasPrefix("index ")
                || line.hasPrefix("new file mode ")
                || line.hasPrefix("deleted file mode ")
                || line.hasPrefix("old mode ")
                || line.hasPrefix("new mode ")
                || line.hasPrefix("similarity index ")
                || line.hasPrefix("rename from ")
                || line.hasPrefix("rename to ")
                || line.hasPrefix("Binary files ") {
                color = .secondaryLabel
            } else if line.hasPrefix("+") {
                color = .systemGreen
            } else if line.hasPrefix("-") {
                color = .systemRed
            } else if line.hasPrefix("\\ No newline ") {
                color = .secondaryLabel
            }

            if let color {
                result.addAttribute(.foregroundColor, value: color, range: lineRange)
            }
            if bold {
                result.addAttribute(
                    .font,
                    value: UIFont.monospacedSystemFont(ofSize: font.pointSize, weight: .semibold),
                    range: lineRange
                )
            }
            location = NSMaxRange(lineRange)
        }
        return result
    }
}

struct CommitDetailView: View {
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
                DiffTextView(text: text)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
}

private struct RepoOperationsSheet: View {
    @EnvironmentObject private var store: RepoStore
    @Environment(\.dismiss) private var dismiss
    let name: String
    let branch: String
    let origin: String
    let upstream: String?
    let branches: [BranchInfo]
    let remotes: [RemoteInfo]
    @Binding var username: String
    @Binding var secret: String
    @Binding var message: String
    let savedAccount: String?
    let linked: Bool
    let onLink: () -> Void
    let isLoading: Bool

    @State private var newBranch = ""
    @State private var selectedRemote = ""
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
                    Picker("Remote", selection: $selectedRemote) {
                        Text("Automatic (upstream)").tag("")
                        ForEach(remotes) { remote in Text(remote.name).tag(remote.name) }
                    }
                    LabeledContent("Upstream", value: upstream ?? String(localized: "None"))
                    Text("Pull follows the upstream branch.").font(.caption).foregroundStyle(.secondary)
                    Button("Fetch") { sync(fetch: true) }
                        .disabled(store.isBusy || remotes.isEmpty)
                    Button("Pull") { sync(fetch: false) }
                        .disabled(store.isBusy || remotes.isEmpty)
                    Button("Push") {
                        store.push(name: name, username: username, secret: secret, remoteName: selectedRemote.isEmpty ? nil : selectedRemote)
                        dismiss()
                    }
                    .disabled(store.isBusy || remotes.isEmpty)
                }
                Section("Changes") {
                    NavigationLink("Resolve conflicts") { ConflictResolutionPage(name: name) }
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
                    NavigationLink("Stash") { StashPage(name: name) }
                    NavigationLink("Submodules") { SubmodulePage(name: name) }
                    NavigationLink("Tags") { TagsPage(name: name) }
                    Button("Reset (HARD)", role: .destructive) { confirmReset = true }
                }
                Section("Branches") {
                    NavigationLink("Manage Branches and Upstream") { BranchManagementPage(name: name) }
                    ForEach(branches) { item in
                        Button {
                            guard !item.isCurrent else { return }
                            if item.isRemote {
                                store.checkoutRemote(name: name, branch: item.name)
                            } else {
                                store.checkout(name: name, branch: item.name)
                            }
                            dismiss()
                        } label: {
                            LabeledContent(item.name) {
                                if item.isCurrent { Text("Current") }
                                else if item.isRemote { Text("Checkout as Local") }
                            }
                        }
                        .disabled(item.isCurrent)
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
                        ConfigPage(repo: store.repoURL(name))
                    }
                }
            }
            .overlay {
                if isLoading || store.isBusy {
                    if let progress = store.operationProgress, store.isBusy {
                        OperationProgressOverlay(state: progress)
                    } else {
                        ZStack {
                            Color.black.opacity(0.12)
                                .ignoresSafeArea()
                            ProgressView()
                                .controlSize(.large)
                                .padding(24)
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
                        }
                        .allowsHitTesting(true)
                    }
                }
            }
            .animation(.easeInOut(duration: 0.15), value: isLoading || store.isBusy)
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

    private func sync(fetch: Bool) {
        if fetch {
            store.fetch(name: name, username: username, secret: secret, remoteName: selectedRemote.isEmpty ? nil : selectedRemote)
        } else {
            store.pull(name: name, username: username, secret: secret)
        }
        dismiss()
    }
}

private struct DiffPage: View {
    let repo: URL
    let path: String?
    @State private var scope: GitClient.DiffScope
    @State private var text = ""
    @State private var error: String?
    @State private var isLoading = true

    init(repo: URL, path: String? = nil, scope: GitClient.DiffScope = .worktree) {
        self.repo = repo
        self.path = path
        _scope = State(initialValue: scope)
    }

    var body: some View {
        DiffPanelLayout {
            DiffScopePicker(scope: $scope).padding(.horizontal)
        } content: {
            if isLoading { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if let error { Text(error).padding() }
            else if text.isEmpty { Text("No changes").foregroundStyle(.secondary).padding() }
            else { DiffTextView(text: text).frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .navigationTitle(path ?? String(localized: "Diff"))
        .navigationBarTitleDisplayMode(.inline)
        .task(id: scope) {
            isLoading = true
            let repo = repo
            let path = path
            let selectedScope = scope
            do {
                let value = try await Task.detached(priority: .userInitiated) {
                    try GitClient.diff(at: repo, scope: selectedScope, path: path)
                }.value
                guard !Task.isCancelled else { return }
                text = value.count > 80_000 ? String(value.prefix(80_000)) : value
                error = nil
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
            isLoading = false
        }
    }
}

private struct ConfigPage: View {
    let repo: URL
    @State private var text = ""

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
        .task {
            let repo = repo
            let loaded = await Task.detached(priority: .userInitiated) { GitClient.configText(at: repo) }.value
            guard !Task.isCancelled else { return }
            text = loaded
        }
    }
}
