import XCTest
import SwiftUI
@testable import Gitling

@MainActor
final class DiffPanelLayoutTests: XCTestCase {
    private struct HeaderFrame: PreferenceKey {
        static var defaultValue = CGRect.zero
        static func reduce(value: inout CGRect, nextValue: () -> CGRect) { let next = nextValue(); if next.height > 0 { value = next } }
    }
    private final class State: ObservableObject {
        @Published var phase = 0
        @Published var scope = GitClient.DiffScope.worktree
        var header = CGRect.zero
        var rendered = -1
    }
    private struct Harness: View {
        @ObservedObject var state: State
        var body: some View {
            DiffPanelLayout {
                DiffScopePicker(scope: $state.scope)
                    .background(GeometryReader { proxy in Color.clear.preference(key: HeaderFrame.self, value: proxy.frame(in: .global)) })
                    .padding(.horizontal)
            } content: {
                Group {
                    switch state.phase {
                    case 0: ScrollView { Text("diff content\n+ changed line").frame(maxWidth: .infinity, alignment: .leading) }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    case 1: Text("No changes").foregroundStyle(.secondary).padding()
                    case 2: Text("Could not read changes").padding()
                    default: ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .task(id: state.phase) { state.rendered = state.phase }
            }
            .onPreferenceChange(HeaderFrame.self) { state.header = $0 }
        }
    }

    func testSwitchingFromWorktreePatchToEmptyStagedDiffKeepsPickerAtTop() async throws {
        for size in [CGSize(width: 393, height: 852), CGSize(width: 466, height: 678), CGSize(width: 951, height: 669)] {
            let state = State()
            let host = UIHostingController(rootView: Harness(state: state))
            let window = UIWindow(frame: CGRect(origin: .zero, size: size))
            window.rootViewController = host
            window.makeKeyAndVisible()
            defer { window.isHidden = true; window.rootViewController = nil }
            for _ in 0..<100 where state.rendered != 0 || state.header.height == 0 { try await Task.sleep(for: .milliseconds(10)) }
            let original = state.header.minY
            XCTAssertGreaterThan(state.header.height, 20)
            XCTAssertLessThan(original, 120, "Header must be near the top, not vertically centered")
            // The reported sequence: enter an unstaged patch, select staged
            // changes (empty), and switch back. Error/loading share this layout.
            for phase in [1, 0, 2, 3, 1] {
                state.scope = phase == 1 ? .staged : .worktree
                state.phase = phase
                for _ in 0..<100 where state.rendered != phase { try await Task.sleep(for: .milliseconds(10)) }
                try await Task.sleep(for: .milliseconds(30))
                XCTAssertEqual(state.rendered, phase)
                XCTAssertEqual(state.header.minY, original, accuracy: 1, "\(size), phase \(phase)")
                XCTAssertLessThan(state.header.minY, size.height / 4)
            }
        }
    }

    func testDiffPickerAndTagWarningsFitDuoAndLocalizedAccessibilityText() {
        for locale in ["en", "zh-Hans", "ja"] {
            for width: CGFloat in [240, 346, 466, 619, 951] {
                let picker = UIHostingController(rootView: DiffScopePicker(scope: .constant(.staged))
                    .environment(\.locale, Locale(identifier: locale)).environment(\.dynamicTypeSize, .accessibility3))
                let size = picker.sizeThatFits(in: CGSize(width: width, height: 10_000))
                XCTAssertLessThanOrEqual(size.width, width + 0.5)
                XCTAssertGreaterThan(size.height, 20)
                let notice = UIHostingController(rootView: VStack(alignment: .leading) {
                    DetachedHeadNotice(oid: String(repeating: "a", count: 40))
                    TagCheckoutImpact(tag: "release/版本-很长的标签名称-for-iPhone-Duo", oid: String(repeating: "b", count: 40))
                }.environment(\.locale, Locale(identifier: locale)).environment(\.dynamicTypeSize, .accessibility3))
                let warning = notice.sizeThatFits(in: CGSize(width: width, height: 10_000))
                XCTAssertLessThanOrEqual(warning.width, width + 0.5)
                XCTAssertGreaterThan(warning.height, 100)
                XCTAssertTrue(warning.height.isFinite)
            }
        }
    }
}
