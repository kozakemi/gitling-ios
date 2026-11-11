import CryptoKit
import XCTest
@testable import Gitling

final class LFSContentCacheTests: XCTestCase {
    func testUnchangedFileIsHashedOnceAndSameSizeEditInvalidatesCache() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("asset.bin")
        let original = Data("original".utf8)
        let modified = Data("modified".utf8)
        func oid(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
        try original.write(to: url)
        let modifiedAt = try XCTUnwrap(url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        let pointer = LFSPointer.make(oid: oid(original), size: original.count)
        var hashes = 0
        let cache = LFSContentCache { file in
            hashes += 1
            return oid(try Data(contentsOf: file))
        }
        XCTAssertTrue(cache.matches(url, pointer: pointer))
        XCTAssertTrue(cache.matches(url, pointer: pointer))
        XCTAssertEqual(hashes, 1)
        try modified.write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: url.path)
        XCTAssertFalse(cache.matches(url, pointer: pointer))
        XCTAssertEqual(hashes, 2)
        XCTAssertFalse(cache.matches(url, pointer: pointer))
        XCTAssertEqual(hashes, 2)
        // A different branch can associate a different pointer with the same path.
        XCTAssertTrue(cache.matches(url, pointer: LFSPointer.make(oid: oid(modified), size: modified.count)))
        XCTAssertEqual(hashes, 3)
        try FileManager.default.removeItem(at: url)
        XCTAssertFalse(cache.matches(url, pointer: pointer))
    }

    func testSymbolicLinkIsNotTreatedAsUnchangedLFSContent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target")
        let link = root.appendingPathComponent("link")
        try Data("x".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let cache = LFSContentCache { _ in XCTFail("Symlinks must not be hashed"); return "" }
        XCTAssertFalse(cache.matches(link, pointer: LFSPointer.make(oid: String(repeating: "a", count: 64), size: 1)))
    }
}
