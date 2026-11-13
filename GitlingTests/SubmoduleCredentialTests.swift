import XCTest
@testable import Gitling

final class SubmoduleCredentialTests: XCTestCase {
    private func account(_ base: String, username: String = "user") -> RemoteAccount {
        .init(id: UUID(), provider: .gitlab, baseURL: base, username: username, displayName: username, createdAt: .now)
    }
    func testEachRemoteGetsOnlyItsOwnAccountIncludingSchemePortAndInstancePath() {
        let first = account("https://one.invalid"), second = account("https://two.invalid:8443/forge")
        let router = SubmoduleCredentialRouter(accounts: [.init(account: first, secret: "first-secret"), .init(account: second, secret: "second-secret")])
        XCTAssertEqual(router.credentials(for: "https://one.invalid/repo.git").secret, "first-secret")
        XCTAssertEqual(router.credentials(for: "https://two.invalid:8443/forge/repo.git").secret, "second-secret")
        for url in ["http://one.invalid/repo.git", "https://two.invalid/forge/repo.git", "https://two.invalid:8443/other/repo.git", "https://unknown.invalid/repo.git", "file:///offline/repo.git"] {
            XCTAssertTrue(router.credentials(for: url).secret.isEmpty, url)
        }
    }
    func testExplicitAccountSelectionAndSSHAuthorityScopeDoNotReuseHTTPToken() {
        let one = account("https://one.invalid"), two = account("https://one.invalid", username: "second")
        let key = SSHKeyMaterial(privateKey: "offline test key", passphrase: nil)
        let router = SubmoduleCredentialRouter(accounts: [.init(account: one, secret: "first"), .init(account: two, secret: "second")], selectedAccounts: ["https://one.invalid:443": two.id], sshKeys: ["ssh://one.invalid:22": key])
        XCTAssertEqual(router.credentials(for: "https://one.invalid/a.git").secret, "second")
        let ssh = router.credentials(for: "git@one.invalid:a.git")
        XCTAssertTrue(ssh.secret.isEmpty)
        XCTAssertNotNil(ssh.sshKey)
        XCTAssertNil(router.credentials(for: "ssh://git@one.invalid:2222/a.git").sshKey)
        XCTAssertNil(router.credentials(for: "git@two.invalid:a.git").sshKey)
    }
    func testManualCredentialsAreScopedToOneAuthorityAndNeverSentToSSH() {
        let router = SubmoduleCredentialRouter(overrides: ["http://local.invalid:8106": .init(username: "local", secret: "offline-test")])
        XCTAssertEqual(router.credentials(for: "http://local.invalid:8106/child.git").secret, "offline-test")
        XCTAssertTrue(router.credentials(for: "https://local.invalid:8106/child.git").secret.isEmpty)
        XCTAssertTrue(router.credentials(for: "http://local.invalid:8107/child.git").secret.isEmpty)
        XCTAssertTrue(router.credentials(for: "ssh://local@local.invalid/child.git").secret.isEmpty)
    }
    func testRedirectAcrossInstancesOnSameHostDoesNotSelectAnotherAccountsToken() {
        let first = account("https://one.invalid/first"), second = account("https://one.invalid/second")
        let router = SubmoduleCredentialRouter(accounts: [.init(account: first, secret: "first"), .init(account: second, secret: "second")])
        let auth = SubmoduleAuth(resolve: { router.credentials(for: $0) })
        XCTAssertNil(auth.credentials(for: "https://one.invalid/second/a.git", expected: "https://one.invalid/first/a.git"))
        XCTAssertNotNil(auth.credentials(for: "https://one.invalid/first/a.git/info/refs", expected: "https://one.invalid/first/a.git"))
    }
    func testParentSignInIsReusedOnlyForTheSameSchemeHostAndPort() {
        let router = SubmoduleCredentialRouter(inherited: ["http://wlab.top:8106": .init(username: "chenshuo", secret: "offline-test")])
        let match = router.credentials(for: "http://wlab.top:8106/fixed_unit_queue.git")
        XCTAssertEqual(match.username, "chenshuo")
        XCTAssertEqual(match.secret, "offline-test")
        for url in ["https://wlab.top:8106/fixed_unit_queue.git", "http://wlab.top:8107/fixed_unit_queue.git", "http://other.invalid:8106/fixed_unit_queue.git", "ssh://git@wlab.top/fixed_unit_queue.git"] {
            XCTAssertTrue(router.credentials(for: url).secret.isEmpty, url)
        }
        let usernameOnly = SubmoduleCredentialRouter(inherited: ["http://wlab.top:8106": .init(username: "chenshuo", secret: "")])
        XCTAssertTrue(usernameOnly.credentials(for: "http://wlab.top:8106/fixed_unit_queue.git").secret.isEmpty)
        XCTAssertTrue(usernameOnly.credentials(for: "http://wlab.top:8106/fixed_unit_queue.git").username.isEmpty)
    }
    func testTypedPasswordWinsAndEmptyUsernameComesFromTheParentSignIn() {
        let account = self.account("http://wlab.top:8106", username: "account-user")
        let router = SubmoduleCredentialRouter(
            accounts: [.init(account: account, secret: "account-secret")],
            overrides: ["http://wlab.top:8106": .init(username: "", secret: "typed")],
            inherited: ["http://wlab.top:8106": .init(username: "chenshuo", secret: "saved")]
        )
        let typed = router.credentials(for: "http://wlab.top:8106/fixed_unit_queue.git")
        XCTAssertEqual(typed.username, "chenshuo")
        XCTAssertEqual(typed.secret, "typed")
        let automatic = SubmoduleCredentialRouter(
            accounts: [.init(account: account, secret: "account-secret")],
            inherited: ["http://wlab.top:8106": .init(username: "chenshuo", secret: "saved")]
        )
        XCTAssertEqual(automatic.credentials(for: "http://wlab.top:8106/fixed_unit_queue.git").secret, "account-secret")
    }
    func testParentOriginUserInfoMapsOntoThatAuthorityOnly() {
        let mapped = SubmoduleCredentialRouter.parentCredentials(origin: "http://chenshuo@wlab.top:8106/Js_ms_rtos.git", username: "", secret: "offline-test")
        XCTAssertEqual(mapped["http://wlab.top:8106"]?.username, "chenshuo")
        XCTAssertEqual(mapped["http://wlab.top:8106"]?.secret, "offline-test")
        XCTAssertEqual(mapped.count, 1)
        let embedded = SubmoduleCredentialRouter.parentCredentials(origin: "http://chenshuo:offline-test@wlab.top:8106/Js_ms_rtos.git", username: "", secret: "")
        XCTAssertEqual(embedded["http://wlab.top:8106"]?.username, "chenshuo")
        XCTAssertEqual(embedded["http://wlab.top:8106"]?.secret, "offline-test")
        XCTAssertTrue(SubmoduleCredentialRouter.parentCredentials(origin: "git@wlab.top:Js_ms_rtos.git", username: "", secret: "offline-test").isEmpty)
    }
    func testInheritedPasswordsArePreservedByteForByte() {
        for password in [" leading and trailing ", "\tpassword\n", " "] {
            let mapped = SubmoduleCredentialRouter.parentCredentials(origin: "http://user@local.invalid:8106/parent.git", username: "", secret: password)
            XCTAssertEqual(mapped["http://local.invalid:8106"]?.secret, password)
        }
    }
    func testPasswordOverrideCanUseSelectedAccountUsernameWithoutParentSignIn() {
        let account = self.account("http://local.invalid:8106", username: "account-user")
        let router = SubmoduleCredentialRouter(accounts: [.init(account: account, secret: "saved")],
                                               overrides: ["http://local.invalid:8106": .init(secret: "typed")])
        let credentials = router.credentials(for: "http://local.invalid:8106/child.git")
        XCTAssertEqual(credentials.username, "oauth2")
        XCTAssertEqual(credentials.secret, "typed")
    }
    func testExplicitAccountOutsideInstanceDoesNotFallBackToParentPassword() {
        let account = self.account("http://local.invalid:8106/first")
        let router = SubmoduleCredentialRouter(accounts: [.init(account: account, secret: "account-password")],
                                               selectedAccounts: ["http://local.invalid:8106": account.id],
                                               inherited: ["http://local.invalid:8106": .init(username: "parent-user", secret: "parent-password")])
        let credentials = router.credentials(for: "http://local.invalid:8106/second/child.git")
        XCTAssertTrue(credentials.username.isEmpty)
        XCTAssertTrue(credentials.secret.isEmpty)
    }
    @MainActor
    func testStoreDoesNotExpandProviderAccountScopeWhenInheritingCredentials() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let name = "scope-" + UUID().uuidString
        try GitClient.initialize(name: name, root: root)
        let host = UUID().uuidString.lowercased() + ".invalid"
        let base = "http://\(host):8106/first"
        try GitClient.addRemote(at: root.appendingPathComponent(name), url: base + "/parent.git")
        let store = RepoStore(root: root, reloadOnStart: false)
        let account = try XCTUnwrap(store.addAccount(provider: .gitlab, baseURL: base, username: "fixture-user", token: "scoped-token"))
        defer { store.removeRepoLink(name); store.removeAccount(account) }
        store.linkRepo(name, to: account)
        let auth = store.submoduleAuth(name: name)
        XCTAssertEqual(auth.resolve(base + "/child.git").secret, "scoped-token")
        XCTAssertTrue(auth.resolve("http://\(host):8106/second/child.git").secret.isEmpty)
        XCTAssertNil(auth.credentials(for: "http://\(host):8106/second/child.git", expected: base + "/child.git"))
    }

    @MainActor
    func testStoreSnapshotsLegacyParentSignInWithoutChangingItsPasswordOrOtherOrigins() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let name = "legacy-" + UUID().uuidString, host = UUID().uuidString.lowercased() + ".invalid"
        try GitClient.initialize(name: name, root: root)
        try GitClient.addRemote(at: root.appendingPathComponent(name), url: "http://\(host):8106/parent.git")
        KeychainStore.save(host: host, username: "fixture-user", secret: " exact password ")
        defer { KeychainStore.delete(host: host) }
        let store = RepoStore(root: root, reloadOnStart: false), auth = store.submoduleAuth(name: name)
        XCTAssertEqual(auth.resolve("http://\(host):8106/child.git").username, "fixture-user")
        XCTAssertEqual(auth.resolve("http://\(host):8106/child.git").secret, " exact password ")
        for url in ["http://\(host):8107/child.git", "https://\(host):8106/child.git", "http://other.invalid:8106/child.git"] {
            XCTAssertTrue(auth.resolve(url).secret.isEmpty)
        }
    }
    func testCallbackRejectsCrossHostPortAndDowngradeRedirects() {
        let auth = SubmoduleAuth(resolve: { _ in .init(username: "user", secret: "secret") })
        XCTAssertNotNil(auth.credentials(for: "https://one.invalid/path.git", expected: "https://one.invalid:443/path.git"))
        for actual in ["http://one.invalid/path.git", "https://two.invalid/path.git", "https://one.invalid:8443/path.git", "file:///tmp/repo"] {
            XCTAssertNil(auth.credentials(for: actual, expected: "https://one.invalid/path.git"))
        }
    }
}
