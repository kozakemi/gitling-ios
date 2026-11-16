import Foundation
import XCTest
@testable import Gitling

final class RepositoryAccessGateTests: XCTestCase {
    func testNativeReadersCoexistAndExcludeGuestUntilReleased() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        var first: RepoWriteLock.Hold? = try RepositoryAccessGate.holdNative(base: base)
        var second: RepoWriteLock.Hold? = try RepositoryAccessGate.holdNative(base: base)
        XCTAssertThrowsError(try RepositoryAccessGate.holdGuest(base: base))
        first = nil
        XCTAssertThrowsError(try RepositoryAccessGate.holdGuest(base: base))
        withExtendedLifetime(second) {}
        second = nil
        let guest = try RepositoryAccessGate.holdGuest(base: base)
        XCTAssertThrowsError(try RepositoryAccessGate.holdNative(base: base))
        XCTAssertThrowsError(try RepositoryAccessGate.holdGuest(base: base))
        withExtendedLifetime(guest) {}
    }

    func testNativeGitReadsWritesAndProviderEntryRejectGuestLease() throws {
        var guest: RepoWriteLock.Hold? = try RepositoryAccessGate.holdGuest()
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertThrowsError(try GitClient.status(at: missing)) { XCTAssertEqual($0 as? WorkingTreeError, .busy) }
        XCTAssertThrowsError(try GitClient.history(at: missing)) { XCTAssertEqual($0 as? WorkingTreeError, .busy) }
        XCTAssertThrowsError(try GitClient.historySearch(at: missing, query: "initial")) { XCTAssertEqual($0 as? WorkingTreeError, .busy) }
        XCTAssertThrowsError(try GitClient.fileHistory(at: missing, path: "README.md")) { XCTAssertEqual($0 as? WorkingTreeError, .busy) }
        XCTAssertThrowsError(try GitClient.fileSearch(at: missing, query: "README")) { XCTAssertEqual($0 as? WorkingTreeError, .busy) }
        XCTAssertThrowsError(try GitClient.blame(at: missing, path: "README.md")) { XCTAssertEqual($0 as? WorkingTreeError, .busy) }
        XCTAssertThrowsError(try GitClient.stage(at: missing, path: "README.md")) { XCTAssertEqual($0 as? WorkingTreeError, .busy) }
        XCTAssertThrowsError(try ProviderWorkspace.withCurrentRoots { _, _ in () }) { XCTAssertEqual($0 as? WorkingTreeError, .busy) }
        XCTAssertThrowsError(try WorkingTree.node(root: missing, identifier: "repo:test")) { XCTAssertEqual($0 as? WorkingTreeError, .busy) }
        XCTAssertEqual(GitClient.configText(at: missing), WorkingTreeError.busy.localizedDescription)
        withExtendedLifetime(guest) {}
        guest = nil
        XCTAssertNoThrow(try RepositoryAccessGate.holdNative())
    }

    func testGuestPreventsRepositoryDeletionAndStoragePublication() throws {
        let name = "guest-storage-" + UUID().uuidString
        let live = RepoStorage.repositoriesRoot().appendingPathComponent(name)
        let backup = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("repositories").appendingPathComponent(name)
        try FileManager.default.createDirectory(at: live, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: live); try? FileManager.default.removeItem(at: backup) }
        try Data("live".utf8).write(to: live.appendingPathComponent("live.txt"))
        try Data("backup".utf8).write(to: backup.appendingPathComponent("backup.txt"))
        let guest = try RepositoryAccessGate.holdGuest()
        XCTAssertThrowsError(try RepoStorage.removeRepository(named: name)) { XCTAssertEqual($0 as? WorkingTreeError, .busy) }
        RepoStorage.publish()
        XCTAssertTrue(FileManager.default.fileExists(atPath: live.appendingPathComponent("live.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: live.appendingPathComponent("backup.txt").path))
        withExtendedLifetime(guest) {}
    }

    func testFileSearchHandleRetainsReadReservationUntilCursorClosed() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("test".utf8).write(to: root.appendingPathComponent("README.md"))
        var reader: FileNameSearchReader? = try .init(root: root, access: nil, query: "README")
        XCTAssertThrowsError(try RepositoryAccessGate.holdGuest())
        withExtendedLifetime(reader) {}
        reader = nil
        XCTAssertNoThrow(try RepositoryAccessGate.holdGuest())
    }
}
