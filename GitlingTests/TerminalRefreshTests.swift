import Foundation
import XCTest
@testable import Gitling

@MainActor final class TerminalRefreshTests: XCTestCase {
    func testShellCompletionInvalidatesPageRevisionAndCachedHeaderThenRefreshesSummary() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let name = "terminal-refresh-" + UUID().uuidString
        defer { RepoDetailCache.remove(name) }
        try GitClient.initialize(name: name, root: root)
        let repo = root.appendingPathComponent(name)
        try Data("created in shell".utf8).write(to: repo.appendingPathComponent("new.txt"))
        let store = RepoStore(root: root, reloadOnStart: false)
        var stale = RepoDetailSnapshot(); stale.branch = "stale"
        RepoDetailCache.save(stale, for: name)
        let before = store.revision
        await store.refreshAfterTerminal(repository: name)
        XCTAssertEqual(store.revision, before + 1, "FileBrowser's persistent page must reload")
        XCTAssertNil(RepoDetailCache.load(name))
        XCTAssertTrue(try XCTUnwrap(store.repos.first { $0.name == name }).isDirty)
    }
}
