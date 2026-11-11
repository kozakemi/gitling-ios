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
    func testCallbackRejectsCrossHostPortAndDowngradeRedirects() {
        let auth = SubmoduleAuth(resolve: { _ in .init(username: "user", secret: "secret") })
        XCTAssertNotNil(auth.credentials(for: "https://one.invalid/path.git", expected: "https://one.invalid:443/path.git"))
        for actual in ["http://one.invalid/path.git", "https://two.invalid/path.git", "https://one.invalid:8443/path.git", "file:///tmp/repo"] {
            XCTAssertNil(auth.credentials(for: actual, expected: "https://one.invalid/path.git"))
        }
    }
}
