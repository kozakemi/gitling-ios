import SwiftUI
import GitlingIsh
import SwiftTerm
import UIKit
import XCTest
@testable import Gitling

private final class HorizontalTestPan: UIPanGestureRecognizer {
    override func velocity(in view: UIView?) -> CGPoint { CGPoint(x: 100, y: 5) }
}

private final class FontSelection: ObservableObject {
    @Published var size = 22.0
}

private struct FontPreviewHost: View {
    @ObservedObject var selection: FontSelection
    var body: some View { TerminalFontSizeSheet(size: $selection.size) }
}

@MainActor final class RepositoryTerminalLayoutTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults.standard.set(TerminalFont.fallback, forKey: TerminalFont.storageKey)
    }

    func testDuoNarrowWideAndKeyboardHeightLayoutsKeepTerminalAndControlsVisible() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        for width: CGFloat in [240, 346, 466, 619, 951] {
            for font in [DynamicTypeSize.large, .accessibility3] {
                let model = RepositoryTerminalModel()
                let host = UIHostingController(rootView: RepositoryTerminalView(repo: URL(fileURLWithPath: "/unused"), model: model)
                    .environment(\.dynamicTypeSize, font))
                let window = UIWindow(windowScene: scene)
                window.frame = CGRect(x: 0, y: 0, width: width, height: 560)
                window.rootViewController = host; window.makeKeyAndVisible()
                defer { window.isHidden = true; window.rootViewController = nil }
                for height: CGFloat in [560, 360] {
                    window.frame.size.height = height
                    host.view.setNeedsLayout(); host.view.layoutIfNeeded()
                    let terminal = try XCTUnwrap(model.surface)
                    let frame = terminal.convert(terminal.bounds, to: host.view)
                    let labels = Self.labels(in: host.view)
                    XCTAssertFalse(labels.contains { $0.contains("Offline Shell") || $0.contains("Repository:") || $0.contains("Leaving this page") })
                    XCTAssertGreaterThan(frame.height, height * 0.3, "The explanation block should not shrink the terminal")
                    XCTAssertEqual(terminal.contentInset, .zero)
                    terminal.feed(text: "ready")
                    terminal.layoutIfNeeded()
                    XCTAssertEqual(terminal.contentOffset.y, 0, accuracy: 1)
                    XCTAssertEqual(terminal.caretFrame.minY, 0, accuracy: 1, "Input row should start at the top of the terminal background")
                    XCTAssertGreaterThan(frame.width, 100)
                    XCTAssertGreaterThan(frame.height, 40, "Terminal must remain usable with keyboard and large text")
                    XCTAssertGreaterThanOrEqual(frame.minX, -1)
                    XCTAssertLessThanOrEqual(frame.maxX, width + 1)
                    XCTAssertGreaterThanOrEqual(frame.minY, -1)
                    XCTAssertLessThanOrEqual(frame.maxY, height + 1)
                    XCTAssertGreaterThan(terminal.getTerminal().cols, 1)
                    XCTAssertGreaterThan(terminal.getTerminal().rows, 1)
                }
                XCTAssertFalse(model.active, "Layout must not boot the kernel or acquire a repository lease")
            }
        }
    }

    func testLiveProductionTerminalStreamsAndStopsWithRepositoryLease() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try GitClient.initialize(name: "ui-shell", root: root)
        let repo = root.appendingPathComponent("ui-shell")
        let model = RepositoryTerminalModel()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: RepositoryTerminalView(repo: repo, model: model))
        window.rootViewController = host; window.makeKeyAndVisible(); host.view.layoutIfNeeded()
        defer { model.stop(); window.isHidden = true; window.rootViewController = nil }
        model.start(repo: repo)
        for _ in 0..<3000 {
            if model.phase == .running || !model.active { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(model.phase, .running, model.error ?? "Missing PTY prompt")
        guard model.phase == .running else { return }
        model.send(Array("stty -echo; git --version; printf '__%s__\\n' UI_READY\n".utf8)[...])
        let terminal = try XCTUnwrap(model.surface)
        for _ in 0..<300 {
            if String(decoding: terminal.getTerminal().getBufferAsData(), as: UTF8.self).contains("__UI_READY__") { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let text = String(decoding: terminal.getTerminal().getBufferAsData(), as: UTF8.self)
        XCTAssertTrue(text.contains("__UI_READY__"), text)
        XCTAssertTrue(text.contains("git version"), text)
        XCTAssertThrowsError(try GitClient.status(at: repo))
        model.setForeground(false)
        for _ in 0..<200 { if model.phase == .suspended { break }; try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(model.phase, .suspended)
        XCTAssertNoThrow(try GitClient.status(at: repo))
        model.setForeground(true)
        for _ in 0..<200 { if model.phase == .running { break }; try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(model.phase, .running)
        host.view.layoutIfNeeded()
        // CoreText rendering is scheduled for the next display frame after
        // the PTY bytes enter the emulator; capture the rendered output.
        try await Task.sleep(for: .milliseconds(250))
        let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true) }
        let screenshot = XCTAttachment(image: image)
        screenshot.name = "Production offline PTY terminal"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        model.stop()
        for _ in 0..<240 {
            if !model.active { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertFalse(model.active)
        XCTAssertNil(model.error)
        XCTAssertNoThrow(try GitClient.status(at: repo))
    }

    func testStartWaitsWhileNativeGitHoldsTheRepository() async throws {
        let hold = try RepositoryAccessGate.holdNative()
        defer { withExtendedLifetime(hold) {} }
        let model = RepositoryTerminalModel()
        model.start(repo: URL(fileURLWithPath: "/tmp/gitling-terminal-wait"))
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(model.phase, .starting)
        XCTAssertNil(model.error)
        XCTAssertEqual(model.status, String(localized: "Preparing Git…"))
        model.stop()
        for _ in 0..<40 {
            if !model.active { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(model.phase, .stopped)
        XCTAssertNil(model.error)
    }

    func testRepositoryAutomaticallyStartsAndSwipesWithoutLosingShellState() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let name = "automatic-" + UUID().uuidString
        try GitClient.initialize(name: name, root: root)
        let store = RepoStore(root: root, reloadOnStart: false)
        let model = RepositoryTerminalModel()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let host = UIHostingController(rootView: RepoDetailView(name: name, terminal: model).environmentObject(store).environment(\.scenePhase, .active))
        let window = UIWindow(windowScene: scene); window.rootViewController = host
        window.makeKeyAndVisible(); host.view.layoutIfNeeded()
        defer { model.stop(); window.isHidden = true; window.rootViewController = nil }
        for _ in 0..<3000 {
            if model.phase == .suspended { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(model.phase, .suspended, model.error ?? "Entry should start and park the shell")
        XCTAssertNoThrow(try GitClient.status(at: root.appendingPathComponent(name)))
        let gate = try XCTUnwrap(Self.control(identifier: "repository.sections.gate", in: host.view))
        let pager = try XCTUnwrap(RepositoryPagingGate.pagingScroller(from: gate) as? UICollectionView)
        func swipe(to section: Int) {
            pager.setContentOffset(CGPoint(x: pager.bounds.width * CGFloat(section), y: 0), animated: false)
            pager.layoutIfNeeded()
            var target = pager.contentOffset
            pager.delegate?.scrollViewWillEndDragging?(pager, withVelocity: .zero, targetContentOffset: &target)
            pager.delegate?.scrollViewDidEndDecelerating?(pager)
            host.view.layoutIfNeeded()
        }
        swipe(to: 3)
        for _ in 0..<200 {
            if model.phase == .running { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(model.phase, .running)
        let emulator = model.terminalSurface()
        model.send(Array("stty -echo; export TAB_MEMORY=kept; printf '__%s__\\n' TAB_READY\n".utf8)[...])
        for _ in 0..<200 {
            if String(decoding: emulator.getTerminal().getBufferAsData(), as: UTF8.self).contains("__TAB_READY__") { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(pager.isScrollEnabled, "Terminal must allow horizontal paging")
        swipe(to: 2)
        for _ in 0..<200 {
            if model.phase == .suspended { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(model.phase, .suspended)
        XCTAssertTrue(model.active)
        XCTAssertNoThrow(try GitClient.status(at: root.appendingPathComponent(name)))
        swipe(to: 3)
        for _ in 0..<200 {
            if model.phase == .running { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(model.surface === emulator)
        model.send(Array("printf '__%s__\\n' \"$TAB_MEMORY\"\n".utf8)[...])
        for _ in 0..<200 {
            if String(decoding: emulator.getTerminal().getBufferAsData(), as: UTF8.self).contains("__kept__") { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(String(decoding: emulator.getTerminal().getBufferAsData(), as: UTF8.self).contains("__kept__"))
        model.stop()
        for _ in 0..<200 { if !model.active { break }; try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertFalse(model.active)
    }

    func testDroppingRepositoryScopeCancelsGuestWithoutRetainingItsModel() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try GitClient.initialize(name: "scope", root: root)
        var model: RepositoryTerminalModel? = RepositoryTerminalModel()
        weak var released = model
        model?.start(repo: root.appendingPathComponent("scope"))
        for _ in 0..<3000 { if model?.phase == .running { break }; try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(model?.phase, .running)
        model?.setForeground(false)
        model = nil
        XCTAssertNil(released, "Worker callbacks must not retain a repository's UI scope")
        for _ in 0..<200 { if gp_ish_active_threads() == 0 { break }; try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(gp_ish_active_threads(), 0)
        XCTAssertNoThrow(try RepositoryAccessGate.holdNative())
    }

    func testLeavingRepositoryNavigationScopeReleasesTheParkedSession() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let name = "leave-" + UUID().uuidString
        try GitClient.initialize(name: name, root: root)
        let store = RepoStore(root: root, reloadOnStart: false)
        var owner: RepositoryTerminalModel? = RepositoryTerminalModel()
        weak var released = owner
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        var host: UIHostingController<AnyView>? = UIHostingController(rootView: AnyView(
            RepoDetailView(name: name, terminal: owner).environmentObject(store).environment(\.scenePhase, .active)))
        window.rootViewController = host; window.makeKeyAndVisible(); host?.view.layoutIfNeeded()
        for _ in 0..<3000 { if owner?.phase == .suspended { break }; try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(owner?.phase, .suspended)
        window.isHidden = true; window.rootViewController = nil; host = nil; owner = nil
        for _ in 0..<240 {
            if released == nil && gp_ish_active_threads() == 0 && store.revision > 0 && (try? RepositoryAccessGate.holdNative()) != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertGreaterThan(store.revision, 0, "Sidebar and cached pages must refresh even after the session owner is deallocated")
        XCTAssertNil(released, "Completion closures and terminal coordinators must not retain the repository scope")
        XCTAssertEqual(gp_ish_active_threads(), 0)
        XCTAssertNoThrow(try RepositoryAccessGate.holdNative())
    }

    func testFontSizePreviewUsesTheSelectedSize() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let selection = FontSelection()
        let host = UIHostingController(rootView: FontPreviewHost(selection: selection))
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 500)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        defer { window.isHidden = true; window.rootViewController = nil }
        let preview = try XCTUnwrap(Self.control(identifier: "terminal.font.preview", in: host.view) as? UILabel)
        XCTAssertEqual(preview.font.pointSize, 22, accuracy: 0.5)
        XCTAssertEqual(preview.text, "/shared $ git status")
        selection.size = 16
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        XCTAssertEqual(preview.font.pointSize, 16, accuracy: 0.5, "The sample should follow the slider while it is moving")
    }

    func testTerminalHorizontalPanYieldsToRepositoryPaging() {
        let model = RepositoryTerminalModel()
        let terminal = model.terminalSurface()
        terminal.frame = CGRect(x: 0, y: 0, width: 346, height: 500)
        let pan = HorizontalTestPan()
        terminal.addGestureRecognizer(pan)
        XCTAssertFalse(terminal.gestureRecognizerShouldBegin(pan), "Horizontal input must reach the repository pager")
        terminal.removeGestureRecognizer(pan)
    }

    func testSplitUTF8ANSIAndTerminalInputAreRenderedByEmulator() throws {
        let terminal = TerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let bytes = Array("\u{1b}[31m你好\u{1b}[0m\r\nready".utf8)
        for byte in bytes { terminal.feed(byteArray: [byte][...]) }
        let text = String(decoding: terminal.getTerminal().getBufferAsData(), as: UTF8.self).replacingOccurrences(of: "\0", with: "")
        XCTAssertTrue(text.contains("你好"), text)
        XCTAssertTrue(text.contains("ready"), text)
        XCTAssertFalse(text.contains("[31m"))
        XCTAssertTrue(terminal.canBecomeFirstResponder)
    }

    private static func labels(in view: UIView) -> [String] {
        var result: [String] = []
        if let label = view as? UILabel, let text = label.text { result.append(text) }
        for child in view.subviews { result.append(contentsOf: labels(in: child)) }
        return result
    }

    private static func control(identifier: String, in root: UIView) -> UIView? {
        if root.accessibilityIdentifier == identifier { return root }
        for child in root.subviews {
            if let found = control(identifier: identifier, in: child) { return found }
        }
        return nil
    }
}
