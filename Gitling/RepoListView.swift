import SwiftUI
import UniformTypeIdentifiers

struct RepoListView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var store: RepoStore
    @State private var selection: String?
    @State private var showAdd = false
    @State private var showSettings = false
    @State private var pendingDelete: String?
    @State private var searchQuery = ""

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Gitling")
                            .font(.largeTitle.bold())
                        Text(repoCountText)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    searchField
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 10)

                List(selection: $selection) {
                    Section {
                        ForEach(filteredRepos) { repo in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(repo.name)
                                    .font(.headline)
                                Text(subtitle(repo))
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            .tag(repo.name)
                            .swipeActions {
                                Button("Delete", role: .destructive) {
                                    pendingDelete = repo.name
                                }
                            }
                        }
                    }
                }
                .scrollContentBackground(.hidden)
                .contentMargins(.bottom, 88, for: .scrollContent)
                .overlay {
                    if store.repos.isEmpty && !store.isBusy {
                        ContentUnavailableView {
                            Label("No repositories yet", systemImage: "folder")
                        } description: {
                            Text("Clone or create a repository in this app.")
                        } actions: {
                            Button("Add repository") { showAdd = true }
                                .buttonStyle(.borderedProminent)
                        }
                    } else if filteredRepos.isEmpty {
                        ContentUnavailableView(
                            "No repositories found",
                            systemImage: "magnifyingglass",
                            description: Text("Try a different name or branch.")
                        )
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    Button {
                        showAdd = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(width: 56, height: 56)
                            .background(Circle().fill(Color.accentColor))
                            .shadow(color: .black.opacity(0.22), radius: 8, y: 4)
                    }
                    .buttonStyle(.plain)
                    .disabled(store.isBusy)
                    .accessibilityLabel(Text("Add repository"))
                    .padding(.trailing, 20)
                    .padding(.bottom, 20)
                }
                .refreshable { await store.reload() }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if store.isBusy {
                        ProgressView()
                    }
                    Button("Settings", systemImage: "gearshape") { showSettings = true }
                }
            }
        } detail: {
            if let selection, store.repos.contains(where: { $0.name == selection }) {
                RepoDetailView(name: selection)
            } else {
                ContentUnavailableView(
                    "Select a repository",
                    systemImage: "folder",
                    description: detailDescription
                )
            }
        }
        .onChange(of: store.focusName) { _, name in
            if let name { selection = name }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                store.revision += 1
                Task { await store.reload() }
            }
        }
        .sheet(isPresented: $showAdd) { AddRepoSheet() }
        .sheet(isPresented: $showSettings) { SettingsSheet() }
        .confirmationDialog(
            "Delete Repository?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let pendingDelete {
                    if selection == pendingDelete { selection = nil }
                    store.delete(name: pendingDelete)
                }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("This removes the local copy from this app.")
        }
        .alert(
            "Gitling",
            isPresented: Binding(
                get: { store.alert != nil },
                set: { if !$0 { store.alert = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.alert ?? "")
        }
        .overlay(alignment: .bottom) {
            if store.isBusy && !store.statusLine.isEmpty {
                Text(store.statusLine)
                    .font(.footnote)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 12)
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search repositories", text: $searchQuery)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
            if !searchQuery.isEmpty {
                Button {
                    searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .padding(4)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Clear search"))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            Color(.systemGray5),
            in: Capsule()
        )
    }

    private var detailDescription: Text {
        if RepoStorage.usesDocumentsFolder {
            return Text("Repositories are available in the Files app under On My iPhone → Gitling.")
        }
        return Text("Choose a folder in the Files app when cloning, or turn on the Gitling location.")
    }

    private var filteredRepos: [RepoSummary] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return store.repos }
        return store.repos.filter { repo in
            [repo.name, repo.branch ?? "", repo.origin ?? ""].contains {
                $0.localizedStandardContains(query)
            }
        }
    }

    private var repoCountText: String {
        let count = store.repos.count
        if count == 1 {
            return String(localized: "1 repository")
        }
        return String(format: String(localized: "%d repositories"), count)
    }

    private func subtitle(_ repo: RepoSummary) -> String {
        if repo.unavailable { return String(localized: "Not a Git repository") }
        let branch = repo.branch ?? String(localized: "No commits yet")
        let state = repo.isDirty ? String(localized: "Changes pending") : String(localized: "Clean")
        return "\(branch) · \(state)"
    }
}

private struct AddRepoSheet: View {
    @EnvironmentObject private var store: RepoStore
    @Environment(\.dismiss) private var dismiss
    @State private var kind = 0
    @State private var url = ""
    @State private var name = ""
    @State private var username = ""
    @State private var secret = ""
    @State private var folderBookmark: Data?
    @State private var folderName: String?
    @State private var pickFolder = false
    @State private var repoQuery = ""

    var body: some View {
        NavigationStack {
            Form {
                Picker("Action", selection: $kind) {
                    Text("Clone").tag(0)
                    Text("New Local Repository").tag(1)
                }
                if kind == 0 {
                    TextField("Remote URL", text: $url)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    TextField("Local Name", text: $name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Username", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password or Token", text: $secret)
                    if secret.isEmpty, let savedAccount {
                        Text(String(format: String(localized: "Saved account %@ is used when these fields are empty."), savedAccount))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    githubReposSection
                } else {
                    TextField("Local Name", text: $name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section("Working Folder") {
                    if folderName != nil {
                        LabeledContent("Files Location", value: folderDisplay)
                        Button("Inside Gitling") {
                            folderBookmark = nil
                            self.folderName = nil
                        }
                    } else {
                        Button("Choose Folder") { pickFolder = true }
                    }
                    Text("A folder with the repository name is created inside the location you choose. Git data stays in Gitling, so that folder does not get a .git directory.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(kind == 0 ? "Clone" : "New Local Repository")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { submit() }
                        .disabled(!canSubmit)
                }
            }
            .onAppear { if kind == 0 { store.loadGitHubRepos() } }
            .fileImporter(isPresented: $pickFolder, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    let accessing = url.startAccessingSecurityScopedResource()
                    defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                    do {
                        folderBookmark = try WorktreeLink.bookmark(for: url)
                        folderName = url.lastPathComponent
                    } catch {
                        store.alert = String(localized: "Could not use that folder.")
                    }
                case .failure(let error):
                    let cocoa = error as NSError
                    if cocoa.domain == NSCocoaErrorDomain && cocoa.code == CocoaError.userCancelled.rawValue { return }
                    store.alert = String(localized: "Could not use that folder.")
                }
            }
        }
    }

    private var folderDisplay: String {
        let repoName = kind == 0 ? resolvedName : name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let folderName else { return "" }
        if repoName.isEmpty { return folderName }
        return "\(folderName)/\(repoName)"
    }

    @ViewBuilder
    private var githubReposSection: some View {
        Section("Your GitHub Repositories") {
            if store.githubLogin == nil {
                Text("Connect with GitHub in Settings to choose a repository.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                TextField("Search repositories", text: $repoQuery)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if store.isLoadingGitHubRepos {
                    ProgressView()
                }
                ForEach(filteredGitHubRepos) { repo in
                    Button {
                        url = repo.cloneURL
                        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            name = repo.name
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(repo.fullName)
                            if !repo.description.isEmpty {
                                Text(repo.description)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Text(repoDetail(repo))
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                }
                if let githubReposMessage = store.githubReposMessage {
                    Text(githubReposMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var filteredGitHubRepos: [GitHubRepo] {
        let query = repoQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return store.githubRepos }
        return store.githubRepos.filter {
            $0.fullName.localizedStandardContains(query) || $0.description.localizedStandardContains(query)
        }
    }

    private func repoDetail(_ repo: GitHubRepo) -> String {
        var parts = ["★ \(repo.stars)"]
        if !repo.language.isEmpty { parts.append(repo.language) }
        return parts.joined(separator: " · ")
    }

    private var savedAccount: String? {
        _ = store.githubLogin
        guard secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let host = GitClient.host(of: url) else { return nil }
        return KeychainStore.load(host: host)?.username
    }

    private var canSubmit: Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if kind == 1 { return !trimmedName.isEmpty }
        return !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !resolvedName.isEmpty
    }

    private var resolvedName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        guard let last = URL(string: url.trimmingCharacters(in: .whitespacesAndNewlines))?.lastPathComponent else {
            return ""
        }
        return last.hasSuffix(".git") ? String(last.dropLast(4)) : last
    }

    private func submit() {
        if kind == 0 {
            store.clone(
                url: url,
                name: resolvedName,
                username: username.trimmingCharacters(in: .whitespacesAndNewlines),
                secret: secret,
                worktreeBookmark: folderBookmark
            )
        } else {
            store.create(name: name, worktreeBookmark: folderBookmark)
        }
        dismiss()
    }
}

private struct SettingsSheet: View {
    @EnvironmentObject private var store: RepoStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var filesInfo: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Git user name") {
                    TextField("Name", text: $store.userName)
                        .textInputAutocapitalization(.words)
                    TextField("Email", text: $store.userEmail)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.emailAddress)
                }
                githubSection
                Section("Files") {
                    Button("Show in Files") {
                        Task {
                            filesInfo = await store.filesLocationExplanation()
                        }
                    }
                    Group {
                        if RepoStorage.usesDocumentsFolder {
                            Text("Repositories are available in the Files app under On My iPhone → Gitling.")
                        } else {
                            Text("In the Files app, open Browse, tap the More button, tap Edit, and turn on Gitling.")
                        }
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
                Section("About") {
                    LabeledContent("Gitling") {
                        Text(version)
                    }
                    Text("GPLv3. Git operations use libgit2 (GPL-2.0 with Linking Exception).")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .alert(
                "Gitling",
                isPresented: Binding(
                    get: { filesInfo != nil },
                    set: { if !$0 { filesInfo = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(filesInfo ?? "")
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") {
                        store.saveIdentity()
                        dismiss()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var githubSection: some View {
        Section("GitHub") {
            if let prompt = store.githubPrompt {
                Text(prompt.userCode)
                    .font(.title.monospaced())
                    .textSelection(.enabled)
                Text(String(format: String(localized: "Approve the sign-in in your browser. Your code is %@."), prompt.userCode))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Open Verification Page") { openURL(prompt.url) }
                Button("Cancel") { store.cancelGitHub() }
            } else if let login = store.githubLogin {
                Text(String(format: String(localized: "Connected as %@"), login))
                Button("Sign Out", role: .destructive) { store.signOutGitHub() }
            } else {
                Button("Connect with GitHub") {
                    store.connectGitHub { openURL($0) }
                }
                .disabled(store.githubBusy)
            }
            if store.githubBusy {
                ProgressView()
            }
            if let message = store.githubMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    }
}