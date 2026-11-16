import SwiftUI
import GitlingIsh
import UIKit
import XCTest
@testable import Gitling

private final class InspectSelection: ObservableObject { @Published var value = FileInspectSection.contents }
private final class PageLoads { var values: [FileInspectSection] = [] }
private struct InspectPagesFixture: View {
    @ObservedObject var selection: InspectSelection
    let loads: PageLoads
    var body: some View {
        VStack {
            FileInspectPicker(section: $selection.value)
            LazySectionPages(selection: $selection.value, values: FileInspectSection.allCases) { page in
                Text(String(describing: page)).onAppear { loads.values.append(page) }
            }
        }
    }
}

@MainActor final class TabletAndSwipeTests: XCTestCase {
    func testFileInspectorPagerDoesNotLoadAdjacentHistoryOrBlame() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let selection = InspectSelection(), loads = PageLoads()
        let host = UIHostingController(rootView: InspectPagesFixture(selection: selection, loads: loads))
        let window = UIWindow(windowScene: scene); window.rootViewController = host
        window.makeKeyAndVisible(); host.view.layoutIfNeeded()
        defer { window.isHidden = true; window.rootViewController = nil }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(Set(loads.values), [.contents])
        selection.value = .history
        try await Task.sleep(for: .milliseconds(150))
        host.view.layoutIfNeeded()
        XCTAssertTrue(loads.values.contains(.history))
        XCTAssertFalse(loads.values.contains(.blame), "A swipe-enabled preview must not eagerly run blame")
        selection.value = .blame
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(loads.values.contains(.blame))
    }

    func testResetSettingsAndInspectorFitTabletLandscapePortraitAndNarrowColumns() throws {
        for width: CGFloat in [320, 507, 768, 1024, 1366] {
            for size in [DynamicTypeSize.large, .accessibility3] {
                let reset = UIHostingController(rootView: Form { TerminalResetSection() }.environment(\.dynamicTypeSize, size))
                reset.view.frame = CGRect(x: 0, y: 0, width: width, height: 850)
                reset.view.layoutIfNeeded()
                XCTAssertLessThanOrEqual(reset.view.systemLayoutSizeFitting(CGSize(width: width, height: 850)).width, width + 1)
                let inspect = UIHostingController(rootView: FileInspectPicker(section: .constant(.contents)).environment(\.dynamicTypeSize, size))
                let fit = inspect.sizeThatFits(in: CGSize(width: width, height: 500))
                XCTAssertLessThanOrEqual(fit.width, width + 1)
                XCTAssertGreaterThan(fit.height, 20)
            }
        }
    }

    func testTabletSettingsAndRepositoryScreenshots() async throws {
        // The same flow runs on phones; an iPad additionally exercises the
        // actual split navigation rather than only synthetic width fixtures.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let name = "Offline Demo"
        try GitClient.initialize(name: name, root: root)
        try Data("# Offline workspace\n\nA local repository for layout verification.\n".utf8).write(to: root.appendingPathComponent(name + "/README.md"))
        try GitClient.stageAll(at: root.appendingPathComponent(name))
        try GitClient.commit(at: root.appendingPathComponent(name), message: "Create offline workspace", name: "Gitling", email: "qa@example.invalid")
        let store = RepoStore(root: root, reloadOnStart: false)
        await store.reload()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        var host: UIHostingController<AnyView>? = UIHostingController(rootView: AnyView(RepoListView().environmentObject(store).environment(\.scenePhase, .active)))
        let window = UIWindow(windowScene: scene); window.rootViewController = host
        window.makeKeyAndVisible(); host!.view.layoutIfNeeded()
        defer { window.isHidden = true; window.rootViewController = nil }
        store.focusName = name
        func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap { descendants($0) } }
        for _ in 0..<240 {
            if descendants(host!.view).contains(where: { ($0 as? UISegmentedControl)?.numberOfSegments == 4 }) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        do {
        let picker = try XCTUnwrap(descendants(host!.view).compactMap { $0 as? UISegmentedControl }.first { $0.numberOfSegments == 4 })
        picker.selectedSegmentIndex = 3; picker.sendActions(for: .valueChanged)
        }
        for _ in 0..<300 {
            if descendants(host!.view).contains(where: { $0.accessibilityIdentifier == "terminal.surface" }) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        host!.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(500))
        capture(host!.view, name: "Repository terminal and split navigation")
        let settings = UIHostingController(rootView: NavigationStack { Form { TerminalResetSection() }.navigationTitle("Settings") })
        window.rootViewController = settings; host = nil; settings.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        capture(settings.view, name: "Terminal reset settings")
        window.isHidden = true; window.rootViewController = nil
        for _ in 0..<200 {
            if gp_ish_active_threads() == 0 && (try? RepositoryAccessGate.holdNative()) != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(gp_ish_active_threads(), 0)
    }
    private func capture(_ view: UIView, name: String) {
        let image = UIGraphicsImageRenderer(bounds: view.bounds).image { _ in view.drawHierarchy(in: view.bounds, afterScreenUpdates: true) }
        let attachment = XCTAttachment(image: image); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
