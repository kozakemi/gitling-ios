import Foundation
import XCTest
@testable import Gitling

final class TerminalEnvironmentStoreTests: XCTestCase {
    private let version = String(repeating: "a", count: 64)
    private func fixture() throws -> (URL, URL, TerminalEnvironmentStore) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let pristine = base.appendingPathComponent("bundle/fs")
        try FileManager.default.createDirectory(at: pristine.appendingPathComponent("data/bin"), withIntermediateDirectories: true)
        try Data("shell".utf8).write(to: pristine.appendingPathComponent("data/bin/sh"))
        try Data("clean-db".utf8).write(to: pristine.appendingPathComponent("meta.db"))
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        return (base, pristine, .init(directory: base.appendingPathComponent("TerminalRuntime")))
    }
    func testResetStagesCleanFilesAndOnlyRemovesOldEnvironmentOnNextLaunch() throws {
        let (base, pristine, store) = try fixture()
        let old = try store.rootForLaunch(version: version)
        try FileManager.default.copyItem(at: pristine, to: old)
        try FileManager.default.removeItem(at: old.appendingPathComponent("data/bin/sh"))
        try Data("private settings".utf8).write(to: old.appendingPathComponent("data/profile"))
        let repository = base.appendingPathComponent("repositories/project/.git/objects")
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try Data("git-object".utf8).write(to: repository.appendingPathComponent("keep"))
        let staged = try store.prepareReset(version: version, pristine: pristine)
        XCTAssertEqual(try Data(contentsOf: staged.appendingPathComponent("data/bin/sh")), Data("shell".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.appendingPathComponent("data/profile").path), "Live kernel files cannot be deleted in-place")
        XCTAssertEqual(try store.rootForLaunch(version: version), staged)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.appendingPathComponent("data/profile").path))
        XCTAssertEqual(try Data(contentsOf: repository.appendingPathComponent("keep")), Data("git-object".utf8))
    }
    func testFailedCopyKeepsPreviousSelectionAndFiles() throws {
        let (_, pristine, store) = try fixture()
        let selected = try store.prepareReset(version: version, pristine: pristine)
        _ = try store.rootForLaunch(version: version)
        XCTAssertThrowsError(try store.prepareReset(version: version, pristine: pristine.appendingPathComponent("missing")))
        XCTAssertEqual(try store.rootForLaunch(version: version), selected)
        XCTAssertTrue(FileManager.default.fileExists(atPath: selected.appendingPathComponent("data/bin/sh").path))
    }
    func testMalformedSelectorCanBeRecoveredAndUnexpectedNamesAreKept() throws {
        let (_, pristine, store) = try fixture()
        _ = try store.rootForLaunch(version: version)
        try Data("broken".utf8).write(to: store.directory.appendingPathComponent("environment.json"))
        XCTAssertThrowsError(try store.rootForLaunch(version: version))
        let untouched = store.directory.appendingPathComponent("keep-user-data")
        try Data("keep".utf8).write(to: untouched)
        let root = try store.prepareReset(version: version, pristine: pristine)
        XCTAssertEqual(try store.rootForLaunch(version: version), root)
        XCTAssertEqual(try Data(contentsOf: untouched), Data("keep".utf8))
        XCTAssertThrowsError(try store.prepareReset(version: "../../repositories", pristine: pristine))
    }
    func testCleanupDoesNotFollowAnOldRootSymlink() throws {
        let (base, pristine, store) = try fixture()
        _ = try store.rootForLaunch(version: version)
        let outside = base.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: outside.appendingPathComponent("data"))
        try FileManager.default.createSymbolicLink(at: store.directory.appendingPathComponent(String(repeating: "b", count: 64)), withDestinationURL: outside)
        _ = try store.prepareReset(version: version, pristine: pristine)
        _ = try store.rootForLaunch(version: version)
        XCTAssertEqual(try Data(contentsOf: outside.appendingPathComponent("data")), Data("keep".utf8))
    }
}
