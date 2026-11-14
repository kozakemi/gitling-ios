import XCTest
import SwiftUI
import Combine
@testable import Gitling

final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [GitProgress] = []
    var values: [GitProgress] { lock.withLock { snapshots } }
    func record(_ value: GitProgress) { lock.withLock { if snapshots.count < 1000 { snapshots.append(value) } } }
}

private final class ProgressSchedule: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [@Sendable () -> Void] = []
    var count: Int { lock.withLock { pending.count } }
    func enqueue(_ work: @escaping @Sendable () -> Void) { lock.withLock { pending.append(work) } }
    func drain() {
        let work = lock.withLock { let result = pending; pending.removeAll(); return result }
        work.forEach { $0() }
    }
}

final class OperationProgressTests: XCTestCase {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func repository(_ root: URL, _ name: String = "source") throws -> URL {
        try GitClient.initialize(name: name, root: root)
        let repo = root.appendingPathComponent(name)
        try advance(repo, content: "initial\n")
        return repo
    }
    private func advance(_ repo: URL, content: String) throws {
        try content.write(to: repo.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        try GitClient.stageAll(at: repo)
        try GitClient.commit(at: repo, message: "offline progress fixture", name: "Test", email: "test@example.invalid")
    }

    func testUnknownTotalsDoNotBecomeZeroPercentAndEachPhaseUsesItsOwnUnits() {
        XCTAssertNil(GitProgress(phase: .connecting).fraction)
        XCTAssertNil(GitProgress(phase: .receiving, completed: 8, total: 0).countText())
        XCTAssertEqual(GitProgress(phase: .receiving, completed: 3, total: 10).fraction, 0.3)
        XCTAssertEqual(GitProgress(phase: .checkingOut, completed: 12, total: 10).fraction, 1)
        XCTAssertEqual(GitProgress(phase: .receiving, completed: -1, total: 10).fraction, 0)
        XCTAssertNotEqual(GitProgress(phase: .checkingOut, completed: 2, total: 4).countText(),
                          GitProgress(phase: .receiving, completed: 2, total: 4).countText())
        XCTAssertNil(GitProgress(phase: .refreshing).fraction)
    }

    func testTenThousandCallbacksCoalesceIntoOnePendingDeliveryAndKeepLatest() {
        let schedule = ProgressSchedule(), recorder = ProgressRecorder()
        let relay = GitProgressRelay(schedule: { schedule.enqueue($0) }, deliver: { recorder.record($0) })
        DispatchQueue.concurrentPerform(iterations: 10000) { index in
            relay.submit(.init(phase: .receiving, completed: index, total: 10000))
        }
        relay.submit(.init(phase: .resolving, completed: 5, total: 20))
        XCTAssertEqual(schedule.count, 1)
        XCTAssertTrue(recorder.values.isEmpty)
        schedule.drain()
        XCTAssertEqual(recorder.values, [.init(phase: .resolving, completed: 5, total: 20)])
        relay.submit(.init(phase: .refreshing))
        XCTAssertEqual(schedule.count, 1)
        relay.invalidate()
        schedule.drain()
        relay.submit(.init(phase: .receiving))
        XCTAssertEqual(schedule.count, 0)
        XCTAssertEqual(recorder.values.count, 1)
    }

    func testRealHTTPCloneFetchAndFastForwardPullReportTransferAndCheckout() throws {
        let root = try root(), source = try repository(root), server = try SubmoduleHTTPServer()
        defer { server.stop() }
        let clone = root.appendingPathComponent("clone"), received = ProgressRecorder()
        server.serve(try .init(at: source, username: "fixture-user", password: "offline"))
        try GitClient.clone(url: server.authority + "/fixed_unit_queue.git", name: "clone", root: root,
                            username: "fixture-user", secret: "offline", progress: { received.record($0) })
        XCTAssertTrue(received.values.contains { $0.phase == .authenticating })
        XCTAssertTrue(received.values.contains { $0.phase == .receiving && $0.total > 0 && $0.bytes > 0 })
        XCTAssertTrue(received.values.contains { $0.phase == .checkingOut && $0.total > 0 && $0.completed == $0.total })
        XCTAssertTrue(received.values.contains { $0.phase == .largeFiles })
        let head = try GitClient.history(at: clone, limit: 1)[0].id
        try advance(source, content: "fetch version\n")
        server.serve(try .init(at: source, username: "fixture-user", password: "offline"))
        let fetched = ProgressRecorder()
        try GitClient.fetch(at: clone, username: "fixture-user", secret: "offline", progress: { fetched.record($0) })
        XCTAssertTrue(fetched.values.contains { $0.phase == .receiving && $0.total > 0 && $0.bytes > 0 })
        XCTAssertEqual(try GitClient.history(at: clone, limit: 1)[0].id, head)
        try advance(source, content: "pulled version\n")
        server.serve(try .init(at: source, username: "fixture-user", password: "offline"))
        let pulled = ProgressRecorder()
        try GitClient.pull(at: clone, username: "fixture-user", secret: "offline", name: "Test", email: "test@example.invalid",
                           progress: { pulled.record($0) })
        XCTAssertTrue(pulled.values.contains { $0.phase == .receiving && $0.bytes > 0 })
        XCTAssertTrue(pulled.values.contains { $0.phase == .checkingOut && $0.total > 0 })
        XCTAssertEqual(try String(contentsOf: clone.appendingPathComponent("file.txt"), encoding: .utf8), "pulled version\n")
        XCTAssertTrue(try GitClient.status(at: clone).isEmpty)
    }

    func testPushReportsActualPackingAndTransportWithoutChangingLocalHead() throws {
        let root = try root(), source = try repository(root)
        try GitClient.initialize(name: "bare", root: root, bare: true)
        let bare = root.appendingPathComponent("bare"), recorder = ProgressRecorder()
        try GitClient.addRemote(at: source, name: "offline", url: bare.path)
        let head = try GitClient.history(at: source, limit: 1)[0].id
        try GitClient.push(at: source, username: "", secret: "", remoteName: "offline", progress: { recorder.record($0) })
        XCTAssertTrue(recorder.values.contains { $0.phase == .connecting })
        XCTAssertTrue(recorder.values.contains { $0.phase == .packing })
        XCTAssertTrue(recorder.values.contains { $0.phase == .sending || $0.phase == .waitingForRemote })
        XCTAssertEqual(try GitClient.history(at: bare, limit: 1)[0].id, head)
        XCTAssertEqual(try GitClient.history(at: source, limit: 1)[0].id, head)
        try GitClient.clone(url: bare.path, name: "other", root: root, username: "", secret: "")
        let other = root.appendingPathComponent("other")
        try advance(other, content: "remote divergence\n")
        try GitClient.push(at: other, username: "", secret: "")
        let remoteHead = try GitClient.history(at: bare, limit: 1)[0].id
        try advance(source, content: "local divergence\n")
        let localHead = try GitClient.history(at: source, limit: 1)[0].id
        XCTAssertThrowsError(try GitClient.push(at: source, username: "", secret: "", remoteName: "offline",
                                               progress: { recorder.record($0) }))
        XCTAssertEqual(try GitClient.history(at: bare, limit: 1)[0].id, remoteHead)
        XCTAssertEqual(try GitClient.history(at: source, limit: 1)[0].id, localHead)
    }

    @MainActor
    func testStoreClearsProgressAfterSuccessAndFailureAndStartsANewIdentity() async throws {
        let root = try root(), source = try repository(root), clone = root.appendingPathComponent("clone")
        try GitClient.clone(url: source.path, name: "clone", root: root, username: "", secret: "")
        let store = RepoStore(root: root, reloadOnStart: false)
        var phases: [GitProgress.Phase] = []
        let observation = store.$operationProgress.sink { if let state = $0 { phases.append(state.progress.phase) } }
        defer { observation.cancel() }
        store.fetch(name: "clone", username: "", secret: "")
        let first = try XCTUnwrap(store.operationProgress)
        XCTAssertTrue(store.isBusy)
        XCTAssertEqual(first.repository, "clone")
        try await waitForFinish(store)
        XCTAssertNil(store.operationProgress)
        XCTAssertTrue(phases.contains(.refreshing))
        try FileManager.default.moveItem(at: source, to: root.appendingPathComponent("parked"))
        store.fetch(name: "clone", username: "", secret: "")
        XCTAssertNotEqual(store.operationProgress?.id, first.id)
        try await waitForFinish(store)
        XCTAssertNotNil(store.alert)
        XCTAssertNil(store.operationProgress)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertNil(store.operationProgress)
        XCTAssertFalse(store.isBusy)
        XCTAssertTrue(try GitClient.status(at: clone).isEmpty)
    }

    @MainActor
    private func waitForFinish(_ store: RepoStore) async throws {
        let limit = ContinuousClock.now + .seconds(15)
        while store.isBusy, ContinuousClock.now < limit { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(store.isBusy, "The offline operation did not finish before its test deadline")
    }

    @MainActor
    func testProgressFitsDuoWidthsAndAccessibilitySizesInThreeLanguages() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        for locale in ["en", "zh-Hans", "ja"] {
            for width in [240.0, 346, 466, 619, 951] {
              for phase in [GitProgress.Phase.receiving, .largeFiles] {
                let state = OperationProgressState(id: UUID(), title: String(localized: "Updating submodules…"),
                    repository: "很长的仓库名称-Offline-Progress", startedAt: Date(),
                    progress: .init(phase: phase, completed: 12345, total: 98765, bytes: 125000000,
                                    byteTotal: phase == .largeFiles ? 9999999999 : 0, submodule: "tools/很长的子模块目录/fixed_unit_queue"))
                let card = UIHostingController(rootView: OperationProgressCard(state: state)
                    .environment(\.locale, Locale(identifier: locale)).environment(\.dynamicTypeSize, .accessibility3))
                let intrinsic = card.sizeThatFits(in: CGSize(width: width, height: 10000))
                XCTAssertLessThanOrEqual(intrinsic.width, width + 0.5)
                XCTAssertGreaterThan(intrinsic.height, 200)
                let host = UIHostingController(rootView: OperationProgressOverlay(state: state)
                    .environment(\.locale, Locale(identifier: locale)).environment(\.dynamicTypeSize, .accessibility3))
                let window = UIWindow(windowScene: scene)
                window.frame = CGRect(x: 0, y: 0, width: width, height: 640)
                window.rootViewController = host; window.makeKeyAndVisible()
                defer { window.isHidden = true; window.rootViewController = nil }
                window.layoutIfNeeded(); host.view.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(20))
                func descendants(_ view: UIView) -> [UIView] { view.subviews.flatMap { [$0] + descendants($0) } }
                let scroll = try XCTUnwrap(descendants(host.view).compactMap { $0 as? UIScrollView }.first)
                XCTAssertLessThanOrEqual(scroll.bounds.width, width + 0.5)
                XCTAssertLessThanOrEqual(scroll.bounds.height, 640 * 0.85 + 1)
                XCTAssertGreaterThan(scroll.bounds.height, 0)
                if width == 240 {
                    XCTAssertGreaterThan(scroll.contentSize.height, scroll.bounds.height)
                    scroll.setContentOffset(CGPoint(x: 0, y: 30), animated: false)
                    XCTAssertGreaterThan(scroll.contentOffset.y, 0)
                }
              }
            }
        }
    }
}
