import CryptoKit
import Foundation
import XCTest
@testable import Gitling

final class LFSProgressTests: XCTestCase {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lfs-progress-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testRealHTTPCloneReportsPartialLFSBytesAndDoesNotLockOtherRepositories() async throws {
        let root = try root(), suffix = UUID().uuidString
        let sourceName = "lfs-source-" + suffix, otherName = "lfs-other-" + suffix, cloneName = "lfs-clone-" + suffix
        let source = root.appendingPathComponent(sourceName), other = root.appendingPathComponent(otherName)
        try GitClient.initialize(name: sourceName, root: root); try GitClient.initialize(name: otherName, root: root)
        let bytes = Data((0..<524288).map { UInt8($0 % 251) })
        let pointer = LFSPointer.make(oid: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(), size: bytes.count)
        try "*.bin filter=lfs\n".write(to: source.appendingPathComponent(".gitattributes"), atomically: true, encoding: .utf8)
        for file in ["first.bin", "duplicate.bin"] { try pointer.raw.write(to: source.appendingPathComponent(file), atomically: true, encoding: .utf8) }
        try GitClient.stageAll(at: source); try GitClient.commit(at: source, message: "LFS", name: "Fixture", email: "fixture@example.invalid")
        let server = try SubmoduleHTTPServer(); defer { server.stop() }
        server.serve(try .init(at: source, username: "fixture", password: "offline"))
        server.serveLFS(bytes)
        let progress = LFSProgressRecorder(), firstByte = expectation(description: "First streamed LFS byte"), gate = DispatchSemaphore(value: 0)
        let worker = Task.detached {
            try GitClient.clone(url: server.authority + "/fixed_unit_queue.git", name: cloneName, root: root,
                                username: "fixture", secret: "offline", lfsAuth: .init(username: "fixture", secret: "offline"), progress: { value in
                let first = progress.record(value)
                if first { firstByte.fulfill(); gate.wait() }
            })
        }
        await fulfillment(of: [firstByte], timeout: 5)
        let independent = expectation(description: "Other Git calls while LFS waits")
        let read = Task.detached {
            _ = try GitClient.status(at: other)
            _ = try GitClient.header(at: other)
            independent.fulfill()
        }
        await fulfillment(of: [independent], timeout: 2)
        gate.signal()
        try await read.value; try await worker.value
        let values = progress.values.filter { $0.phase == .largeFiles }
        XCTAssertTrue(values.contains { $0.bytes > 0 && $0.bytes < bytes.count && $0.completed == 0 && ($0.fraction ?? 0) > 0 })
        XCTAssertEqual(values.last?.byteTotal, bytes.count)
        XCTAssertEqual(values.last?.bytes, bytes.count)
        XCTAssertEqual(values.last?.completed, 1) // Duplicate paths download only one object.
        XCTAssertEqual(values.last?.fraction, 1)
        XCTAssertEqual(values.map(\.bytes), values.map(\.bytes).sorted())
        for file in ["first.bin", "duplicate.bin"] { XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(cloneName + "/" + file)), bytes) }
        XCTAssertTrue(try GitClient.status(at: root.appendingPathComponent(cloneName)).isEmpty)
        XCTAssertTrue(progress.values.contains { $0.phase == .checkingOut && $0.completed == 2 && $0.total == 2 })
    }

    func testInvalidAndMissingObjectsNeverReplacePointersOrClaimCompletion() throws {
        for mode in ["checksum", "missing", "oversize", "unauthorized"] {
            let work = try root(), pointer = LFSProgressStub.pointer
            let file = work.appendingPathComponent("file.bin")
            try pointer.raw.write(to: file, atomically: true, encoding: .utf8)
            let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [LFSProgressStub.self]
            let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
            let recorder = LFSProgressRecorder()
            XCTAssertThrowsError(try LFSClient.smudge(at: work, remoteURL: "https://" + mode + ".invalid/repo.git", auth: nil,
                                                   session: session, progress: .init(handler: { _ = recorder.record($0) })))
            XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), pointer.raw)
            XCTAssertFalse(recorder.values.contains { $0.phase == .largeFiles && $0.completed == 1 })
            XCTAssertTrue(recorder.values.allSatisfy { $0.bytes <= pointer.size })
        }
    }

    func testLFSFractionUsesBytesAndRetainsScopedCounts() {
        let progress = GitProgress(phase: .largeFiles, completed: 0, total: 2, bytes: 50, byteTotal: 200, submodule: "module")
        XCTAssertEqual(progress.fraction, 0.25)
        XCTAssertEqual(GitProgress(phase: .largeFiles, completed: 1, total: 1, byteTotal: 0).fraction, 1)
        XCTAssertNotNil(progress.countText())
        let scoped = LFSProgressRecorder()
        GitProgressReporter(handler: { _ = scoped.record($0) }).scoped(to: "child").report(.largeFiles, bytes: 10, byteTotal: 20)
        XCTAssertEqual(scoped.values.first?.submodule, "child"); XCTAssertEqual(scoped.values.first?.fraction, 0.5)
    }
}

private final class LFSProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [GitProgress] = []
    private var streamed = false
    var values: [GitProgress] { lock.withLock { snapshots } }
    @discardableResult func record(_ value: GitProgress) -> Bool {
        lock.withLock {
            snapshots.append(value)
            if value.phase == .largeFiles, value.bytes > 0, !streamed { streamed = true; return true }
            return false
        }
    }
}

private final class LFSProgressStub: URLProtocol {
    static let pointer = LFSPointer.make(oid: SHA256.hash(data: Data("valid".utf8)).map { String(format: "%02x", $0) }.joined(), size: 5)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let mode = request.url!.host!.split(separator: ".")[0]
        let status = mode == "unauthorized" ? 401 : 200
        let bytes: Data
        if request.url!.path.hasSuffix("objects/batch") {
            bytes = try! JSONSerialization.data(withJSONObject: ["objects": mode == "missing" ? [] : [["oid": Self.pointer.oid, "size": 5,
                "actions": ["download": ["href": "https://\(mode).invalid/object"]]]]])
        } else { bytes = Data((mode == "oversize" ? "too long" : "wrong").utf8) }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: bytes); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
