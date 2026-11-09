import XCTest
@testable import Gitling

final class TransportTests: XCTestCase {
    func testSSHURLForms() {
        XCTAssertTrue(SSHURL.isSSH("ssh://git@example.com:2222/group/repo.git"))
        XCTAssertTrue(SSHURL.isSSH("git@github.com:kozakemi/gitling-ios.git"))
        XCTAssertFalse(SSHURL.isSSH("https://github.com/kozakemi/gitling-ios.git"))
        XCTAssertFalse(SSHURL.isSSH(""))
        XCTAssertEqual(SSHURL.host("git@github.com:kozakemi/gitling-ios.git"), "github.com")
    }

    func testLFSPointerParsing() throws {
        let text = """
        version https://git-lfs.github.com/spec/v1
        oid sha256:4a003717d1e1997c56ef4128f54eb92c72831e44cda4e3d49e93a32ae0cc9222
        size 12259
        """
        let pointer = try XCTUnwrap(LFSPointer.parse(text))
        XCTAssertEqual(pointer.oid, "4a003717d1e1997c56ef4128f54eb92c72831e44cda4e3d49e93a32ae0cc9222")
        XCTAssertEqual(pointer.size, 12259)
        XCTAssertNil(LFSPointer.parse("not an LFS pointer"))
    }

    func testLFSEndpointFromHTTPS() throws {
        let endpoint = try LFSClient.endpoint(
            remoteURL: "https://github.com/kozakemi/gitling-ios.git",
            instanceBaseURL: nil
        )
        XCTAssertEqual(endpoint.absoluteString, "https://github.com/kozakemi/gitling-ios.git/info/lfs")
    }

    func testLFSEndpointFromSCPLikeSSH() throws {
        let endpoint = try LFSClient.endpoint(
            remoteURL: "git@github.com:kozakemi/gitling-ios.git",
            instanceBaseURL: URL(string: "https://github.com")
        )
        XCTAssertEqual(endpoint.absoluteString, "https://github.com/kozakemi/gitling-ios.git/info/lfs")
    }
}
