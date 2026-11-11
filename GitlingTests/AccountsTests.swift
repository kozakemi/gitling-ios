import XCTest
@testable import Gitling

final class AccountsTests: XCTestCase {
    func testCanonicalGitLabURLKeepsPortAndSubpath() throws {
        let url = try XCTUnwrap(InstanceURL.canonical("gitlab.example.com:8443/gitlab/api/v4/"))
        XCTAssertEqual(url.absoluteString, "https://gitlab.example.com:8443/gitlab")
    }

    func testCanonicalGitLabURLSupportsHTTP() {
        XCTAssertEqual(InstanceURL.canonical("http://gitlab.example.com")?.absoluteString, "http://gitlab.example.com")
    }

    func testAccountMatchesSubpathAndPortOnly() throws {
        let account = RemoteAccount(
            id: UUID(),
            provider: .gitlab,
            baseURL: "https://gitlab.example.com:8443/gitlab",
            username: "kozakemi",
            displayName: "Company GitLab",
            createdAt: .now
        )
        XCTAssertTrue(account.matches("https://gitlab.example.com:8443/gitlab/group/project.git"))
        XCTAssertFalse(account.matches("https://gitlab.example.com:8443/group/project.git"))
        XCTAssertFalse(account.matches("https://gitlab.example.com/gitlab/group/project.git"))
        XCTAssertFalse(account.matches("https://other.example.com:8443/gitlab/group/project.git"))
    }
}
