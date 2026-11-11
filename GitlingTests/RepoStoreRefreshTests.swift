import XCTest
@testable import Gitling

final class RepoStoreRefreshTests: XCTestCase {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        for name in ["first", "second"] {
            try GitClient.initialize(name: name, root: root)
            let url = root.appendingPathComponent(name)
            try "base\n".write(to: url.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
            try GitClient.stageAll(at: url)
            try GitClient.commit(at: url, message: "base", name: "Test", email: "test@example.com")
        }
        return root
    }

    @MainActor
    func testTargetedReloadLeavesUnrelatedRepositoryForExplicitFullRefresh() async throws {
        let root = try root()
        let store = RepoStore(root: root, reloadOnStart: false)
        await store.reload()
        try "changed\n".write(to: root.appendingPathComponent("second/a.txt"), atomically: true, encoding: .utf8)
        await store.reload(repository: "first")
        XCTAssertFalse(try XCTUnwrap(store.repos.first { $0.name == "second" }).isDirty)
        await store.reload()
        XCTAssertTrue(try XCTUnwrap(store.repos.first { $0.name == "second" }).isDirty)
        try FileManager.default.removeItem(at: root.appendingPathComponent("first"))
        await store.reload(repository: "first")
        XCTAssertEqual(store.repos.map(\.name), ["second"])
    }

    @MainActor
    func testCheckoutUpdatesOnlyAffectedRepositoryBeforePublishingRevision() async throws {
        let root = try root()
        let first = root.appendingPathComponent("first")
        try GitClient.createBranch(at: first, name: "feature", checkout: false)
        let store = RepoStore(root: root, reloadOnStart: false)
        await store.reload()
        try "changed\n".write(to: root.appendingPathComponent("second/a.txt"), atomically: true, encoding: .utf8)
        let revision = store.revision
        store.checkout(name: "first", branch: "feature")
        XCTAssertTrue(store.isBusy)
        for _ in 0..<500 where store.isBusy { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(store.isBusy)
        XCTAssertNil(store.alert)
        XCTAssertEqual(store.revision, revision + 1)
        XCTAssertEqual(store.repos.first { $0.name == "first" }?.branch, "feature")
        XCTAssertFalse(try XCTUnwrap(store.repos.first { $0.name == "second" }).isDirty)
        let header = try GitClient.header(at: first)
        XCTAssertEqual(header.branch, "feature")
        XCTAssertEqual(header.branches.filter(\.isCurrent).map(\.name), ["feature"])
        XCTAssertNil(header.linkedFolder)
    }
}
