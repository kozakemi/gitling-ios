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

@MainActor
final class RepositoryListReadinessTests: XCTestCase {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("readiness-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        for name in ["first", "second"] {
            try GitClient.initialize(name: name, root: root)
            let repo = root.appendingPathComponent(name)
            try "base\n".write(to: repo.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
            try GitClient.stageAll(at: repo); try GitClient.commit(at: repo, message: "Base", name: "Fixture", email: "fixture@example.invalid")
        }
        return root
    }

    func testColdListPublishesBranchesBeforeSlowStatusAndCoalescesRefreshes() async throws {
        let root = try root(), gate = SummaryGate(), reached = expectation(description: "Status scan started")
        try "changed\n".write(to: root.appendingPathComponent("second/file.txt"), atomically: true, encoding: .utf8)
        let store = RepoStore(root: root, reloadOnStart: false, statusSummary: { url in
            if gate.begin(url.lastPathComponent) { reached.fulfill(); gate.wait() }
            return GitClient.summary(at: url)
        })
        let start = Date()
        await store.reload(waitForStatus: false)
        XCTAssertEqual(store.repos.count, 2)
        XCTAssertTrue(store.repos.allSatisfy { $0.branch != nil && $0.statusState == .checking })
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        await fulfillment(of: [reached], timeout: 2)
        for _ in 0..<10 { await store.reload(waitForStatus: false) }
        XCTAssertEqual(gate.names, ["first"])
        let loading = RepositoryListLabels.subtitle(try XCTUnwrap(store.repos.first), locale: Locale(identifier: "en"))
        XCTAssertTrue(loading.contains(try XCTUnwrap(store.repos.first?.branch)))
        var ready = try XCTUnwrap(store.repos.first); ready.statusState = .ready
        XCTAssertNotEqual(loading, RepositoryListLabels.subtitle(ready, locale: Locale(identifier: "en")))
        gate.release()
        await store.reload()
        XCTAssertEqual(gate.names, ["first", "second"])
        XCTAssertTrue(store.repos.allSatisfy { $0.statusState == .ready })
        XCTAssertEqual(store.repos.first { $0.name == "second" }?.isDirty, true)
    }

    func testTargetedWriteInvalidatesAnOlderBackgroundCycle() async throws {
        let root = try root(), gate = SummaryGate(), reached = expectation(description: "Old scan started")
        try GitClient.createBranch(at: root.appendingPathComponent("first"), name: "feature", checkout: false)
        let store = RepoStore(root: root, reloadOnStart: false, statusSummary: { url in
            if gate.begin(url.lastPathComponent) { reached.fulfill(); gate.wait() }
            return GitClient.summary(at: url)
        })
        await store.reload(waitForStatus: false)
        await fulfillment(of: [reached], timeout: 2)
        store.checkout(name: "first", branch: "feature")
        for _ in 0..<500 where store.isBusy { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(store.isBusy); XCTAssertNil(store.alert)
        XCTAssertEqual(store.repos.first { $0.name == "first" }?.branch, "feature")
        gate.release()
        await store.reload()
        XCTAssertEqual(store.repos.first { $0.name == "first" }?.branch, "feature")
        XCTAssertTrue(store.repos.allSatisfy { $0.statusState == .ready })
    }

    func testStatusErrorIsUnknownAndLegacyCacheCanStillDecode() throws {
        let legacy = Data("{\"name\":\"old\",\"branch\":\"main\",\"isDirty\":false,\"unavailable\":false}".utf8)
        let decoded = try JSONDecoder().decode(RepoSummary.self, from: legacy)
        XCTAssertNil(decoded.statusState)
        var pending = decoded; pending.statusState = .checking
        var failed = decoded; failed.statusState = .unavailable
        for language in ["en", "zh-Hans", "ja"] {
            let locale = Locale(identifier: language)
            XCTAssertNotEqual(RepositoryListLabels.subtitle(pending, locale: locale), RepositoryListLabels.subtitle(decoded, locale: locale))
            XCTAssertNotEqual(RepositoryListLabels.subtitle(failed, locale: locale), RepositoryListLabels.subtitle(decoded, locale: locale))
        }
    }

    func testMetadataDoesNotOpenExternalWorktreeAndSummaryAvoidsDeepUntrackedScan() throws {
        let root = try root(), repo = root.appendingPathComponent("first")
        try WorktreeLink.save(repoName: "first", data: Data("expired bookmark".utf8))
        defer { WorktreeLink.remove(repoName: "first") }
        let metadata = GitClient.summaryMetadata(at: repo)
        XCTAssertNotNil(metadata.branch); XCTAssertFalse(metadata.unavailable); XCTAssertEqual(metadata.statusState, .checking)
        XCTAssertNil(GitClient.summary(at: repo))
        WorktreeLink.remove(repoName: "first")
        let nested = repo.appendingPathComponent("untracked/deep/folder")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        for index in 0..<100 { try "data".write(to: nested.appendingPathComponent("\(index).txt"), atomically: true, encoding: .utf8) }
        let summary = try XCTUnwrap(GitClient.summary(at: repo))
        XCTAssertTrue(summary.isDirty); XCTAssertEqual(summary.statusState, .ready)
        XCTAssertEqual(try GitClient.status(at: repo).filter(\.untracked).count, 100)
        let index = repo.appendingPathComponent(".git/index")
        try Data("damaged index".utf8).write(to: index)
        XCTAssertNotNil(GitClient.summaryMetadata(at: repo).branch)
        let failed = try XCTUnwrap(GitClient.summary(at: repo))
        XCTAssertEqual(failed.statusState, .unavailable)
    }
}

private final class SummaryGate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var started: [String] = []
    var names: [String] { lock.withLock { started } }
    func begin(_ name: String) -> Bool { lock.withLock { started.append(name); return started.count == 1 } }
    func wait() { semaphore.wait() }
    func release() { semaphore.signal() }
}
