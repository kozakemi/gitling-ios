import XCTest
@testable import Gitling

@MainActor
final class TagStoreTests: XCTestCase {
    func testCheckoutReportsFailureToDetailWithoutDismissingWithGlobalAlertThenCanSucceed() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let name = "tag-report-" + UUID().uuidString
        try GitClient.initialize(name: name, root: root)
        let repo = root.appendingPathComponent(name), file = repo.appendingPathComponent("a.txt")
        defer { try? FileManager.default.removeItem(at: root); RepoDetailCache.remove(name) }
        try "base\n".write(to: file, atomically: true, encoding: .utf8)
        try GitClient.stageAll(at: repo)
        try GitClient.commit(at: repo, message: "base", name: "Test", email: "test@example.invalid")
        let oid = try GitClient.history(at: repo)[0].id
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git/refs/tags"), withIntermediateDirectories: true)
        try (oid + "\n").write(to: repo.appendingPathComponent(".git/refs/tags/v1"), atomically: true, encoding: .utf8)
        let detail = try GitClient.tagDetail(at: repo, name: "v1")
        let store = RepoStore(root: root, reloadOnStart: false)
        try "keep local\n".write(to: file, atomically: true, encoding: .utf8)
        let failure: String? = await withCheckedContinuation { continuation in
            store.checkoutTag(name: name, detail: detail) { continuation.resume(returning: $0) }
        }
        XCTAssertNotNil(failure)
        XCTAssertNil(store.alert)
        XCTAssertFalse(store.isBusy)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "keep local\n")
        XCTAssertNil(try GitClient.header(at: repo).detachedOID)
        try "base\n".write(to: file, atomically: true, encoding: .utf8)
        let success: String? = await withCheckedContinuation { continuation in
            store.checkoutTag(name: name, detail: detail) { continuation.resume(returning: $0) }
        }
        XCTAssertNil(success)
        XCTAssertFalse(store.isBusy)
        XCTAssertNil(store.alert)
        XCTAssertEqual(try GitClient.header(at: repo).detachedOID, oid)
    }
}
