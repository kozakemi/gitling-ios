import XCTest
import SwiftUI
@testable import Gitling

@MainActor
final class AdaptiveLayoutTests: XCTestCase {
    private func measure<V: View>(_ view: V, width: CGFloat) -> CGSize {
        let host = UIHostingController(rootView: view)
        return host.sizeThatFits(in: CGSize(width: width, height: 10_000))
    }

    func testStashActionsStackWithoutTruncationInNarrowColumn() {
        let actions = AdaptiveActionGroup {
            Button("Apply Stash") {}
            Button("Apply and Remove Stash") {}
            Button("Delete", role: .destructive) {}
        }
        .buttonStyle(.bordered)
        let wide = measure(actions, width: 650)
        let narrow = measure(actions, width: 280)
        XCTAssertLessThanOrEqual(narrow.width, 280)
        XCTAssertGreaterThan(narrow.height, wide.height * 2)
        XCTAssertGreaterThan(wide.height, 30)
    }

    func testLocalizedActionsFitFoldedAndExpandedWidthsWithLargeText() {
        for locale in ["en", "zh-Hans", "ja"] {
            for width: CGFloat in [280, 346, 466, 619, 951] {
                let actions = AdaptiveActionGroup {
                    Button("Apply Stash") {}
                    Button("Pop Stash") {}
                    Button("Delete", role: .destructive) {}
                }
                .buttonStyle(.bordered)
                .environment(\.locale, Locale(identifier: locale))
                .environment(\.dynamicTypeSize, .accessibility3)
                let size = measure(actions, width: width)
                XCTAssertLessThanOrEqual(size.width, width + 0.5, "\(locale), \(width)")
                XCTAssertGreaterThan(size.height, 44)
                XCTAssertTrue(size.height.isFinite)
            }
        }
    }

    func testSectionPickerFitsNarrowDetailAndAccessibilitySizes() {
        for textSize in [DynamicTypeSize.large, .xxxLarge, .accessibility3] {
            for width: CGFloat in [240, 346, 466, 619] {
                let size = measure(RepositorySectionPicker(selection: .constant(2))
                    .environment(\.dynamicTypeSize, textSize), width: width)
                XCTAssertLessThanOrEqual(size.width, width + 0.5)
                XCTAssertGreaterThan(size.height, 20)
            }
        }
    }

    func testCommitRowsGrowForLargeTextAndDenseGraphStaysBounded() {
        let commit = CommitInfo(id: "abcdef01234567", summary: "A long commit summary with enough content to wrap on the folded screen", author: "Author", date: .now, parents: [])
        let row = CommitGraph.Row(commit: commit, lane: 12, columnCount: 20, incoming: [], outgoing: [], merges: [], continuesFromAbove: false)
        let label = CommitHistoryLabel(row: row, minimumHeight: 56) {
            Text("feature/very-long-branch-name").font(.caption2).lineLimit(1)
        }
        let normal = measure(label, width: 300)
        let large = measure(label.environment(\.dynamicTypeSize, .accessibility3), width: 300)
        XCTAssertLessThanOrEqual(normal.width, 300.5)
        XCTAssertLessThanOrEqual(large.width, 300.5)
        XCTAssertGreaterThan(large.height, normal.height)
        XCTAssertGreaterThan(large.height, 56)
        XCTAssertEqual(CommitGraphMark.drawingWidth(columnCount: 1), 14)
        XCTAssertLessThanOrEqual(CommitGraphMark.drawingWidth(columnCount: 100), 84)
        XCTAssertGreaterThan(CommitGraphMark.drawingWidth(columnCount: 0), 0)
    }

    func testConflictActionsFitDuoColumnsAndAccessibilityText() {
        for locale in ["en", "zh-Hans", "ja"] {
            for width: CGFloat in [240, 346, 466, 619, 951] {
                let actions = ConflictOperationActions(canContinue: false, canAbort: true, busy: false, onContinue: {}, onAbort: {})
                    .environment(\.locale, Locale(identifier: locale))
                    .environment(\.dynamicTypeSize, .accessibility3)
                let size = measure(actions, width: width)
                XCTAssertLessThanOrEqual(size.width, width + 0.5)
                XCTAssertGreaterThan(size.height, 44)
                XCTAssertTrue(size.height.isFinite)
            }
        }
    }

    func testFileRestoreActionsAndImpactFitDuoAndAccessibilityText() {
        for locale in ["en", "zh-Hans", "ja"] {
            for width: CGFloat in [240, 346, 466, 619, 951] {
                let actions = FileStatusActions(staged: false, canRestore: true, busy: false, onStage: {}, onRestore: {})
                    .environment(\.locale, Locale(identifier: locale))
                    .environment(\.dynamicTypeSize, .accessibility3)
                let size = measure(actions, width: width)
                XCTAssertLessThanOrEqual(size.width, width + 0.5)
                XCTAssertGreaterThan(size.height, 44)
                let impact = FileRestoreImpact(path: "很长的文件名-for-iPhone-Duo/已暂存但又修改的文件.txt", restoresDeletedFile: false, external: true)
                    .environment(\.locale, Locale(identifier: locale))
                    .environment(\.dynamicTypeSize, .accessibility3)
                let details = measure(impact, width: width)
                XCTAssertLessThanOrEqual(details.width, width + 0.5)
                XCTAssertTrue(details.height.isFinite)
                XCTAssertGreaterThan(details.height, 100)
            }
        }
    }

    func testSubmoduleActionsFitDuoColumnsAndAccessibilityText() {
        for locale in ["en", "zh-Hans", "ja"] {
            for width: CGFloat in [240, 346, 466, 619, 951] {
                for pending in [false, true] {
                    let view = SubmoduleActions(busy: false, pending: pending, onInitialize: {}, onUpdate: {}, onResume: {}, onEnd: {})
                        .environment(\.locale, Locale(identifier: locale))
                        .environment(\.dynamicTypeSize, .accessibility3)
                    let size = measure(view, width: width)
                    XCTAssertLessThanOrEqual(size.width, width + 0.5)
                    XCTAssertGreaterThan(size.height, 44)
                    XCTAssertTrue(size.height.isFinite)
                }
            }
        }
    }

    func testRepositorySearchControlsFitDuoAndLocalizedAccessibilityText() {
        for locale in ["en", "zh-Hans", "ja"] {
            for width: CGFloat in [240, 346, 466, 619, 951] {
                let view = VStack(alignment: .leading, spacing: 8) {
                    RepositoryQueryField(query: .constant("嵌入式/很长的文件名-or-author@example.invalid"), prompt: "File name or relative path")
                    HistorySearchFilters(field: .constant(.all), scope: .constant(.all), selectedReference: "refs/remotes/company/very-long-branch")
                    RepositorySearchStatus(loading: false, count: 100, scanned: 4500, hasMore: true)
                }.environment(\.locale, Locale(identifier: locale)).environment(\.dynamicTypeSize, .accessibility3)
                let size = measure(view, width: width)
                XCTAssertLessThanOrEqual(size.width, width + 0.5)
                XCTAssertGreaterThan(size.height, 44)
                XCTAssertTrue(size.height.isFinite)
            }
        }
    }

    private final class Selection: ObservableObject {
        @Published var name = "first"
        @Published var compact = false
        var identities: [String: UUID] = [:]
    }

    private struct StateProbe: View {
        let name: String
        let recorded: (String, UUID) -> Void
        @State private var identity = UUID()
        var body: some View {
            Text(name).onAppear { recorded(name, identity) }
        }
    }

    private struct NavigationHarness: View {
        @ObservedObject var selection: Selection
        var body: some View {
            RepositoryDetailNavigation(selection: selection.name) {
                StateProbe(name: selection.name) { selection.identities[$0] = $1 }
            }
            .environment(\.horizontalSizeClass, selection.compact ? .compact : .regular)
        }
    }

    func testRepositorySelectionResetsStateWhileResizePreservesIt() async throws {
        let selection = Selection()
        let host = UIHostingController(rootView: NavigationHarness(selection: selection))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 951, height: 669))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        for _ in 0..<100 where selection.identities["first"] == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        let first = try XCTUnwrap(selection.identities["first"])
        selection.compact = true
        window.frame.size = CGSize(width: 466, height: 678)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(selection.identities["first"], first)
        selection.name = "second"
        for _ in 0..<100 where selection.identities["second"] == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotEqual(try XCTUnwrap(selection.identities["second"]), first)
        selection.identities.removeValue(forKey: "first")
        selection.name = "first"
        for _ in 0..<100 where selection.identities["first"] == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotEqual(try XCTUnwrap(selection.identities["first"]), first)
    }
}
