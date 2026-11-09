import Foundation

@MainActor
final class RepoStore: ObservableObject {
    let root: URL
    @Published var repos: [RepoSummary] = []
    @Published var isBusy = false
    @Published var statusLine = ""
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

    struct GitHubPrompt: Equatable {
        var userCode: String
        var url: URL
    }

    var githubBusy: Bool { githubTask != nil && githubPrompt == nil }

    init() {
        RepoStorage.migrateLegacyRepositoriesIfNeeded()
        root = RepoStorage.repositoriesRoot()
        if !RepoStorage.usesDocumentsFolder {
            FileProviderRegistration.register()
        }
        userName = UserDefaults.standard.string(forKey: Keys.name) ?? ""
        userEmail = UserDefaults.standard.string(forKey: Keys.email) ?? ""
        loadAccounts()
        loadSSHKeys()
        Task { await reload() }
    }

    func reload() async {
        reloadGeneration += 1
        let generation = reloadGeneration
        let root = root
        let repos = await Task.detached { GitClient.list(root: root) }.value
        // Pull-to-refresh can overlap with the scenePhase refresh. Only the latest
        // result may touch the list, and an unchanged list must not be reassigned:
        // doing so makes SwiftUI rebuild the rows and visibly flashes the section.
        guard generation == reloadGeneration else { return }
        if self.repos != repos {
            self.repos = repos
        }
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
           let linked = account(id: id) {
            return linked
        }
        return accounts.first { $0.matches(urlString) }
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
        let matched: RemoteAccount?
        if SSHURL.isSSH(urlString) {
            let host = SSHURL.host(urlString)
            matched = accounts.first { $0.instanceURL?.host?.lowercased() == host }
        } else {
            matched = account(for: urlString, repoName: repoName)
        }
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
        run(String(localized: "Cloning…"), focus: name, linkAccount: chosen, linkSSHKey: chosenSSHKey) {
            try GitClient.clone(
                url: url,
                name: name,
                root: root,
                username: creds.username,
                secret: creds.secret,
                sshKey: sshMaterial,
                lfsAuth: lfs,
                worktreeBookmark: worktreeBookmark
            )
            if chosen == nil, let host = GitClient.host(of: url), !secret.isEmpty {
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
        run(String(localized: "Creating…"), focus: name) {
            try GitClient.initialize(name: name, root: root, worktreeBookmark: worktreeBookmark)
        }
    }

    func delete(name: String) {
        let url = root.appendingPathComponent(name, isDirectory: true)
        removeRepoLink(name)
        run(String(localized: "Working…")) {
            try RepoWriteLock.withLock(at: url) {
                try RepoStorage.removeRepository(named: name)
                WorktreeLink.remove(repoName: name)
            }
        }
    }

    func link(name: String, bookmark: Data) {
        let url = repoURL(name)
        run(String(localized: "Working…"), focus: name) {
            try GitClient.link(at: url, bookmark: bookmark)
        }
    }

    func unlink(name: String) {
        let url = repoURL(name)
        run(String(localized: "Working…"), focus: name) {
            try GitClient.unlink(at: url)
        }
    }

    func filesLocationExplanation() async -> String {
        if RepoStorage.usesDocumentsFolder {
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
        let url = repoURL(name)
        let origin = GitClient.summary(at: url)?.origin
        let lfs = lfsAuth(for: origin ?? "", repoName: name)
        run(String(localized: "Working…")) { try GitClient.stageAll(at: url, lfsAuth: lfs) }
    }

    func unstageAll(name: String) {
        let url = repoURL(name)
        run(String(localized: "Working…")) { try GitClient.unstageAll(at: url) }
    }

    func commit(name: String, message: String) {
        let url = repoURL(name)
        let userName = userName
        let userEmail = userEmail
        let origin = GitClient.summary(at: url)?.origin
        let lfs = lfsAuth(for: origin ?? "", repoName: name)
        run(String(localized: "Committing…")) {
            try GitClient.commit(at: url, message: message, name: userName, email: userEmail, lfsAuth: lfs)
        }
    }

    func pull(name: String, username: String, secret: String) {
        let url = repoURL(name)
        let userName = userName
        let userEmail = userEmail
        let origin = GitClient.summary(at: url)?.origin
        let ssh = sshKeyMaterial(for: origin ?? "", repoName: name)
        let lfs = lfsAuth(for: origin ?? "", repoName: name)
        run(String(localized: "Pulling…")) {
            try GitClient.pull(at: url, username: username, secret: secret, sshKey: ssh, lfsAuth: lfs, name: userName, email: userEmail)
        }
    }

    func fetch(name: String, username: String, secret: String) {
        let url = repoURL(name)
        let origin = GitClient.summary(at: url)?.origin
        let ssh = sshKeyMaterial(for: origin ?? "", repoName: name)
        let lfs = lfsAuth(for: origin ?? "", repoName: name)
        run(String(localized: "Fetching…")) {
            try GitClient.fetch(at: url, username: username, secret: secret, sshKey: ssh, lfsAuth: lfs)
        }
    }

    func checkout(name: String, branch: String) {
        let url = repoURL(name)
        run(String(localized: "Working…")) {
            try GitClient.checkout(at: url, branch: branch)
        }
    }

    func createBranch(name: String, branch: String) {
        let url = repoURL(name)
        run(String(localized: "Working…")) {
            try GitClient.createBranch(at: url, name: branch, checkout: true)
        }
    }

    func merge(name: String, branch: String) {
        let url = repoURL(name)
        let userName = userName
        let userEmail = userEmail
        run(String(localized: "Working…")) {
            try GitClient.mergeBranch(at: url, branch: branch, name: userName, email: userEmail)
        }
    }

    func rebase(name: String, onto branch: String) {
        let url = repoURL(name)
        let userName = userName
        let userEmail = userEmail
        run(String(localized: "Working…")) {
            try GitClient.rebase(at: url, onto: branch, name: userName, email: userEmail)
        }
    }

    func cherryPick(name: String, commit: String) {
        let url = repoURL(name)
        let userName = userName
        let userEmail = userEmail
        run(String(localized: "Working…")) {
            try GitClient.cherryPick(at: url, commit: commit, name: userName, email: userEmail)
        }
    }

    func resetHard(name: String) {
        let url = repoURL(name)
        run(String(localized: "Working…")) {
            try GitClient.resetHard(at: url)
        }
    }

    func addRemote(name: String, remote: String, url remoteURL: String) {
        let repo = repoURL(name)
        run(String(localized: "Working…")) {
            try GitClient.addRemote(at: repo, name: remote, url: remoteURL)
        }
    }

    func removeRemote(name: String, remote: String) {
        let url = repoURL(name)
        run(String(localized: "Working…")) {
            try GitClient.removeRemote(at: url, name: remote)
        }
    }

    func createWorkItem(name: String, itemName: String, directory: Bool) {
        let url = repoURL(name)
        run(String(localized: "Working…")) {
            try GitClient.createWorkItem(at: url, name: itemName, directory: directory)
        }
    }

    func push(name: String, username: String, secret: String) {
        let url = repoURL(name)
        let origin = GitClient.summary(at: url)?.origin
        let ssh = sshKeyMaterial(for: origin ?? "", repoName: name)
        let lfs = lfsAuth(for: origin ?? "", repoName: name)
        run(String(localized: "Pushing…")) {
            try GitClient.push(at: url, username: username, secret: secret, sshKey: ssh, lfsAuth: lfs)
        }
    }

    func repoURL(_ name: String) -> URL {
        root.appendingPathComponent(name, isDirectory: true)
    }

    private func run(
        _ label: String,
        focus: String? = nil,
        linkAccount: RemoteAccount? = nil,
        linkSSHKey: SSHKey? = nil,
        _ work: @escaping @Sendable () throws -> Void
    ) {
        guard !isBusy else { return }
        isBusy = true
        statusLine = label
        Task.detached {
            do {
                try work()
                await self.finish(nil, focus: focus, linkAccount: linkAccount, linkSSHKey: linkSSHKey)
            } catch {
                await self.finish(error.localizedDescription)
            }
        }
    }

    private func finish(
        _ error: String?,
        focus: String? = nil,
        linkAccount: RemoteAccount? = nil,
        linkSSHKey: SSHKey? = nil
    ) async {
        isBusy = false
        statusLine = ""
        if let error {
            alert = error
        } else {
            focusName = focus
            if let focus, let linkAccount {
                linkRepo(focus, to: linkAccount)
            }
            if let focus, let linkSSHKey {
                linkRepoSSHKey(focus, to: linkSSHKey)
            }
        }
        revision += 1
        RepoStorage.publish()
        await reload()
        if !RepoStorage.usesDocumentsFolder {
            FileProviderRegistration.signal()
        }
    }

    private enum Keys {
        static let name = "gitling.userName"
        static let email = "gitling.userEmail"
        static let accounts = "gitling.accounts.v1"
        static let repoAccounts = "gitling.repoAccounts.v1"
        static let sshKeys = "gitling.sshKeys.v1"
        static let repoSSHKeys = "gitling.repoSSHKeys.v1"
    }
}
