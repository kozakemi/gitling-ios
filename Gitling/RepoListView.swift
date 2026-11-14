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
                            NavigationLink(value: repo.name) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(repo.name)
                                        .font(.headline)
                                    Text(subtitle(repo))
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                            }
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
                    addButton
                        .disabled(store.isBusy)
                        .accessibilityLabel(Text("Add repository"))
                        .padding(.trailing, 20)
                        .padding(.bottom, 20)
                }
                .refreshable { await store.reload(waitForStatus: false) }
            }
            .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 340)
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
            RepositoryDetailNavigation(selection: selection) {
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
        }
        .onChange(of: store.focusName) { _, name in
            if let name { selection = name }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                store.revision += 1
                Task { await store.reload(waitForStatus: false) }
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
        .overlay {
            if store.isBusy, let progress = store.operationProgress {
                OperationProgressOverlay(state: progress)
            }
        }
    }

    @ViewBuilder
    private var addButton: some View {
#if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            Button {
                showAdd = true
            } label: {
                Image(systemName: "plus")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .glassEffect(
                .regular
                    .tint(Color.accentColor.opacity(0.72))
                    .interactive(),
                in: Circle()
            )
        } else {
            legacyAddButton
        }
#else
        legacyAddButton
#endif
    }

    private var legacyAddButton: some View {
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
        if !FileProviderRegistration.usesProviderLocation {
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

    private func subtitle(_ repo: RepoSummary) -> String { RepositoryListLabels.subtitle(repo) }
}

enum RepositoryListLabels {
    static func subtitle(_ repo: RepoSummary, locale: Locale = .current) -> String {
        if repo.unavailable { return String(localized: "Not a Git repository", locale: locale) }
        let branch = repo.branch ?? String(localized: repo.statusState == .checking ? "Loading repository…" : "No commits yet", locale: locale)
        let state: String
        switch repo.statusState {
        case .checking: state = String(localized: "Checking status…", locale: locale)
        case .unavailable: state = String(localized: "Status unavailable", locale: locale)
        default: state = repo.isDirty ? String(localized: "Changes pending", locale: locale) : String(localized: "Clean", locale: locale)
        }
        return "\(branch) · \(state)"
    }
}

private struct AddRepoSheet: View {
    @EnvironmentObject private var store: RepoStore
    @Environment(\.dismiss) private var dismiss
    @State private var kind = 1
    @State private var source = "manual"
    @State private var url = ""
    @State private var name = ""
    @State private var username = ""
    @State private var secret = ""
    @State private var folderBookmark: Data?
    @State private var folderName: String?
    @State private var pickFolder = false
    @State private var repoQuery = ""
    @State private var sshKeyID = ""
    @State private var importBookmark: Data?
    @State private var importFolderName: String?

    var body: some View {
        NavigationStack {
            Form {
                Picker("Action", selection: $kind) {
                    Text("New Local Repository").tag(1)
                    Text("Clone").tag(0)
                    Text("Copy Import").tag(2)
                }
                if kind == 2 {
                    Section("Import Source") {
                        Button("Choose Repository Folder") { pickFolder = true }
                        if let importFolderName { LabeledContent("Source Folder", value: importFolderName) }
                        TextField("Local Name", text: $name).textInputAutocapitalization(.never).autocorrectionDisabled()
                        Text("Copies the working files and complete Git data into Gitling. The source folder stays unchanged.")
                            .font(.footnote).foregroundStyle(.secondary)
                        Text("Choose a self-contained repository or a bare repository. External Git directories and shared object stores are not supported.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } else if kind == 0 {
                    Section("Repository Source") {
                        Picker("Account", selection: $source) {
                            Text("Enter URL manually").tag("manual")
                            ForEach(store.accounts) { account in
                                Text(account.accountLabel).tag(account.id.uuidString)
                            }
                        }
                        if let selectedAccount {
                            LabeledContent("Instance", value: selectedAccount.detail)
                        }
                    }
                    if let selectedAccount {
                        Section("Your Repositories") {
                            TextField("Local Name", text: $name)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            remoteProjects(for: selectedAccount)
                        }
                        if !url.isEmpty {
                            Section("Selected Repository") {
                                LabeledContent("Remote URL", value: url)
                                if !resolvedName.isEmpty {
                                    LabeledContent("Local Name", value: resolvedName)
                                }
                            }
                        }
                    } else {
                        Section("Repository") {
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
                        }
                    }
                } else {
                    Section("Repository") {
                        TextField("Local Name", text: $name)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                }
                if kind == 0, selectedAccount == nil, SSHURL.isSSH(url) {
                    Section("SSH") {
                        Picker("SSH Key", selection: $sshKeyID) {
                            Text("Password or none").tag("")
                            ForEach(store.sshKeys) { key in
                                Text(key.name).tag(key.id.uuidString)
                            }
                        }
                        if store.sshKeys.isEmpty {
                            Text("Import an SSH key in Settings.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if kind != 2 {
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
            }
            .navigationTitle(kind == 2 ? String(localized: "Copy Import") : (kind == 0 ? String(localized: "Clone") : String(localized: "New Local Repository")))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(kind == 2 ? String(localized: "Import") : String(localized: "Create")) { submit() }
                        .disabled(!canSubmit)
                }
            }
            .onChange(of: source) { _, newValue in
                url = ""
                repoQuery = ""
                guard newValue != "manual", let account = selectedAccount else {
                    store.clearRemoteProjects()
                    return
                }
                store.loadRemoteProjects(for: account)
            }
            .fileImporter(isPresented: $pickFolder, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    let accessing = url.startAccessingSecurityScopedResource()
                    defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                    do {
                        let bookmark = try WorktreeLink.bookmark(for: url)
                        if kind == 2 {
                            importBookmark = bookmark
                            importFolderName = url.lastPathComponent
                            if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                name = url.lastPathComponent.hasSuffix(".git") ? String(url.lastPathComponent.dropLast(4)) : url.lastPathComponent
                            }
                        } else {
                            folderBookmark = bookmark
                            folderName = url.lastPathComponent
                        }
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

    private var selectedAccount: RemoteAccount? {
        guard source != "manual", let id = UUID(uuidString: source) else { return nil }
        return store.account(id: id)
    }

    @ViewBuilder
    private func remoteProjects(for account: RemoteAccount) -> some View {
        if store.isLoadingRemoteProjects && store.remoteProjectsAccountID == account.id {
            ProgressView()
        } else if store.remoteProjectsAccountID == account.id {
            TextField("Search repositories", text: $repoQuery)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            ForEach(filteredRemoteProjects) { project in
                Button {
                    url = project.cloneURL
                    if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        name = project.name
                    }
                } label: {
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(project.fullName)
                            if !project.description.isEmpty {
                                Text(project.description)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Text(projectDetail(project))
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        Spacer(minLength: 4)
                        if url == project.cloneURL {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.tint)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            if let message = store.remoteProjectsMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var filteredRemoteProjects: [RemoteProject] {
        let query = repoQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return store.remoteProjects }
        return store.remoteProjects.filter {
            $0.fullName.localizedStandardContains(query)
                || $0.description.localizedStandardContains(query)
        }
    }

    private func projectDetail(_ project: RemoteProject) -> String {
        var parts: [String] = []
        if project.stars > 0 { parts.append("★ \(project.stars)") }
        if !project.language.isEmpty { parts.append(project.language) }
        if parts.isEmpty { parts.append(project.provider.title) }
        return parts.joined(separator: " · ")
    }

    private var folderDisplay: String {
        let repoName = kind == 0 ? resolvedName : name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let folderName else { return "" }
        if repoName.isEmpty { return folderName }
        return "\(folderName)/\(repoName)"
    }

    private var savedAccount: String? {
        guard secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let account = store.account(for: url) else { return nil }
        return account.username
    }

    private var canSubmit: Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if kind == 2 { return importBookmark != nil && !trimmedName.isEmpty }
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
        if kind == 2 {
            guard let importBookmark else { return }
            store.importRepository(name: name, sourceBookmark: importBookmark)
        } else if kind == 0 {
            store.clone(
                url: url,
                name: resolvedName,
                username: username.trimmingCharacters(in: .whitespacesAndNewlines),
                secret: secret,
                accountID: selectedAccount?.id,
                sshKeyID: selectedAccount == nil ? UUID(uuidString: sshKeyID) : nil,
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
    @State private var showGitLabAccount = false
    @State private var showSSHImport = false

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
                sshKeysSection
                accountsSection
                Section("Files") {
                    Button("Show in Files") {
                        Task {
                            filesInfo = await store.filesLocationExplanation()
                        }
                    }
                    Group {
                        if !FileProviderRegistration.usesProviderLocation {
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
            .sheet(isPresented: $showGitLabAccount) {
                GitLabAccountSheet()
            }
            .sheet(isPresented: $showSSHImport) {
                SSHKeyImportSheet()
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
    private var sshKeysSection: some View {
        Section("SSH Keys") {
            if store.sshKeys.isEmpty {
                Text("No SSH keys yet. Import a private key to clone over SSH.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(store.sshKeys) { key in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(key.name)
                            Text("Stored in Keychain")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(role: .destructive) {
                            store.removeSSHKey(key)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(Text("Remove SSH Key"))
                    }
                }
            }
            Button("Import SSH Key") {
                showSSHImport = true
            }
        }
    }

    @ViewBuilder
    private var accountsSection: some View {
        Section("Accounts") {
            if store.accounts.isEmpty {
                Text("No accounts yet. Add GitHub or GitLab to clone remote repositories.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(store.accounts) { account in
                    HStack(alignment: .center, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(account.displayName)
                            Text(account.accountLabel)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(account.detail)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Spacer(minLength: 4)
                        Button(role: .destructive) {
                            store.removeAccount(account)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(Text("Remove Account"))
                    }
                }
            }

            if let prompt = store.githubPrompt {
                Text(prompt.userCode)
                    .font(.title.monospaced())
                    .textSelection(.enabled)
                Text(String(format: String(localized: "Approve the sign-in in your browser. Your code is %@."), prompt.userCode))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Open Verification Page") { openURL(prompt.url) }
                Button("Cancel") { store.cancelGitHub() }
            } else {
                Button("Add GitHub Account") {
                    store.connectGitHub { openURL($0) }
                }
                .disabled(store.githubBusy)
            }
            Button("Add GitLab Account") {
                showGitLabAccount = true
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
private struct GitLabAccountSheet: View {
    @EnvironmentObject private var store: RepoStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var baseURL = "https://gitlab.com"
    @State private var token = ""
    @State private var displayName = ""
    @State private var isConnecting = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("GitLab Instance") {
                    TextField("GitLab instance URL", text: $baseURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    Text("Use the instance root, for example https://gitlab.example.com or https://gitlab.com.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("HTTP sends tokens in clear text. Use it only on a trusted network.")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                    TextField("Display Name (optional)", text: $displayName)
                        .textInputAutocapitalization(.words)
                }
                Section("Personal Access Token") {
                    SecureField("Personal Access Token", text: $token)
                    Text("Create a token with read_api, read_user, read_repository, and write_repository.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if let tokenSettingsURL {
                        Button("Open GitLab Token Settings") {
                            openURL(tokenSettingsURL)
                        }
                    }
                }
                if let error {
                    Section {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Add GitLab Account")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(isConnecting)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isConnecting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isConnecting {
                        ProgressView()
                    } else {
                        Button("Connect") { connect() }
                            .disabled(baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                || token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }
    }

    private var tokenSettingsURL: URL? {
        guard let base = InstanceURL.canonical(baseURL) else { return nil }
        var components = URLComponents(
            url: base.appendingPathComponent("-/user_settings/personal_access_tokens"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(
                name: "scopes",
                value: "read_api,read_user,read_repository,write_repository"
            ),
        ]
        return components?.url
    }

    private func connect() {
        isConnecting = true
        error = nil
        Task {
            do {
                _ = try await store.connectGitLab(
                    baseURL: baseURL,
                    token: token,
                    displayName: displayName
                )
                dismiss()
            } catch {
                self.error = error.localizedDescription
                isConnecting = false
            }
        }
    }
}


private struct SSHKeyImportSheet: View {
    @EnvironmentObject private var store: RepoStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var passphrase = ""
    @State private var privateKey = ""
    @State private var fileName = ""
    @State private var error: String?
    @State private var isImporting = false
    @State private var pickFile = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Private Key") {
                    Button("Choose Private Key File") { pickFile = true }
                    if !fileName.isEmpty {
                        Text(fileName)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Text("Import an existing private key. Generated keys and key export are not available yet.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("Name") {
                    TextField("Key Name", text: $name)
                        .textInputAutocapitalization(.words)
                }
                Section("Passphrase") {
                    SecureField("Passphrase (optional)", text: $passphrase)
                    Text("The passphrase is stored in the Keychain and used when the key is unlocked.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let error {
                    Section {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Import SSH Key")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(isImporting)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isImporting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") { importKey() }
                        .disabled(privateKey.isEmpty || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .fileImporter(isPresented: $pickFile, allowedContentTypes: [.item], allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    let accessing = url.startAccessingSecurityScopedResource()
                    defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                    do {
                        let data = try Data(contentsOf: url)
                        guard data.count <= 128 * 1024,
                              let text = String(data: data, encoding: .utf8),
                              text.contains("PRIVATE KEY-----") else {
                            error = String(localized: "Could not read that private key.")
                            return
                        }
                        privateKey = text
                        fileName = url.lastPathComponent
                        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            name = url.deletingPathExtension().lastPathComponent
                        }
                        error = nil
                    } catch {
                        self.error = String(localized: "Could not read that private key.")
                    }
                case .failure:
                    error = String(localized: "Could not read that private key.")
                }
            }
        }
    }

    private func importKey() {
        isImporting = true
        guard store.addSSHKey(name: name, privateKey: privateKey, passphrase: passphrase) != nil else {
            error = String(localized: "Could not read that private key.")
            isImporting = false
            return
        }
        dismiss()
    }
}
