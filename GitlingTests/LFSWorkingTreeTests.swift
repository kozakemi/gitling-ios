import CryptoKit
import XCTest
@testable import Gitling

final class LFSWorkingTreeTests: XCTestCase {
    private func folders() throws -> (URL, URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let work = root.appendingPathComponent("external")
        let git = root.appendingPathComponent("internal/.git")
        for folder in [work, git] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (root, work, git)
    }

    func testDownloadWritesExternalWorktreeAndInternalManifest() throws {
        let (_, work, git) = try folders()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LFSDownloadStub.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let pointer = LFSPointer.make(oid: LFSDownloadStub.oid, size: LFSDownloadStub.bytes.count)
        try pointer.raw.write(to: work.appendingPathComponent("asset.bin"), atomically: true, encoding: .utf8)
        try LFSClient.smudge(at: work, gitDirectory: git, remoteURL: "https://lfs-test.invalid/repo.git", auth: nil, session: session)
        XCTAssertEqual(try Data(contentsOf: work.appendingPathComponent("asset.bin")), LFSDownloadStub.bytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: git.appendingPathComponent("lfs-pointers.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: work.appendingPathComponent(".git").path))
        XCTAssertEqual(LFSClient.cleanPaths(at: work, gitDirectory: git), ["asset.bin"])
        // An unchanged downloaded object must not be uploaded again during clean.
        let pointers = try LFSClient.clean(at: work, gitDirectory: git, remoteURL: "https://example.invalid/repo.git", auth: nil)
        XCTAssertEqual(pointers["asset.bin"]?.oid, pointer.oid)
    }

    func testGlobstarMatchesRootAndNestedFiles() throws {
        let (_, work, git) = try folders()
        try "assets/**/*.bin filter=lfs\n".write(to: work.appendingPathComponent(".gitattributes"), atomically: true, encoding: .utf8)
        let pointer = LFSPointer.make(oid: String(repeating: "a", count: 64), size: 1)
        for path in ["assets/root.bin", "assets/deep/nested.bin", "other.bin"] {
            let url = work.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try pointer.raw.write(to: url, atomically: true, encoding: .utf8)
        }
        let pointers = try LFSClient.clean(at: work, gitDirectory: git, remoteURL: "https://example.invalid/repo.git", auth: nil)
        XCTAssertEqual(Set(pointers.keys), ["assets/root.bin", "assets/deep/nested.bin"])
    }

    func testStagingLinkedRepositoryUsesExternalAttributes() throws {
        let (root, _, _) = try folders()
        let name = "lfs-" + UUID().uuidString
        defer { WorktreeLink.remove(repoName: name) }
        try GitClient.initialize(name: name, root: root)
        let repo = root.appendingPathComponent(name)
        try GitClient.addRemote(at: repo, url: "https://example.invalid/repo.git")
        let folder = root.appendingPathComponent("vault")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try GitClient.link(at: repo, bookmark: WorktreeLink.bookmark(for: folder))
        let work = folder.appendingPathComponent(name)
        try "*.bin filter=lfs\n".write(to: work.appendingPathComponent(".gitattributes"), atomically: true, encoding: .utf8)
        let pointer = LFSPointer.make(oid: String(repeating: "a", count: 64), size: 1)
        try pointer.raw.write(to: work.appendingPathComponent("asset.bin"), atomically: true, encoding: .utf8)
        try GitClient.stageAll(at: repo)
        let manifest = repo.appendingPathComponent(".git/lfs-pointers.json")
        let stored = try JSONDecoder().decode([String: LFSPointer].self, from: Data(contentsOf: manifest))
        XCTAssertEqual(stored["asset.bin"], pointer)
        XCTAssertFalse(FileManager.default.fileExists(atPath: work.appendingPathComponent(".git").path))
        try GitClient.commit(at: repo, message: "LFS", name: "Test", email: "test@example.com")
        XCTAssertTrue(try GitClient.status(at: repo).isEmpty)
    }
}

private final class LFSDownloadStub: URLProtocol {
    static let bytes = Data("downloaded LFS content\n".utf8)
    static let oid = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "lfs-test.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        let payload: Data
        if url.path.hasSuffix("objects/batch") {
            payload = try! JSONSerialization.data(withJSONObject: ["objects": [[
                "oid": Self.oid, "size": Self.bytes.count,
                "actions": ["download": ["href": "https://lfs-test.invalid/object"]]
            ]]])
        } else {
            payload = Self.bytes
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: payload)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
