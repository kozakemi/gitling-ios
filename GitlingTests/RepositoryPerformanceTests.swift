import CryptoKit
import XCTest
@testable import Gitling

final class RepositoryPerformanceTests: XCTestCase {
    func testLargeWorktreeRefreshTimings() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try GitClient.initialize(name: "benchmark", root: root)
        let repo = root.appendingPathComponent("benchmark")
        let content = String(repeating: "file contents\n", count: 80)
        for i in 0..<2000 {
            try content.write(to: repo.appendingPathComponent("file-\(i).txt"), atomically: true, encoding: .utf8)
        }
        try GitClient.stageAll(at: repo)
        try GitClient.commit(at: repo, message: "base", name: "Test", email: "test@example.com")
        try GitClient.createBranch(at: repo, name: "feature", checkout: true)
        try "feature\n".write(to: repo.appendingPathComponent("file-0.txt"), atomically: true, encoding: .utf8)
        try GitClient.stageAll(at: repo)
        try GitClient.commit(at: repo, message: "feature", name: "Test", email: "test@example.com")
        var refresh: [Double] = []
        var checkout: [Double] = []
        for _ in 0..<5 {
            var start = Date()
            try GitClient.checkout(at: repo, branch: "master")
            checkout.append(Date().timeIntervalSince(start))
            start = Date()
            let header = try GitClient.header(at: repo)
            XCTAssertEqual(header.branch, "master")
            XCTAssertTrue(try GitClient.status(at: repo).isEmpty)
            _ = GitClient.syncCounts(at: repo)
            refresh.append(Date().timeIntervalSince(start))
            try GitClient.checkout(at: repo, branch: "feature")
        }
        func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] * 1000 }
        print("PERF 2000 tracked files: checkout median=\(median(checkout))ms; detail+status median=\(median(refresh))ms")
        var single: [Double] = []
        for i in 0..<5 {
            try "selected \(i)\n".write(to: repo.appendingPathComponent("file-1.txt"), atomically: true, encoding: .utf8)
            let start = Date()
            try GitClient.stage(at: repo, path: "file-1.txt")
            XCTAssertTrue(try GitClient.diff(at: repo, scope: .staged, path: "file-1.txt").contains("+selected \(i)"))
            single.append(Date().timeIntervalSince(start))
            try GitClient.unstage(at: repo, path: "file-1.txt")
        }
        print("PERF 2000 tracked files: single-file stage+diff median=\(median(single))ms")

    }

    func testRepeatedLFSVerificationTimings() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let git = root.appendingPathComponent(".git")
        try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let data = Data(repeating: 42, count: 32 * 1024 * 1024)
        let oid = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let pointer = LFSPointer.make(oid: oid, size: data.count)
        try data.write(to: root.appendingPathComponent("asset.bin"))
        try JSONEncoder().encode(["asset.bin": pointer]).write(to: git.appendingPathComponent("lfs-pointers.json"))
        var start = Date()
        XCTAssertEqual(LFSClient.cleanPaths(at: root), ["asset.bin"])
        let cold = Date().timeIntervalSince(start) * 1000
        var warm: [Double] = []
        for _ in 0..<5 {
            start = Date()
            XCTAssertEqual(LFSClient.cleanPaths(at: root), ["asset.bin"])
            warm.append(Date().timeIntervalSince(start) * 1000)
        }
        print("PERF LFS 32 MiB: first verification=\(cold)ms; repeated median=\(warm.sorted()[2])ms")
    }

}
