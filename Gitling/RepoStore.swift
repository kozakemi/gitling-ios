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
    @Published var githubLogin: String?
    @Published var githubPrompt: GitHubPrompt?
    @Published var githubMessage: String?
    @Published var githubRepos: [GitHubRepo] = []
    @Published var githubReposMessage: String?
    @Published var isLoadingGitHubRepos = false
    @Published var focusName: String?
    private var githubTask: Task<Void, Never>?
    private var githubGeneration = 0
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
        githubLogin = KeychainStore.load(host: GitHubAuth.host)?.username
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

    func clone(url: String, name: String, username: String, secret: String, worktreeBookmark: Data? = nil) {
        let root = root
        let url = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard url.lowercased().hasPrefix("https://") else {
            alert = String(localized: "The demo only clones HTTPS repositories.")
            return
        }
        let creds = account(for: url, username: username, secret: secret)
        run(String(localized: "Cloning…"), focus: name) {
            try GitClient.clone(
                url: url,
                name: name,
                root: root,
                username: creds.username,
                secret: creds.secret,
                worktreeBookmark: worktreeBookmark
            )
            if let host = GitClient.host(of: url), !creds.secret.isEmpty {
                KeychainStore.save(host: host, username: creds.username, secret: creds.secret)
            }
        }
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
                KeychainStore.save(host: GitHubAuth.host, username: login, secret: token)
                githubLogin = login
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

    func signOutGitHub() {
        cancelGitHub()
        KeychainStore.delete(host: GitHubAuth.host)
        githubLogin = nil
        githubMessage = nil
        revision += 1
    }

    func loadGitHubRepos() {
        guard let token = KeychainStore.load(host: GitHubAuth.host)?.secret, !token.isEmpty else {
            githubRepos = []
            isLoadingGitHubRepos = false
            githubReposMessage = String(localized: "Connect with GitHub in Settings to choose a repository.")
            return
        }
        guard !isLoadingGitHubRepos else { return }
        isLoadingGitHubRepos = true
        githubReposMessage = nil
        Task {
            do {
                let repos = try await GitHubAuth.fetchRepos(token: token)
                githubRepos = repos
                if repos.isEmpty {
                    githubReposMessage = String(localized: "This GitHub account has no repositories.")
                }
            } catch {
                githubRepos = []
                githubReposMessage = error.localizedDescription
            }
            isLoadingGitHubRepos = false
        }
    }

    func account(for urlString: String, username: String, secret: String) -> (username: String, secret: String) {
        let saved = GitClient.host(of: urlString).flatMap { KeychainStore.load(host: $0) }
        return RemoteCredentials.resolve(username: username, secret: secret, saved: saved)
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
        run(String(localized: "Working…")) { try GitClient.stageAll(at: url) }
    }

    func unstageAll(name: String) {
        let url = repoURL(name)
        run(String(localized: "Working…")) { try GitClient.unstageAll(at: url) }
    }

    func commit(name: String, message: String) {
        let url = repoURL(name)
        let userName = userName
        let userEmail = userEmail
        run(String(localized: "Committing…")) {
            try GitClient.commit(at: url, message: message, name: userName, email: userEmail)
        }
    }

    func pull(name: String, username: String, secret: String) {
        let url = repoURL(name)
        let userName = userName
        let userEmail = userEmail
        run(String(localized: "Pulling…")) {
            try GitClient.pull(at: url, username: username, secret: secret, name: userName, email: userEmail)
        }
    }

    func fetch(name: String, username: String, secret: String) {
        let url = repoURL(name)
        run(String(localized: "Fetching…")) {
            try GitClient.fetch(at: url, username: username, secret: secret)
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
        run(String(localized: "Pushing…")) {
            try GitClient.push(at: url, username: username, secret: secret)
        }
    }

    func repoURL(_ name: String) -> URL {
        root.appendingPathComponent(name, isDirectory: true)
    }

    private func run(_ label: String, focus: String? = nil, _ work: @escaping @Sendable () throws -> Void) {
        guard !isBusy else { return }
        isBusy = true
        statusLine = label
        Task.detached {
            do {
                try work()
                await self.finish(nil, focus: focus)
            } catch {
                await self.finish(error.localizedDescription)
            }
        }
    }

    private func finish(_ error: String?, focus: String? = nil) async {
        isBusy = false
        statusLine = ""
        if let error {
            alert = error
        } else {
            focusName = focus
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
    }
}
