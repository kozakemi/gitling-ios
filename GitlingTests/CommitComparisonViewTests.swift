import SwiftUI
import XCTest
@testable import Gitling

private final class ComparisonWorkCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    private var maximum = 0
    private var executed = 0
    func enter() { lock.lock(); active += 1; maximum = max(maximum, active); executed += 1; lock.unlock() }
    func leave() { lock.lock(); active -= 1; lock.unlock() }
    var totals: (peak: Int, executed: Int) { lock.lock(); defer { lock.unlock() }; return (maximum, executed) }
}

@MainActor
final class CommitComparisonViewTests: XCTestCase {
    private func endpoint(_ character: String) -> ComparisonEndpoint {
        ComparisonEndpoint(oid: String(repeating: character, count: 40), input: "refs/remotes/origin/版本-非常长的分支名-長いブランチ名-development", source: .remoteBranch, summary: "Compare historical versions · 提交说明 · コミットの説明", author: "Fixture", date: .distantPast)
    }

    func testRapidReplacementSkipsCancelledQueuedReadsAndNeverPublishesLateResult() async {
        let model = ComparisonLoadModel<String>(), counter = ComparisonWorkCounter(), started = expectation(description: "first read started")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let first = Task {
            await model.load { _ in
                counter.enter(); defer { counter.leave() }
                started.fulfill()
                _ = release.wait(timeout: .now() + 5)
                return "obsolete" // Deliberately simulates a synchronous call ignoring cancellation.
            }
        }
        await fulfillment(of: [started], timeout: 2)
        var replacements: [Task<Void, Never>] = []
        for number in 0..<20 {
            replacements.append(Task {
                await model.load { token in
                    try token.check()
                    counter.enter(); defer { counter.leave() }
                    return "latest-\(number)"
                }
            })
            await Task.yield()
        }
        release.signal()
        await first.value
        for replacement in replacements { await replacement.value }
        XCTAssertEqual(model.value, "latest-19")
        XCTAssertNil(model.error); XCTAssertFalse(model.isLoading)
        XCTAssertEqual(counter.totals.peak, 1)
        XCTAssertEqual(counter.totals.executed, 2, "Only the running read and newest queued read may execute")
        model.cancel(); XCTAssertNil(model.value)
    }

    func testTaskCancellationReachesRunningReaderAndClearsLoadingWithoutPublishing() async {
        let model = ComparisonLoadModel<Int>(), started = expectation(description: "cooperative read started"), cancelled = expectation(description: "reader observed cancellation")
        let task = Task {
            await model.load { token in
                started.fulfill()
                for _ in 0..<2000 {
                    do { try token.check() }
                    catch { cancelled.fulfill(); throw error }
                    Thread.sleep(forTimeInterval: 0.001)
                }
                return 1
            }
        }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        await fulfillment(of: [cancelled], timeout: 2)
        await task.value
        XCTAssertNil(model.value); XCTAssertNil(model.error); XCTAssertFalse(model.isLoading)
    }

    func testSelectingAnotherReferenceAtSameOIDOrSwappingIdenticalEndpointsKeepsLoadedResult() async {
        let model = ComparisonLoadModel<String>()
        await model.load { _ in "same-commit result" }
        let base = endpoint("a"), target = endpoint("a")
        let original = CommitComparison(base: base, target: target)
        // A different display/ref name can resolve to the very same fixed OID.
        let alias = ComparisonEndpoint(oid: base.oid, input: "refs/tags/same-commit", source: .tag, summary: "alias", author: "Fixture", date: .distantPast)
        model.invalidate(from: original.id, to: CommitComparison(base: alias, target: target).id)
        XCTAssertEqual(model.value, "same-commit result")
        model.invalidate(from: original.id, to: original.swapped().id)
        XCTAssertEqual(model.value, "same-commit result")
        model.invalidate(from: original.id, to: CommitComparison(base: base, target: endpoint("b")).id)
        XCTAssertNil(model.value)
    }

    func testEndpointHeaderFitsDuoWidthsAndLocalizedAccessibilityText() {
        for locale in ["en", "zh-Hans", "ja"] {
            for width: CGFloat in [240, 346, 466, 619, 951] {
                let header = ComparisonEndpointHeader(base: endpoint("a"), target: endpoint("b"), chooseBase: {}, chooseTarget: {}, swap: {})
                let host = UIHostingController(rootView: header.environment(\.locale, Locale(identifier: locale)).environment(\.dynamicTypeSize, .accessibility3))
                let size = host.sizeThatFits(in: CGSize(width: width, height: 10_000))
                XCTAssertLessThanOrEqual(size.width, width + 0.5, "\(locale) \(width)")
                XCTAssertGreaterThan(size.height, 100)
            }
        }
    }

    private struct HeaderFrame: PreferenceKey {
        static var defaultValue = CGRect.zero
        static func reduce(value: inout CGRect, nextValue: () -> CGRect) { let next = nextValue(); if next.height > 1 { value = next } }
    }
    private final class FontState: ObservableObject {
        @Published var size = DynamicTypeSize.large
    }
    private struct FontHarness: View {
        @ObservedObject var state: FontState
        var body: some View {
            DiffPanelLayout {
                ComparisonHeaderViewport(maximumHeight: 160) {
                    VStack {
                        ForEach(0..<12) { _ in Text("Full OID and long historical file path · 历史路径").fixedSize(horizontal: false, vertical: true) }
                    }
                }
            } content: {
                DiffTextView(text: "@@ -1 +1 @@\n-before\n+after\n").frame(minHeight: 200)
            }.environment(\.dynamicTypeSize, state.size)
        }
    }
    private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap { descendants($0) } }

    func testDiffTextTracksRuntimeDynamicTypeAndHeaderRemainsScrollable() async throws {
        let state = FontState(), host = UIHostingController(rootView: FontHarness(state: state))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 346, height: 678)
        window.rootViewController = host; window.makeKeyAndVisible()
        host.view.setNeedsLayout(); host.view.layoutIfNeeded(); window.layoutIfNeeded()
        defer { window.isHidden = true; window.rootViewController = nil }
        for _ in 0..<100 where descendants(window).compactMap({ $0 as? UITextView }).isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        let text = try XCTUnwrap(descendants(window).compactMap { $0 as? UITextView }.first, String(describing: descendants(window).map { (String(describing: type(of: $0)), $0.frame) }))
        func pointSize() -> CGFloat { (text.attributedText.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)?.pointSize ?? 0 }
        let initial = pointSize()
        XCTAssertGreaterThan(initial, 0)
        state.size = .accessibility3
        for _ in 0..<100 where pointSize() <= initial { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertGreaterThan(pointSize(), initial * 1.5, "The UIKit patch must scale along with SwiftUI metadata")
        let header = try XCTUnwrap(descendants(window).compactMap { $0 as? UIScrollView }.first { !($0 is UITextView) })
        XCTAssertGreaterThan(header.contentSize.height, header.bounds.height)
        header.setContentOffset(CGPoint(x: 0, y: min(100, header.contentSize.height - header.bounds.height)), animated: false)
        XCTAssertGreaterThan(header.contentOffset.y, 0, "Capped metadata must remain scrollable")
        state.size = .small
        for _ in 0..<100 where pointSize() >= initial { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertLessThan(pointSize(), initial)
        XCTAssertEqual(text.attributedText.string, "@@ -1 +1 @@\n-before\n+after\n")
        XCTAssertFalse(text.isEditable); XCTAssertTrue(text.isSelectable)
        XCTAssertFalse(text.adjustsFontForContentSizeCategory, "Explicit trait scaling must not be applied a second time")
        try await Task.sleep(for: .milliseconds(50))
    }
    private final class LayoutState: ObservableObject {
        @Published var phase = 0
        var frame = CGRect.zero
        var rendered = -1
    }
    private struct LayoutHarness: View {
        @ObservedObject var state: LayoutState
        let base: ComparisonEndpoint
        let target: ComparisonEndpoint
        var body: some View {
            DiffPanelLayout {
                ComparisonHeaderViewport(maximumHeight: 200) {
                    ComparisonEndpointHeader(base: base, target: target, chooseBase: {}, chooseTarget: {}, swap: {}).padding(.horizontal)
                }
                .background(GeometryReader { proxy in Color.clear.preference(key: HeaderFrame.self, value: proxy.frame(in: .global)) })
            } content: {
                Group {
                    switch state.phase {
                    case 0: DiffTextView(text: "@@ -1 +1 @@\n-before\n+after\n")
                    case 1: Text("No changed files between these commits.")
                    case 2: Text("Could not compare those commits.")
                    default: ProgressView()
                    }
                }.task(id: state.phase) { state.rendered = state.phase }
            }
            .onPreferenceChange(HeaderFrame.self) { state.frame = $0 }
        }
    }

    func testScrollableHeaderStaysAtTopAndLeavesRoomForDiffAcrossAllStates() async throws {
        for size in [CGSize(width: 346, height: 678), CGSize(width: 466, height: 678), CGSize(width: 951, height: 669)] {
            let state = LayoutState()
            let host = UIHostingController(rootView: LayoutHarness(state: state, base: endpoint("a"), target: endpoint("b")).environment(\.dynamicTypeSize, .accessibility3))
            let window = UIWindow(frame: CGRect(origin: .zero, size: size)); window.rootViewController = host; window.makeKeyAndVisible()
            defer { window.isHidden = true; window.rootViewController = nil }
            for _ in 0..<100 where state.frame.height < 100 || state.rendered != 0 { try await Task.sleep(for: .milliseconds(10)) }
            let original = state.frame.minY
            XCTAssertGreaterThan(state.frame.height, 100); XCTAssertLessThanOrEqual(state.frame.height, 200.5)
            XCTAssertLessThan(original, 120)
            for phase in [1, 2, 3, 0] {
                state.phase = phase
                for _ in 0..<100 where state.rendered != phase { try await Task.sleep(for: .milliseconds(10)) }
                try await Task.sleep(for: .milliseconds(30))
                XCTAssertEqual(state.rendered, phase)
                XCTAssertEqual(state.frame.minY, original, accuracy: 1)
                XCTAssertLessThanOrEqual(state.frame.height, 200.5)
            }
        }
        let state = LayoutState()
        let short = ComparisonHeaderViewport(maximumHeight: 200) { Text("Short header").padding(8) }
            .background(GeometryReader { proxy in Color.clear.preference(key: HeaderFrame.self, value: proxy.frame(in: .global)) })
            .onPreferenceChange(HeaderFrame.self) { state.frame = $0 }
        let host = UIHostingController(rootView: short), window = UIWindow(frame: CGRect(x: 0, y: 0, width: 346, height: 678))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        for _ in 0..<100 where state.frame.height < 20 || state.frame.height > 100 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertGreaterThan(state.frame.height, 20); XCTAssertLessThan(state.frame.height, 100, "A short header must not reserve the whole maximum viewport")
    }
}
