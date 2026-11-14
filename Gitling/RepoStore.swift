import Foundation

@MainActor
final class RepoStore: ObservableObject {
    let root: URL
    @Published var repos: [RepoSummary] = []
    @Published var isBusy = false
    @Published var statusLine = ""
    @Published private(set) var operationProgress: OperationProgressState?
    private var progressRelay: GitProgressRelay?
    private var activeProgressID: UUID?
    @Published var alert: String?
    @Published var revision = 0
    @Published var userName: String
    @Published var userEmail: String
    @Published var githubPrompt: GitHubPrompt?
    @Published var githubMessage: String?
    @Published private(set) var accounts: [RemoteAccount] = []
    @Published private(set) var sshKeys: [SSHKey] = []
    @Published var remoteProjects: [RemoteProject] = []
    @Published var remoteProjectsMessage: String?
    @Published var isLoadingRemoteProjects = false
    @Published private(set) var remoteProjectsAccountID: UUID?
    @Published var focusName: String?
    private var githubTask: Task<Void, Never>?
    private var githubGeneration = 0
    private var remoteProjectsGeneration = 0
    private var reloadGeneration = 0
    private var reloadCycle: ReloadCycle?
    private let statusSummary: @Sendable (URL) -> RepoSummary?
    private struct ReloadCycle {
        var metadata: Task<[RepoSummary], Never>
        var statuses: Task<Void, Never>
    }

    struct GitHubPrompt: Equatable {
        var userCode: String
        var url: URL
    }

    var githubBusy: Bool { githubTask != nil && githubPrompt == nil }

    init(root: URL? = nil, reloadOnStart: Bool = true,
         statusSummary: @escaping @Sendable (URL) -> RepoSummary? = { GitClient.summary(at: $0) }) {
        self.statusSummary = statusSummary
        self.root = root ?? RepoStorage.repositoriesRoot()
        userName = UserDefaults.standard.string(forKey: Keys.name) ?? ""
        userEmail = UserDefaults.standard.string(forKey: Keys.email) ?? ""
        loadAccounts()
        loadSSHKeys()
        loadCachedRepos()
        if reloadOnStart {
            Task {
                if root == nil {
                    await Task.detached { RepoStorage.migrateLegacyRepositoriesIfNeeded() }.value
                    if FileProviderRegistration.usesProviderLocation { FileProviderRegistration.register() }
                }
                await reload(waitForStatus: false)
            }
        }
    }

    /// UI refresh waits only for branch metadata; expensive status scans publish
    /// per row in the background. Callers performing writes can await completion.
    func reload(repository name: String? = nil, waitForStatus: Bool = true) async {
        if name == nil, let cycle = reloadCycle {
            _ = await cycle.metadata.value
            if waitForStatus { await cycle.statuses.value }
            return
        }
        reloadGeneration += 1
        let generation = reloadGeneration
        reloadCycle?.metadata.cancel(); reloadCycle?.statuses.cancel(); reloadCycle = nil
        let root = root, reader = statusSummary
        if let name {
            let url = root.appendingPathComponent(name)
            let metadata = await Task.detached { () -> RepoSummary? in
                guard FileManager.default.fileExists(atPath: url.path) else { return nil }
                return GitClient.summaryMetadata(at: url)
            }.value
            guard generation == reloadGeneration else { return }
            replaceSummary(metadata, named: name)
            let summary = metadata == nil ? nil : await Task.detached { reader(url) }.value
            guard generation == reloadGeneration else { return }
            if let summary { replaceSummary(summary, named: name) }
            else if metadata != nil {
                var unknown = metadata!; unknown.statusState = .unavailable
                replaceSummary(unknown, named: name)
            }
            saveCachedRepos()
            resumePendingStatuses(generation: generation)
            return
        }
        let metadata = Task.detached { () -> [RepoSummary] in
            var summaries: [RepoSummary] = []
            for name in GitClient.repositoryNames(root: root) {
                if Task.isCancelled { break }
                summaries.append(GitClient.summaryMetadata(at: root.appendingPathComponent(name)))
            }
            if !Task.isCancelled { await self.publishMetadata(summaries, generation: generation) }
            return summaries
        }
        let statuses = readStatuses(metadata: metadata, generation: generation, root: root, reader: reader)
        reloadCycle = ReloadCycle(metadata: metadata, statuses: statuses)
        _ = await metadata.value
        if waitForStatus { await statuses.value }
    }

    private func readStatuses(metadata: Task<[RepoSummary], Never>, generation: Int, root: URL,
                              reader: @escaping @Sendable (URL) -> RepoSummary?) -> Task<Void, Never> {
        return Task { @MainActor [weak self] in
            let summaries = await metadata.value
            guard let self, !Task.isCancelled, generation == self.reloadGeneration else { return }
            for metadata in summaries where !metadata.unavailable && metadata.statusState == .checking {
                guard !Task.isCancelled, generation == self.reloadGeneration else { return }
                let url = root.appendingPathComponent(metadata.name)
                let summary = await Task.detached { reader(url) }.value
                guard !Task.isCancelled, generation == self.reloadGeneration else { return }
                if let summary { self.replaceSummary(summary, named: metadata.name) }
                else {
                    var unknown = metadata; unknown.statusState = .unavailable
                    self.replaceSummary(unknown, named: metadata.name)
                }
            }
            self.saveCachedRepos()
            self.reloadCycle = nil
        }
    }

    private func resumePendingStatuses(generation: Int) {
        let pending = repos.filter { !$0.unavailable && $0.statusState == .checking }
        guard !pending.isEmpty else { return }
        let metadata = Task.detached { pending }
        let statuses = readStatuses(metadata: metadata, generation: generation, root: root, reader: statusSummary)
        reloadCycle = ReloadCycle(metadata: metadata, statuses: statuses)
    }

    private func publishMetadata(_ summaries: [RepoSummary], generation: Int) {
        guard generation == reloadGeneration else { return }
        if repos != summaries { repos = summaries }
    }

    private func replaceSummary(_ summary: RepoSummary?, named name: String) {
        var updated = repos.filter { $0.name != name }
        if let summary { updated.append(summary) }
        updated.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if repos != updated { repos = updated }
    }

    func saveIdentity() {
        userName = userName.trimmingCharacters(in: .whitespacesAndNewlines)
        userEmail = userEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(userName, forKey: Keys.name)
        UserDefaults.standard.set(userEmail, forKey: Keys.email)
    }

    // MARK: Accounts

    func account(id: UUID?) -> RemoteAccount? {
        guard let id else { return nil }
        return accounts.first { $0.id == id }
    }

    func accounts(for provider: GitProvider) -> [RemoteAccount] {
        accounts.filter { $0.provider == provider }
    }

    func secret(for account: RemoteAccount) -> String? {
        KeychainStore.loadSecret(accountID: account.id)
    }

    @discardableResult
    func addAccount(
        provider: GitProvider,
        baseURL: String,
        username: String,
        token: String,
        displayName: String? = nil
    ) -> RemoteAccount? {
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty, !trimmedToken.isEmpty else { return nil }
        let canonical = InstanceURL.canonical(baseURL) ?? URL(string: "https://github.com")!
        let base = canonical.absoluteString
        let name = displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let index = accounts.firstIndex(where: {
            $0.provider == provider && $0.baseURL == base && $0.username == username
        }) {
            accounts[index].displayName = name.isEmpty ? accounts[index].displayName : name
            KeychainStore.saveSecret(trimmedToken, accountID: accounts[index].id)
            saveAccounts()
            revision += 1
            return accounts[index]
        }
        let account = RemoteAccount(
            id: UUID(),
            provider: provider,
            baseURL: base,
            username: username,
            displayName: name.isEmpty ? username : name,
            createdAt: Date()
        )
        KeychainStore.saveSecret(trimmedToken, accountID: account.id)
        accounts.append(account)
        saveAccounts()
        revision += 1
        return account
    }

    func removeAccount(_ account: RemoteAccount) {
        KeychainStore.deleteSecret(accountID: account.id)
        accounts.removeAll { $0.id == account.id }
        var links = repoAccountLinks()
        links = links.filter { $0.value != account.id.uuidString }
        UserDefaults.standard.set(links, forKey: Keys.repoAccounts)
        saveAccounts()
        revision += 1
    }

    func linkedAccountID(for repoName: String) -> UUID? {
        repoAccountLinks()[repoName].flatMap(UUID.init(uuidString:))
    }

    func linkRepo(_ repoName: String, to account: RemoteAccount) {
        var links = repoAccountLinks()
        links[repoName] = account.id.uuidString
        UserDefaults.standard.set(links, forKey: Keys.repoAccounts)
    }

    func removeRepoLink(_ repoName: String) {
        var links = repoAccountLinks()
        links.removeValue(forKey: repoName)
        UserDefaults.standard.set(links, forKey: Keys.repoAccounts)
        var sshLinks = repoSSHKeyLinks()
        sshLinks.removeValue(forKey: repoName)
        UserDefaults.standard.set(sshLinks, forKey: Keys.repoSSHKeys)
    }

    func account(for urlString: String, repoName: String? = nil) -> RemoteAccount? {
        if let repoName,
           let id = linkedAccountID(for: repoName),
           let linked = account(id: id), matchesTransport(linked, url: urlString) {
            return linked
        }
        return accounts.first { matchesTransport($0, url: urlString) }
    }

    private func matchesTransport(_ account: RemoteAccount, url: String) -> Bool {
        if SSHURL.isSSH(url) { return account.instanceURL?.host?.lowercased() == SSHURL.host(url) }
        return account.matches(url)
    }

    func accountUsername(for urlString: String, repoName: String? = nil) -> String? {
        account(for: urlString, repoName: repoName)?.username
    }

    func connectGitLab(baseURL: String, token: String, displayName: String?) async throws -> RemoteAccount {
        guard let url = InstanceURL.canonical(baseURL) else {
            throw GitLabClientError.invalidInstance
        }
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw GitLabClientError.unauthorized }
        let user = try await GitLabClient.fetchUser(baseURL: url, token: trimmed)
        guard let account = addAccount(
            provider: .gitlab,
            baseURL: url.absoluteString,
            username: user.username,
            token: trimmed,
            displayName: displayName
        ) else {
            throw GitLabClientError.invalidResponse
        }
        return account
    }

    // MARK: SSH keys

    func sshKey(id: UUID?) -> SSHKey? {
        guard let id else { return nil }
        return sshKeys.first { $0.id == id }
    }

    @discardableResult
    func addSSHKey(name: String, privateKey: String, passphrase: String?) -> SSHKey? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedKey = privateKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !trimmedKey.isEmpty else { return nil }
        let key = SSHKey(id: UUID(), name: trimmedName, createdAt: Date())
        KeychainStore.saveSSHKey(trimmedKey, id: key.id)
        KeychainStore.saveSSHPassphrase(passphrase, id: key.id)
        sshKeys.append(key)
        saveSSHKeys()
        revision += 1
        return key
    }

    func removeSSHKey(_ key: SSHKey) {
        KeychainStore.deleteSSHKey(id: key.id)
        sshKeys.removeAll { $0.id == key.id }
        var links = repoSSHKeyLinks()
        links = links.filter { $0.value != key.id.uuidString }
        UserDefaults.standard.set(links, forKey: Keys.repoSSHKeys)
        saveSSHKeys()
        revision += 1
    }

    func linkedSSHKeyID(for repoName: String) -> UUID? {
        repoSSHKeyLinks()[repoName].flatMap(UUID.init(uuidString:))
    }

    func linkRepoSSHKey(_ repoName: String, to key: SSHKey) {
        var links = repoSSHKeyLinks()
        links[repoName] = key.id.uuidString
        UserDefaults.standard.set(links, forKey: Keys.repoSSHKeys)
    }

    func sshKeyMaterial(for id: UUID?) -> SSHKeyMaterial? {
        guard let id,
              let privateKey = KeychainStore.loadSSHKey(id: id),
              !privateKey.isEmpty else { return nil }
        return SSHKeyMaterial(
            privateKey: privateKey,
            passphrase: KeychainStore.loadSSHPassphrase(id: id)
        )
    }

    private func sshKeyMaterial(for urlString: String, repoName: String) -> SSHKeyMaterial? {
        guard SSHURL.isSSH(urlString) else { return nil }
        if let id = linkedSSHKeyID(for: repoName) {
            return sshKeyMaterial(for: id)
        }
        return nil
    }

    private func lfsAuth(for urlString: String, repoName: String) -> LFSAuth? {
        let matched = account(for: urlString, repoName: repoName)
        guard let matched, let token = secret(for: matched), !token.isEmpty else { return nil }
        return LFSAuth(
            username: matched.provider == .gitlab ? "oauth2" : matched.username,
            secret: token,
            instanceBaseURL: URL(string: matched.baseURL)
        )
    }

    // MARK: Remote projects

    func clearRemoteProjects() {
        remoteProjectsGeneration += 1
        remoteProjects = []
        remoteProjectsMessage = nil
        isLoadingRemoteProjects = false
        remoteProjectsAccountID = nil
    }

    func loadRemoteProjects(for account: RemoteAccount) {
        remoteProjectsGeneration += 1
        let generation = remoteProjectsGeneration
        guard let token = KeychainStore.loadSecret(accountID: account.id), !token.isEmpty else {
            remoteProjects = []
            remoteProjectsAccountID = account.id
            remoteProjectsMessage = String(localized: "Reconnect this account to load its repositories.")
            isLoadingRemoteProjects = false
            return
        }
        remoteProjects = []
        remoteProjectsMessage = nil
        remoteProjectsAccountID = account.id
        isLoadingRemoteProjects = true
        Task {
            do {
                let projects: [RemoteProject]
                switch account.provider {
                case .github:
                    let repos = try await GitHubAuth.fetchRepos(token: token)
                    projects = repos.map { repo in
                        RemoteProject(
                            id: "github:\(repo.fullName)",
                            provider: .github,
                            name: repo.name,
                            fullName: repo.fullName,
                            description: repo.description,
                            cloneURL: repo.cloneURL,
                            stars: repo.stars,
                            language: repo.language
                        )
                    }
                case .gitlab:
                    projects = try await GitLabClient.fetchProjects(baseURL: URL(string: account.baseURL)!, token: token)
                }
                guard generation == remoteProjectsGeneration else { return }
                remoteProjects = projects
                if projects.isEmpty {
                    remoteProjectsMessage = account.provider == .github
                        ? String(localized: "This GitHub account has no repositories.")
                        : String(localized: "This GitLab account has no repositories.")
                }
            } catch {
                guard generation == remoteProjectsGeneration else { return }
                remoteProjects = []
                remoteProjectsMessage = error.localizedDescription
            }
            if generation == remoteProjectsGeneration {
                isLoadingRemoteProjects = false
            }
        }
    }

    private struct CachedRepos: Codable {
        var root: String
        var repos: [RepoSummary]
    }

    private func loadCachedRepos() {
        guard let data = UserDefaults.standard.data(forKey: Keys.repoCache),
              let cached = try? JSONDecoder().decode(CachedRepos.self, from: data),
              cached.root == root.path else { return }
        repos = cached.repos.map { value in
            var value = value
            if !value.unavailable { value.statusState = .checking }
            return value
        }
    }

    private func saveCachedRepos() {
        let cached = CachedRepos(root: root.path, repos: repos)
        guard let data = try? JSONEncoder().encode(cached) else { return }
        UserDefaults.standard.set(data, forKey: Keys.repoCache)
    }

    private func repoAccountLinks() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: Keys.repoAccounts) as? [String: String] ?? [:]
    }
    private func repoSSHKeyLinks() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: Keys.repoSSHKeys) as? [String: String] ?? [:]
    }

    private func loadSSHKeys() {
        guard let data = UserDefaults.standard.data(forKey: Keys.sshKeys),
              let decoded = try? JSONDecoder().decode([SSHKey].self, from: data) else { return }
        sshKeys = decoded
    }

    private func saveSSHKeys() {
        guard let data = try? JSONEncoder().encode(sshKeys) else { return }
        UserDefaults.standard.set(data, forKey: Keys.sshKeys)
    }

    private func loadAccounts() {
        if let data = UserDefaults.standard.data(forKey: Keys.accounts),
           let decoded = try? JSONDecoder().decode([RemoteAccount].self, from: data) {
            accounts = decoded
        }
        migrateLegacyGitHubAccountIfNeeded()
    }

    private func saveAccounts() {
        guard let data = try? JSONEncoder().encode(accounts) else { return }
        UserDefaults.standard.set(data, forKey: Keys.accounts)
    }

    private func migrateLegacyGitHubAccountIfNeeded() {
        guard accounts.isEmpty,
              let legacy = KeychainStore.load(host: GitHubAuth.host),
              !legacy.secret.isEmpty else { return }
        let account = RemoteAccount(
            id: UUID(),
            provider: .github,
            baseURL: "https://github.com",
            username: legacy.username,
            displayName: legacy.username,
            createdAt: Date()
        )
        KeychainStore.saveSecret(legacy.secret, accountID: account.id)
        accounts = [account]
        saveAccounts()
    }

    func clone(
        url: String,
        name: String,
        username: String,
        secret: String,
        accountID: UUID? = nil,
        sshKeyID: UUID? = nil,
        worktreeBookmark: Data? = nil
    ) {
        let root = root
        let originalURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let split = GitRemoteURL.splitUserInfo(originalURL)
        let url = split.url
        var username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        var secret = secret
        if username.isEmpty, let fromURL = split.username, !fromURL.isEmpty {
            username = fromURL
        }
        if secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let password = split.password, !password.isEmpty {
            secret = password
        }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard GitRemoteURL.isSupported(url) else {
            alert = String(localized: "Only HTTP, HTTPS, and SSH repositories are supported.")
            return
        }
        let chosen = account(id: accountID)
        let chosenSSHKey = sshKey(id: sshKeyID)
        let sshMaterial = sshKeyMaterial(for: sshKeyID)
        let lfs = lfsAuth(for: url, repoName: name)
        let creds = credentials(
            for: chosen,
            urlString: url,
            repoName: name,
            username: username,
            secret: secret
        )
        let suppliedSecret = secret
        runProgress(String(localized: "Cloning…"), repository: name, publishStorage: true, focus: name, linkAccount: chosen, linkSSHKey: chosenSSHKey) { progress in
            try GitClient.clone(
                url: url,
                name: name,
                root: root,
                username: creds.username,
                secret: creds.secret,
                sshKey: sshMaterial,
                lfsAuth: lfs,
                worktreeBookmark: worktreeBookmark,
                progress: progress
            )
            if chosen == nil, let host = GitClient.host(of: url), !suppliedSecret.isEmpty {
                KeychainStore.save(host: host, username: creds.username, secret: creds.secret)
            }
        }
    }

    private func credentials(
        for account: RemoteAccount?,
        urlString: String,
        repoName: String,
        username: String,
        secret: String
    ) -> (username: String, secret: String) {
        let typedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let typedSecret = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typedSecret.isEmpty {
            return (typedUsername, typedSecret)
        }
        let matched = account ?? self.account(for: urlString, repoName: repoName)
        if let matched, let token = self.secret(for: matched), !token.isEmpty {
            return (matched.provider == .gitlab ? "oauth2" : matched.username, token)
        }
        let legacy = GitClient.host(of: urlString).flatMap { KeychainStore.load(host: $0) }
        return RemoteCredentials.resolve(username: typedUsername, secret: typedSecret, saved: legacy)
    }

    func connectGitHub(open: @escaping (URL) -> Void) {
        githubGeneration += 1
        let generation = githubGeneration
        githubTask?.cancel()
        githubMessage = nil
        githubPrompt = nil
        githubTask = Task {
            defer { if githubGeneration == generation { githubTask = nil } }
            do {
                let code = try await GitHubAuth.requestDeviceCode()
                guard githubGeneration == generation else { return }
                guard let page = code.pageURL else { throw GitHubAuthError.unreachable }
                githubPrompt = GitHubPrompt(userCode: code.userCode, url: page)
                open(page)
                let token = try await GitHubAuth.poll(
                    deviceCode: code.deviceCode,
                    interval: code.interval,
                    expiresIn: code.expiresIn
                )
                guard githubGeneration == generation else { return }
                let login = try await GitHubAuth.fetchLogin(token: token)
                guard githubGeneration == generation else { return }
                _ = addAccount(
                    provider: .github,
                    baseURL: "https://github.com",
                    username: login,
                    token: token,
                    displayName: login
                )
                githubPrompt = nil
                githubMessage = String(format: String(localized: "Connected as %@"), login)
                revision += 1
            } catch is CancellationError {
                if githubGeneration == generation { githubPrompt = nil }
            } catch {
                if githubGeneration == generation {
                    githubPrompt = nil
                    githubMessage = error.localizedDescription
                }
            }
        }
    }

    func cancelGitHub() {
        githubGeneration += 1
        githubTask?.cancel()
        githubTask = nil
        githubPrompt = nil
    }

    func account(for urlString: String, repoName: String, username: String, secret: String) -> (username: String, secret: String) {
        credentials(
            for: account(for: urlString, repoName: repoName),
            urlString: urlString,
            repoName: repoName,
            username: username,
            secret: secret
        )
    }

    func create(name: String, worktreeBookmark: Data? = nil) {
        let root = root
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        run(String(localized: "Creating…"), repository: name, publishStorage: true, focus: name) {
            try GitClient.initialize(name: name, root: root, worktreeBookmark: worktreeBookmark)
        }
    }

    func importRepository(name: String, sourceBookmark: Data) {
        let root = root
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        run(String(localized: "Importing…"), repository: name, publishStorage: true, resetLinks: true, focus: name) {
            var stale = false
            let source = try URL(resolvingBookmarkData: sourceBookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
            let started = source.startAccessingSecurityScopedResource()
            defer { if started { source.stopAccessingSecurityScopedResource() } }
            let coordinator = NSFileCoordinator()
            var coordinationError: NSError?
            var outcome: Result<Void, Error>?
            coordinator.coordinate(readingItemAt: source, options: .withoutChanges, error: &coordinationError) { location in
                outcome = Result { try GitClient.importRepository(from: location, name: name, root: root) }
            }
            if let coordinationError { throw coordinationError }
            guard let outcome else { throw RepositoryImporter.Failure.invalidSource }
            try outcome.get()
        }
    }

    func delete(name: String) {
        let url = root.appendingPathComponent(name, isDirectory: true)
        removeRepoLink(name)
        RepoDetailCache.remove(name)
        run(String(localized: "Working…"), repository: name, publishStorage: true) {
            try RepoWriteLock.withLock(at: url) {
                try RepoStorage.removeRepository(named: name)
                WorktreeLink.remove(repoName: name)
            }
        }
    }

    func link(name: String, bookmark: Data) {
        let url = repoURL(name)
        run(String(localized: "Working…"), repository: name, publishStorage: true, focus: name) {
            try GitClient.link(at: url, bookmark: bookmark)
        }
    }

    func unlink(name: String) {
        let url = repoURL(name)
        run(String(localized: "Working…"), repository: name, publishStorage: true, focus: name) {
            try GitClient.unlink(at: url)
        }
    }

    func filesLocationExplanation() async -> String {
        if !FileProviderRegistration.usesProviderLocation {
            return String(localized: "In the Files app, open On My iPhone, then Gitling.")
        }
        return await withCheckedContinuation { continuation in
            FileProviderRegistration.register { problem in
                var text = String(localized: "In the Files app, open Browse, tap the More button, tap Edit, and turn on Gitling.")
                if let problem { text += "\n\n" + problem }
                continuation.resume(returning: text)
            }
        }
    }

    func stageAll(name: String) {
        runWithRemote(String(localized: "Working…"), name: name) { url, _, lfs in
            try GitClient.stageAll(at: url, lfsAuth: lfs)
        }
    }

    func stage(name: String, entry: StatusEntry) {
        runWithRemote(String(localized: "Working…"), name: name) { url, _, lfs in
            try GitClient.stage(at: url, path: entry.path, originalPath: entry.originalPath, lfsAuth: lfs)
        }
    }

    func updateSubmodules(name: String, action: SubmoduleAction, recursive: Bool, initializeMissing: Bool,
                          resume: Bool = false, selectedAccounts: [String: UUID] = [:], selectedSSHKeys: [String: UUID] = [:], overrides: [String: SubmoduleCredentials] = [:]) {
        let url = repoURL(name)
        let auth = submoduleAuth(name: name, selectedAccounts: selectedAccounts, selectedSSHKeys: selectedSSHKeys, overrides: overrides)
        runProgress(String(localized: "Updating submodules…"), repository: name, publishStorage: true) { progress in
            try GitClient.updateSubmodules(at: url, action: action, recursive: recursive, initializeMissing: initializeMissing, resume: resume, auth: auth, progress: progress)
        }
    }

    /// Capture credentials before leaving the main actor. Provider tokens stay
    /// in the path-scoped account router; only legacy manual sign-in is inherited.
    func submoduleAuth(name: String, selectedAccounts: [String: UUID] = [:],
                       selectedSSHKeys: [String: UUID] = [:], overrides: [String: SubmoduleCredentials] = [:]) -> SubmoduleAuth {
        let url = repoURL(name)
        let accounts = accounts.compactMap { account -> SubmoduleAccountSecret? in
            guard let secret = secret(for: account) else { return nil }
            return .init(account: account, secret: secret)
        }.sorted { $0.account.id == linkedAccountID(for: name) && $1.account.id != linkedAccountID(for: name) }
        var keys = selectedSSHKeys.compactMapValues { sshKeyMaterial(for: $0) }
        var inherited: [String: SubmoduleCredentials] = [:]
        // The repository's linked key is scoped to its own SSH authority.
        // HTTP sign-in is reused only for a submodule on that same scheme, host, and port.
        if let origin = try? GitClient.originURL(url) {
            if SSHURL.isSSH(origin),
               let authority = SubmoduleAuth.authority(origin), keys[authority] == nil,
               let key = sshKeyMaterial(for: linkedSSHKeyID(for: name)) { keys[authority] = key }
            let split = GitRemoteURL.splitUserInfo(origin)
            if !SSHURL.isSSH(origin), account(for: split.url, repoName: name) == nil {
                let saved = GitClient.host(of: split.url).flatMap { KeychainStore.load(host: $0) }
                inherited = SubmoduleCredentialRouter.parentCredentials(origin: origin,
                    username: split.username ?? saved?.username ?? "", secret: split.password ?? saved?.secret ?? "")
            }
        }
        let router = SubmoduleCredentialRouter(accounts: accounts, selectedAccounts: selectedAccounts, sshKeys: keys, overrides: overrides, inherited: inherited)
        return SubmoduleAuth(resolve: { router.credentials(for: $0) })
    }

    func endSubmoduleUpdate(name: String) {
        let url = repoURL(name)
        run(String(localized: "Working…"), repository: name) { try GitClient.endSubmoduleUpdate(at: url) }
    }

    func restoreFile(name: String, plan: FileRestorePlan) {
        let url = repoURL(name)
        run(String(localized: "Working…"), repository: name, publishStorage: true) {
            try GitClient.restoreFile(at: url, plan: plan)
        }
    }

    func unstage(name: String, entry: StatusEntry) {
        let url = repoURL(name)
        run(String(localized: "Working…"), repository: name) {
            try GitClient.unstage(at: url, path: entry.path, originalPath: entry.originalPath)
        }
    }

    func saveStash(name: String, message: String, includeUntracked: Bool) {
        let url = repoURL(name)
        let userName = userName
        let userEmail = userEmail
        run(String(localized: "Working…"), repository: name) {
            try GitClient.saveStash(at: url, message: message, includeUntracked: includeUntracked, name: userName, email: userEmail)
        }
    }

    func applyStash(name: String, oid: String, pop: Bool) {
        let url = repoURL(name)
        run(String(localized: "Working…"), repository: name) { try GitClient.applyStash(at: url, oid: oid, pop: pop) }
    }

    func dropStash(name: String, oid: String) {
        let url = repoURL(name)
        run(String(localized: "Working…"), repository: name) { try GitClient.dropStash(at: url, oid: oid) }
    }

    func renameBranch(name: String, branch: String, to newName: String) {
        let url = repoURL(name)
        run(String(localized: "Working…"), repository: name) { try GitClient.renameBranch(at: url, branch: branch, to: newName) }
    }

    func deleteBranch(name: String, branch: String) {
        let url = repoURL(name)
        run(String(localized: "Working…"), repository: name) { try GitClient.deleteBranch(at: url, branch: branch) }
    }

    func setUpstream(name: String, branch: String, upstream: String?) {
        let url = repoURL(name)
        run(String(localized: "Working…"), repository: name) { try GitClient.setUpstream(at: url, branch: branch, upstream: upstream) }
    }

    func unstageAll(name: String) {
        let url = repoURL(name)
        run(String(localized: "Working…"), repository: name) { try GitClient.unstageAll(at: url) }
    }

    func commit(name: String, message: String) {
        let url = repoURL(name)
        let userName = userName
        let userEmail = userEmail
        run(String(localized: "Committing…"), repository: name) {
            try GitClient.commit(at: url, message: message, name: userName, email: userEmail)
        }
    }

    func pull(name: String, username: String, secret: String) {
        let userName = userName
        let userEmail = userEmail
        runSync(String(localized: "Pulling…"), name: name, username: username, secret: secret) { url, user, token, ssh, lfs, progress in
            try GitClient.pull(at: url, username: user, secret: token, sshKey: ssh, lfsAuth: lfs, name: userName, email: userEmail, progress: progress)
        }
    }

    func fetch(name: String, username: String, secret: String, remoteName: String? = nil) {
        runSync(String(localized: "Fetching…"), name: name, remoteName: remoteName, username: username, secret: secret) { url, user, token, ssh, lfs, progress in
            try GitClient.fetch(at: url, username: user, secret: token, sshKey: ssh, lfsAuth: lfs, remoteName: remoteName, progress: progress)
        }
    }

    func checkoutTag(name: String, detail: TagDetail, report: @escaping @MainActor (String?) -> Void) {
        guard !isBusy else { return }
        let url = repoURL(name)
        isBusy = true
        statusLine = String(localized: "Working…")
        _ = beginProgress(statusLine, repository: name)
        Task {
            let problem = await Task.detached { () -> String? in
                do { try GitClient.checkoutTag(at: url, tag: detail); return nil }
                catch { return error.localizedDescription }
            }.value
            // Present failures in the owning detail page. A root alert can
            // dismiss the operations sheet while its confirmation is closing.
            await finish(nil, repository: name, publishStorage: problem == nil)
            report(problem)
        }
    }

    func checkout(name: String, branch: String) {
        let url = repoURL(name)
        run(String(localized: "Working…"), repository: name) {
            try GitClient.checkout(at: url, branch: branch)
        }
    }

    func checkoutRemote(name: String, branch: String) {
        let url = repoURL(name)
        run(String(localized: "Working…"), repository: name) {
            try GitClient.checkoutRemote(at: url, branch: branch)
        }
    }

    func createBranch(name: String, branch: String) {
        let url = repoURL(name)
        run(String(localized: "Working…"), repository: name) {
            try GitClient.createBranch(at: url, name: branch, checkout: true)
        }
    }

    func merge(name: String, branch: String) {
        let url = repoURL(name)
        let userName = userName
        let userEmail = userEmail
        run(String(localized: "Working…"), repository: name) {
            try GitClient.mergeBranch(at: url, branch: branch, name: userName, email: userEmail)
        }
    }

    func rebase(name: String, onto branch: String) {
        let url = repoURL(name)
        let userName = userName
        let userEmail = userEmail
        run(String(localized: "Working…"), repository: name) {
            try GitClient.rebase(at: url, onto: branch, name: userName, email: userEmail)
        }
    }

    func cherryPick(name: String, commit: String) {
        let url = repoURL(name)
        let userName = userName
        let userEmail = userEmail
        run(String(localized: "Working…"), repository: name) {
            try GitClient.cherryPick(at: url, commit: commit, name: userName, email: userEmail)
        }
    }

    func continueOperation(name: String) {
        let url = repoURL(name), author = userName, email = userEmail
        run(String(localized: "Working…"), repository: name) {
            try GitClient.continueOperation(at: url, name: author, email: email)
        }
    }

    func abortOperation(name: String) {
        let url = repoURL(name)
        run(String(localized: "Working…"), repository: name) { try GitClient.abortOperation(at: url) }
    }

    func resolveConflict(name: String, conflict: ConflictFile, delete: Bool) {
        runWithRemote(String(localized: "Working…"), name: name) { url, _, lfs in
            try GitClient.resolveConflict(at: url, conflict: conflict, delete: delete, lfsAuth: lfs)
        }
    }

    func resetHard(name: String) {
        let url = repoURL(name)
        run(String(localized: "Working…"), repository: name) {
            try GitClient.resetHard(at: url)
        }
    }

    func addRemote(name: String, remote: String, url remoteURL: String) {
        let repo = repoURL(name)
        run(String(localized: "Working…"), repository: name) {
            try GitClient.addRemote(at: repo, name: remote, url: remoteURL)
        }
    }

    func removeRemote(name: String, remote: String) {
        let url = repoURL(name)
        run(String(localized: "Working…"), repository: name) {
            try GitClient.removeRemote(at: url, name: remote)
        }
    }

    func createWorkItem(name: String, itemName: String, directory: Bool) {
        let url = repoURL(name)
        run(String(localized: "Working…"), repository: name) {
            try GitClient.createWorkItem(at: url, name: itemName, directory: directory)
        }
    }

    func push(name: String, username: String, secret: String, remoteName: String? = nil) {
        runSync(String(localized: "Pushing…"), name: name, remoteName: remoteName, push: true, username: username, secret: secret) { url, user, token, ssh, lfs, progress in
            try GitClient.push(at: url, username: user, secret: token, sshKey: ssh, lfsAuth: lfs, remoteName: remoteName, progress: progress)
        }
    }

    func repoURL(_ name: String) -> URL {
        root.appendingPathComponent(name, isDirectory: true)
    }

    private func runSync(
        _ label: String, name: String, remoteName: String? = nil, push: Bool = false, username: String, secret: String,
        _ work: @escaping @Sendable (URL, String, String, SSHKeyMaterial?, LFSAuth?, @escaping GitProgressHandler) throws -> Void
    ) {
        guard !isBusy else { return }
        isBusy = true
        statusLine = label
        let progress = beginProgress(label, repository: name)
        let url = repoURL(name)
        Task {
            do {
                let remote = try await Task.detached { try GitClient.transportURL(at: url, remoteName: remoteName, push: push) }.value
                let creds = account(for: remote, repoName: name, username: username, secret: secret)
                let ssh = sshKeyMaterial(for: remote, repoName: name)
                let lfs = lfsAuth(for: remote, repoName: name)
                try await Task.detached { try work(url, creds.username, creds.secret, ssh, lfs, progress) }.value
                if !secret.isEmpty, let host = GitClient.host(of: remote) {
                    KeychainStore.save(host: host, username: creds.username, secret: creds.secret)
                }
                await finish(nil, repository: name)
            } catch { await finish(error.localizedDescription, repository: name) }
        }
    }

    private func runWithRemote(
        _ label: String,
        name: String,
        _ work: @escaping @Sendable (URL, SSHKeyMaterial?, LFSAuth?) throws -> Void
    ) {
        guard !isBusy else { return }
        isBusy = true
        statusLine = label
        _ = beginProgress(label, repository: name)
        let url = repoURL(name)
        Task {
            let origin = await Task.detached { (try? GitClient.transportURL(at: url)) ?? "" }.value
            let ssh = sshKeyMaterial(for: origin, repoName: name)
            let lfs = lfsAuth(for: origin, repoName: name)
            do {
                try await Task.detached { try work(url, ssh, lfs) }.value
                await finish(nil, repository: name)
            } catch {
                await finish(error.localizedDescription, repository: name)
            }
        }
    }

    private func run(
        _ label: String,
        repository: String? = nil,
        publishStorage: Bool = false,
        resetLinks: Bool = false,
        focus: String? = nil,
        linkAccount: RemoteAccount? = nil,
        linkSSHKey: SSHKey? = nil,
        _ work: @escaping @Sendable () throws -> Void
    ) {
        runProgress(label, repository: repository, publishStorage: publishStorage, resetLinks: resetLinks, focus: focus, linkAccount: linkAccount, linkSSHKey: linkSSHKey) { _ in try work() }
    }

    private func runProgress(
        _ label: String,
        repository: String? = nil,
        publishStorage: Bool = false,
        resetLinks: Bool = false,
        focus: String? = nil,
        linkAccount: RemoteAccount? = nil,
        linkSSHKey: SSHKey? = nil,
        _ work: @escaping @Sendable (@escaping GitProgressHandler) throws -> Void
    ) {
        guard !isBusy else { return }
        isBusy = true
        statusLine = label
        let progress = beginProgress(label, repository: repository)
        Task.detached {
            do {
                try work(progress)
                await self.finish(nil, repository: repository, publishStorage: publishStorage, resetLinks: resetLinks, focus: focus, linkAccount: linkAccount, linkSSHKey: linkSSHKey)
            } catch {
                await self.finish(error.localizedDescription, repository: repository, publishStorage: publishStorage)
            }
        }
    }

    private func beginProgress(_ title: String, repository: String?) -> GitProgressHandler {
        progressRelay?.invalidate()
        let id = UUID()
        activeProgressID = id
        operationProgress = .init(id: id, title: title, repository: repository, startedAt: Date(), progress: .init(phase: .preparing))
        let relay = GitProgressRelay { [weak self] value in
            Task { @MainActor [weak self] in
                guard let self, self.activeProgressID == id, self.isBusy else { return }
                self.operationProgress?.progress = value
            }
        }
        progressRelay = relay
        return { value in relay.submit(value) }
    }

    private func finish(
        _ error: String?,
        repository: String? = nil,
        publishStorage: Bool = false,
        resetLinks: Bool = false,
        focus: String? = nil,
        linkAccount: RemoteAccount? = nil,
        linkSSHKey: SSHKey? = nil
    ) async {
        activeProgressID = nil
        progressRelay?.invalidate()
        progressRelay = nil
        operationProgress?.progress = .init(phase: .refreshing)
        if let error {
            alert = error
        } else {
            if resetLinks, let repository {
                removeRepoLink(repository)
                WorktreeLink.remove(repoName: repository)
                RepoDetailCache.remove(repository)
            }
            focusName = focus
            if let focus, let linkAccount {
                linkRepo(focus, to: linkAccount)
            }
            if let focus, let linkSSHKey {
                linkRepoSSHKey(focus, to: linkSSHKey)
            }
        }
        if publishStorage {
            await Task.detached { RepoStorage.publish() }.value
        }
        await reload(repository: repository)
        isBusy = false
        statusLine = ""
        operationProgress = nil
        revision += 1
        if FileProviderRegistration.usesProviderLocation {
            FileProviderRegistration.signal()
        }
    }

    private enum Keys {
        static let name = "gitling.userName"
        static let email = "gitling.userEmail"
        static let accounts = "gitling.accounts.v1"
        static let repoAccounts = "gitling.repoAccounts.v1"
        static let sshKeys = "gitling.sshKeys.v1"
        static let repoCache = "gitling.repoCache.v1"
        static let repoSSHKeys = "gitling.repoSSHKeys.v1"
    }
}
