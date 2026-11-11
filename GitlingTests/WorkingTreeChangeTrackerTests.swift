import XCTest
@testable import Gitling

final class WorkingTreeChangeTrackerTests: XCTestCase {
    private func node(_ path: String) -> WorkingTree.Node {
        let repo = URL(fileURLWithPath: "/repositories/test")
        return WorkingTree.Node(repoName: "test", repoURL: repo, fileURL: repo.appendingPathComponent(path), relative: path,
                                isRepoRoot: false, isDirectory: false, fileSize: 1, modified: Date(timeIntervalSince1970: 1))
    }

    func testDeletionUsesOriginalAnchorEvenAfterAnotherEnumeration() throws {
        let tracker = WorkingTreeChangeTracker()
        let anchor = tracker.record(container: "repo:test", nodes: [node("a"), node("b")])
        _ = tracker.record(container: "repo:test", nodes: [node("b")])
        let changes = try tracker.changes(container: "repo:test", nodes: [node("b")], from: anchor)
        XCTAssertEqual(changes.removed, ["repo:test/a"])
        XCTAssertTrue(changes.hasChanges)
        XCTAssertFalse(try tracker.changes(container: "repo:test", nodes: [node("b")], from: changes.anchor).hasChanges)
    }

    func testRestartExpiresOldAnchorEvenIfDirectoryWasEnumeratedAgain() {
        let old = WorkingTreeChangeTracker().record(container: "repo:test", nodes: [node("a")])
        let restarted = WorkingTreeChangeTracker()
        _ = restarted.record(container: "repo:test", nodes: [])
        XCTAssertThrowsError(try restarted.changes(container: "repo:test", nodes: [], from: old))
    }

    func testEvictedAndWrongContainerAnchorsExpire() {
        let tracker = WorkingTreeChangeTracker(capacity: 1)
        let anchor = tracker.record(container: "repo:test", nodes: [node("a")])
        XCTAssertThrowsError(try tracker.changes(container: "other", nodes: [], from: anchor))
        _ = tracker.record(container: "repo:test", nodes: [])
        XCTAssertThrowsError(try tracker.changes(container: "repo:test", nodes: [], from: anchor))
    }
}
