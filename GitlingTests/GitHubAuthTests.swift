import XCTest
@testable import Gitling

final class GitHubAuthTests: XCTestCase {
    func testDeviceCodeUsesCompleteURLWhenPresent() {
        let json = """
        {"device_code":"device","user_code":"ABCD-1234","verification_uri":"https://github.com/login/device","verification_uri_complete":"https://github.com/login/device?user_code=ABCD-1234","expires_in":900,"interval":5}
        """.data(using: .utf8)!
        let code = GitHubAuth.decodeDeviceCode(json)
        XCTAssertEqual(code?.userCode, "ABCD-1234")
        XCTAssertEqual(code?.pageURL?.absoluteString, "https://github.com/login/device?user_code=ABCD-1234")
        XCTAssertEqual(code?.interval, 5)
    }

    func testPollStates() {
        XCTAssertEqual(GitHubAuth.decodePoll(Data(#"{"error":"authorization_pending"}"#.utf8)), .pending)
        XCTAssertEqual(GitHubAuth.decodePoll(Data(#"{"error":"slow_down"}"#.utf8)), .slowDown)
        XCTAssertEqual(GitHubAuth.decodePoll(Data(#"{"error":"access_denied"}"#.utf8)), .denied)
        XCTAssertEqual(GitHubAuth.decodePoll(Data(#"{"error":"expired_token"}"#.utf8)), .denied)
        XCTAssertEqual(GitHubAuth.decodePoll(Data(#"{"access_token":"gho_example","token_type":"bearer"}"#.utf8)), .token("gho_example"))
        XCTAssertEqual(GitHubAuth.decodePoll(Data("not-json".utf8)), .pending)
    }

    func testRepoListDecodesNameAndCloneURL() {
        let json = """
        [{"name":"Memo","full_name":"octocat/Memo","description":"notes","clone_url":"https://github.com/octocat/Memo.git","stargazers_count":3,"language":"Swift"},{"name":"","full_name":"skip","clone_url":"https://github.com/octocat/skip.git"}]
        """.data(using: .utf8)!
        let repos = GitHubAuth.decodeRepos(json)
        XCTAssertEqual(repos.count, 1)
        XCTAssertEqual(repos[0].name, "Memo")
        XCTAssertEqual(repos[0].fullName, "octocat/Memo")
        XCTAssertEqual(repos[0].cloneURL, "https://github.com/octocat/Memo.git")
        XCTAssertEqual(repos[0].stars, 3)
        XCTAssertEqual(repos[0].language, "Swift")
        XCTAssertEqual(GitHubAuth.decodeRepos(Data("not-json".utf8)), [])
    }

    func testLoginName() {
        XCTAssertEqual(GitHubAuth.decodeLogin(Data(#"{"login":"octocat"}"#.utf8)), "octocat")
    }

    func testTypedSecretOverridesSavedAccount() {
        let saved = KeychainStore.Item(username: "octocat", secret: "saved-token")
        let typed = RemoteCredentials.resolve(username: "other", secret: "typed-token", saved: saved)
        XCTAssertEqual(typed.username, "other")
        XCTAssertEqual(typed.secret, "typed-token")

        let empty = RemoteCredentials.resolve(username: "", secret: "  ", saved: saved)
        XCTAssertEqual(empty.username, "octocat")
        XCTAssertEqual(empty.secret, "saved-token")

        let missing = RemoteCredentials.resolve(username: "someone", secret: "", saved: nil)
        XCTAssertEqual(missing.username, "someone")
        XCTAssertEqual(missing.secret, "")
    }
}
