import CryptoKit
import XCTest
@testable import Gitling

/// Opt-in fixture: scripts/install-offline-benchmark-fixture.py installs a local
/// bare repository in the simulator. This suite never fetches from a server.
final class OfflineRepositoryPerformanceTests: XCTestCase {
    private struct Manifest: Decodable {
        struct Target: Decodable {
            var branch: String
            var commits: Int
            var changedPaths: Int
        }
        var version: Int
        var head: String
        var headOID: String
        var headCommits: Int
        var allCommits: Int
        var branchCount: Int
        var trackedFiles: Int
        var targets: [Target]
    }

    private func workingCopy() throws -> (URL, Manifest) {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OfflineBenchmarks")
        let source = directory.appendingPathComponent("fixture.git")
        guard FileManager.default.fileExists(atPath: source.appendingPathComponent("HEAD").path) else {
            throw XCTSkip("Install a local bare fixture with scripts/install-offline-benchmark-fixture.py; no network download is performed by tests.")
        }
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: directory.appendingPathComponent("manifest.json")))
        XCTAssertEqual(manifest.version, 1)
        // Fail before cloning if someone replaced the fixture with a network remote.
        XCTAssertTrue(try GitClient.remotes(at: source).isEmpty)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let name = "offline-benchmark-" + UUID().uuidString
        try GitClient.clone(url: source.absoluteString, name: name, root: root, username: "", secret: "")
        let repo = root.appendingPathComponent(name)
        XCTAssertTrue(try GitClient.remotes(at: repo).allSatisfy { URL(string: $0.url)?.isFileURL == true })
        XCTAssertEqual(try GitClient.header(at: repo).branch, manifest.head)
        XCTAssertTrue(try GitClient.status(at: repo).isEmpty)
        return (repo, manifest)
    }

    private func elapsed(_ operation: () throws -> Void) rethrows -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        try operation()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    private func record(_ name: String, _ samples: [Double]) throws {
        let sorted = samples.sorted()
        let result: [String: Any] = [
            "name": name, "count": samples.count,
            "medianMilliseconds": sorted[sorted.count / 2],
            "maxMilliseconds": sorted.last!, "samplesMilliseconds": samples,
        ]
        let encoded = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        print("OFFLINE_PERF " + String(decoding: encoded, as: UTF8.self))
    }

    func testRealRepositoryBranchSwitching() throws {
        let (repo, manifest) = try workingCopy()
        let cacheName = "offline-benchmark-" + UUID().uuidString
        defer { RepoDetailCache.remove(cacheName) }
        for target in manifest.targets {
            let prefix = "checkout.\(manifest.head)-\(target.branch).\(target.changedPaths)-paths"
            let first = try elapsed {
                try GitClient.checkoutRemote(at: repo, branch: "origin/\(target.branch)")
            }
            try record(prefix + ".first-remote-checkout", [first])
            try GitClient.checkout(at: repo, branch: manifest.head)
            var forward: [Double] = []
            var backward: [Double] = []
            for _ in 0..<7 {
                forward.append(try elapsed { try GitClient.checkout(at: repo, branch: target.branch) })
                XCTAssertEqual(try GitClient.header(at: repo).branch, target.branch)
                XCTAssertTrue(try GitClient.status(at: repo).isEmpty)
                backward.append(try elapsed { try GitClient.checkout(at: repo, branch: manifest.head) })
                XCTAssertEqual(try GitClient.header(at: repo).branch, manifest.head)
                XCTAssertTrue(try GitClient.status(at: repo).isEmpty)
            }
            try record(prefix + ".warm-forward", forward)
            try record(prefix + ".warm-backward", backward)
            var workflow: [Double] = []
            for _ in 0..<3 {
                workflow.append(try elapsed {
                    try GitClient.checkout(at: repo, branch: target.branch)
                    // Store completion refresh + history tab's data preparation.
                    _ = try XCTUnwrap(GitClient.summary(at: repo))
                    let header = try GitClient.header(at: repo)
                    let commits = try GitClient.history(at: repo, limit: 300, allBranches: true)
                    _ = CommitGraph.rows(from: commits)
                    var snapshot = RepoDetailSnapshot()
                    snapshot.branch = header.branch
                    snapshot.branches = header.branches
                    snapshot.history = commits
                    RepoDetailCache.save(snapshot, for: cacheName)
                })
                try GitClient.checkout(at: repo, branch: manifest.head)
            }
            try record(prefix + ".checkout-refresh-history-cache", workflow)
        }
    }

    func testRealRepositoryHistoryFirstPagePaginationAndGraph() throws {
        let (repo, manifest) = try workingCopy()
        var first: [CommitInfo] = []
        let initial = try elapsed { first = try GitClient.history(at: repo, limit: 300, allBranches: true) }
        try record("history.all.first-call-300", [initial])
        let full = try GitClient.history(at: repo, limit: manifest.allCommits + 1, allBranches: true)
        XCTAssertEqual(full.count, manifest.allCommits)
        XCTAssertEqual(Set(full.map(\.id)).count, full.count)
        XCTAssertEqual(first.map(\.id), Array(full.prefix(300)).map(\.id))
        let second = try GitClient.history(at: repo, limit: 300, allBranches: true, offset: 300)
        XCTAssertEqual(second.map(\.id), Array(full.dropFirst(300).prefix(300)).map(\.id))
        XCTAssertTrue(Set(first.map(\.id)).isDisjoint(with: Set(second.map(\.id))))
        XCTAssertEqual(try GitClient.history(at: repo, limit: manifest.headCommits + 1).count, manifest.headCommits)
        let cacheName = "offline-history-" + UUID().uuidString
        defer { RepoDetailCache.remove(cacheName) }
        let operations: [(String, () throws -> Void)] = [
            ("history.all.warm-first-page-300", { _ = try GitClient.history(at: repo, limit: 300, allBranches: true) }),
            ("history.all.warm-second-page-offset-300", { _ = try GitClient.history(at: repo, limit: 300, allBranches: true, offset: 300) }),
            ("history.current.warm-first-page-300", { _ = try GitClient.history(at: repo, limit: 300) }),
            ("history.all.graph-first-page", { _ = CommitGraph.rows(from: first) }),
            ("history.all.graph-after-append", { _ = CommitGraph.rows(from: first + second) }),
            ("history.all.cache-save-load-first-page", {
                var snapshot = RepoDetailSnapshot()
                snapshot.history = first
                RepoDetailCache.save(snapshot, for: cacheName)
                XCTAssertEqual(RepoDetailCache.load(cacheName)?.history.count, first.count)
            }),
        ]
        for (name, operation) in operations {
            var samples: [Double] = []
            for _ in 0..<9 { samples.append(try elapsed(operation)) }
            try record(name, samples)
        }
        if let target = manifest.targets.last {
            var samples: [Double] = []
            for _ in 0..<9 {
                samples.append(try elapsed {
                    _ = try GitClient.history(at: repo, limit: 300, allBranches: true, ref: "origin/\(target.branch)")
                })
            }
            XCTAssertEqual(try GitClient.history(at: repo, limit: target.commits + 1, ref: "origin/\(target.branch)").count, target.commits)
            try record("history.selected.warm-first-page-300", samples)
        }
    }

    private func digest(_ directory: URL) throws -> String {
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]))
        var files: [URL] = []
        for case let url as URL in enumerator { files.append(url) }
        var hash = SHA256()
        for url in files.sorted(by: { $0.path < $1.path }) {
            hash.update(data: Data(url.path.dropFirst(directory.path.count).utf8))
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true {
                hash.update(data: Data(try FileManager.default.destinationOfSymbolicLink(atPath: url.path).utf8))
            } else if values.isDirectory != true {
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
            }
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func testOfflineBareImportKeepsPackedObjectsAllBranchesAndSourceUnchanged() throws {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("OfflineBenchmarks")
        let source = directory.appendingPathComponent("fixture.git")
        guard FileManager.default.fileExists(atPath: source.appendingPathComponent("HEAD").path) else {
            throw XCTSkip("Install the existing local offline fixture; no download is performed.")
        }
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: directory.appendingPathComponent("manifest.json")))
        XCTAssertTrue(try GitClient.remotes(at: source).isEmpty)
        let sourceDigest = try digest(source)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let name = "imported-bare-" + UUID().uuidString
        let milliseconds = try elapsed { try GitClient.importRepository(from: source, name: name, root: root) }
        try record("import.real-bare-copy-validate-checkout-publish", [milliseconds])
        let imported = root.appendingPathComponent(name)
        XCTAssertEqual(try GitClient.history(at: imported, limit: manifest.allCommits + 1, allBranches: true).count, manifest.allCommits)
        XCTAssertEqual(try GitClient.branches(at: imported).count, manifest.branchCount)
        XCTAssertEqual(try GitClient.header(at: imported).branch, manifest.head)
        XCTAssertTrue(try GitClient.status(at: imported).isEmpty)
        XCTAssertEqual(try digest(imported.appendingPathComponent(".git/objects")), try digest(source.appendingPathComponent("objects")))
        XCTAssertEqual(try digest(source), sourceDigest)
        try "independent\n".write(to: imported.appendingPathComponent("gitling-import-check.txt"), atomically: true, encoding: .utf8)
        try GitClient.stage(at: imported, path: "gitling-import-check.txt")
        try GitClient.commit(at: imported, message: "independent import", name: "Test", email: "test@example.com")
        XCTAssertEqual(try digest(source), sourceDigest)
    }

    func testOfflineWorkingImportKeepsUncommittedStateAndSourceUnchanged() throws {
        let (source, manifest) = try workingCopy()
        let file = source.appendingPathComponent("gitling-import-check.txt")
        try "staged\n".write(to: file, atomically: true, encoding: .utf8)
        try GitClient.stage(at: source, path: file.lastPathComponent)
        try "unstaged\n".write(to: file, atomically: true, encoding: .utf8)
        let sourceDigest = try digest(source)
        let status = try GitClient.status(at: source)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let name = "imported-worktree-" + UUID().uuidString
        let milliseconds = try elapsed { try GitClient.importRepository(from: source, name: name, root: root) }
        try record("import.real-worktree-copy-validate-publish", [milliseconds])
        let imported = root.appendingPathComponent(name)
        XCTAssertEqual(try GitClient.history(at: imported, limit: manifest.allCommits + 1, allBranches: true).count, manifest.allCommits)
        XCTAssertEqual(try GitClient.status(at: imported), status)
        XCTAssertTrue(try GitClient.diff(at: imported, scope: .staged, path: file.lastPathComponent).contains("+staged"))
        XCTAssertTrue(try GitClient.diff(at: imported, scope: .worktree, path: file.lastPathComponent).contains("+unstaged"))
        XCTAssertEqual(try digest(source), sourceDigest)
    }

    func testRealRepositoryHistoryAndFileSearchUseFullOfflineScope() throws {
        let (repo, _) = try workingCopy()
        let all = try GitClient.history(at: repo, limit: 1000, allBranches: true)
        let oldest = try XCTUnwrap(all.last)
        XCTAssertGreaterThan(all.count, 300)
        XCTAssertFalse(try GitClient.history(at: repo, limit: 300, allBranches: true).contains { $0.id == oldest.id })
        var historySamples: [Double] = []
        for _ in 0..<3 {
            historySamples.append(try elapsed {
                let page = try GitClient.historySearch(at: repo, query: String(oldest.id.prefix(12)), field: .oid).nextPage()
                XCTAssertEqual(page.items.map(\.id), [oldest.id])
                XCTAssertGreaterThan(page.scanned, 300)
            })
        }
        try record("search.real-history-old-oid", historySamples)
        var fileSamples: [Double] = []
        for _ in 0..<3 {
            fileSamples.append(try elapsed {
                let reader = try GitClient.fileSearch(at: repo, query: "/")
                var paths = Set<String>()
                while true {
                    let page = try reader.nextPage()
                    for file in page.items { XCTAssertTrue(paths.insert(file.path).inserted); XCTAssertTrue(file.path.contains("/")) }
                    if !page.hasMore { break }
                }
                XCTAssertGreaterThan(paths.count, 300)
            })
        }
        try record("search.real-worktree-nested-paths", fileSamples)
    }

}
