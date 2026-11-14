import CryptoKit
import ImageIO
import SwiftUI
import UIKit
import WebKit
import XCTest
@testable import Gitling

private enum MarkdownImageFixtures {
    static let red = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAgAAAAECAIAAAA8r+mnAAAAEklEQVR4nGP4z8CAFWEXJUsCAFpeH+EeQoQoAAAAAElFTkSuQmCC")!
    static let blue = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAMAAAAGCAIAAACJh7NbAAAAD0lEQVR4nGNgYPgPQ6SyAAhQEe+mAnSXAAAAAElFTkSuQmCC")!
    static func width(_ data: Data) -> Int {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return 0 }
        return (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
    }
}

final class MarkdownRepositoryImageTests: XCTestCase {
    private func directory() throws -> URL {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("md-images-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: path) }
        return path
    }

    func testPathResolutionHandlesParentsRootUnicodeAndURLSuffixes() {
        let cases = [
            "images/a.png": "docs/images/a.png", "./a.png": "docs/a.png", "../images/a.png": "images/a.png",
            "/images/a.png": "images/a.png", "../images/截图 1.png": "images/截图 1.png",
            "../images/%E6%88%AA%E5%9B%BE%201.png?raw=true#view": "images/截图 1.png",
            "a%23b.png#fragment": "docs/a#b.png", "a%2532.png": "docs/a%32.png",
            "sub/../a.png": "docs/a.png"
        ]
        for (raw, path) in cases { XCTAssertEqual(MarkdownImagePath.resolve(raw, document: "docs/README.md"), path, raw) }
        XCTAssertEqual(MarkdownImagePath.resolve("./logo.png", document: "README.md"), "logo.png")
    }

    func testInvalidPathsNeverBecomeFilesystemOrNetworkURLs() {
        for raw in ["", "#anchor", "?raw=1", "../../outside.png", "%2e%2e/%2e%2e/out.png", "/../out.png", ".git/config", "../.GIT/config", "/%2egit/config", "file:///etc/private", "data:image/png,abc", "javascript:alert(1)", "https://example.invalid/a", "//example.invalid/a", "%2F%2Fexample.invalid/a", "file%3A%2F%2F%2Fprivate", "a\\b.png", "a%5cb.png", "a%00.png", "a\nb.png", "%zz.png"] {
            XCTAssertNil(MarkdownImagePath.resolve(raw, document: "docs/README.md"), raw)
        }
        XCTAssertNil(MarkdownImagePath.resolve("a.png", document: "../README.md"))
    }

    func testRendererRegistersOnlyReferencedImagesAndKeepsRemoteConsentSeparate() async throws {
        let context = MarkdownImageContext(repo: try directory(), source: .worktree("docs/README.md"))
        let markdown = """
        ![first](../images/a.png)
        ![alias](/images/a.png?raw=1)
        ![reference][logo]

        [logo]: ../images/截图%201.png

        <img src="../images/b.png" onerror="evil()" alt="HTML">
        <img src="../images/a&amp;b.png" alt="A &amp; B">

        ![remote](https://example.invalid/remote.png)
        ![outside](../../outside.png)
        ![private](file:///private/image.png)

        ```markdown
        ![code](not-read.png)
        ```
        """
        let document = try await MarkdownRenderer.shared.render(markdown, localContext: context)
        XCTAssertEqual(Set(document.localImages.values), ["images/a.png", "images/截图 1.png", "images/b.png", "images/a&b.png"])
        XCTAssertEqual(document.localImages.count, 4); XCTAssertEqual(document.remoteImages, 1)
        XCTAssertEqual(document.body.components(separatedBy: "<img ").count - 1, 5)
        XCTAssertFalse(document.body.contains("onerror")); XCTAssertFalse(document.body.contains("file:///"))
        XCTAssertFalse(document.body.contains("src=\"https://"))
        XCTAssertTrue(document.html(pointSize: 17, dark: false, imagesAllowed: false).contains("img-src gitling-image:;"))
        let noContext = try await MarkdownRenderer.shared.render("![image](local.png)")
        XCTAssertTrue(noContext.localImages.isEmpty); XCTAssertFalse(noContext.body.contains("<img"))
        let many = try await MarkdownRenderer.shared.render((0..<70).map { "![x](\($0).png)" }.joined(separator: "\n"), localContext: context)
        XCTAssertEqual(many.localImages.count, 64)
    }

    func testWorktreeSnapshotsAreBoundedReusableAndDoNotLeakTemporaryFiles() async throws {
        let repo = try directory(), image = repo.appendingPathComponent("image.png"), store = PreviewCache(root: try directory(), byteBudget: 1024 * 1024)
        try MarkdownImageFixtures.red.write(to: image)
        let first = URL(string: "gitling-image://test/0")!, alias = URL(string: "gitling-image://test/1")!
        let loader = MarkdownImageLoader(context: .init(repo: repo, source: .worktree("README.md")), references: [first.absoluteString: "image.png", alias.absoluteString: "image.png"], cache: store)
        let value = try await loader.load(first, token: PreviewCancellation())
        XCTAssertEqual(MarkdownImageFixtures.width(value), 8); XCTAssertEqual(store.liveBytes, 0)
        try FileManager.default.removeItem(at: image)
        let reused = try await loader.load(alias, token: PreviewCancellation())
        XCTAssertEqual(reused, value)
        do { _ = try await loader.load(URL(string: "gitling-image://test/not-registered")!, token: PreviewCancellation()); XCTFail("Unregistered resource served") } catch {}
        let token = PreviewCancellation(); token.cancel()
        do { _ = try await loader.load(alias, token: token); XCTFail("Cancelled cache read served") } catch is CancellationError {} catch { XCTFail("Unexpected \(error)") }
        try MarkdownImageFixtures.red.write(to: image)
        for (input, output, pixels) in [(1, 1024, 100), (1024, 1, 100), (1024, 1024, 1)] {
            let constrained = MarkdownImageLoader(context: .init(repo: repo, source: .worktree("README.md")), references: [first.absoluteString: "image.png"], cache: store, inputLimit: Int64(input), outputLimit: output, pixelLimit: pixels)
            do { _ = try await constrained.load(first, token: PreviewCancellation()); XCTFail("Budget bypassed") } catch {}
            XCTAssertEqual(store.liveBytes, 0)
        }
    }

    func testSymlinksNonImagesAndLFSRemainPassive() async throws {
        let repo = try directory(), outside = try directory(), store = PreviewCache(root: try directory(), byteBudget: 1024 * 1024)
        try MarkdownImageFixtures.red.write(to: outside.appendingPathComponent("image.png"))
        try FileManager.default.createSymbolicLink(at: repo.appendingPathComponent("link.png"), withDestinationURL: outside.appendingPathComponent("image.png"))
        try FileManager.default.createSymbolicLink(at: repo.appendingPathComponent("linked"), withDestinationURL: outside)
        try Data("not an image".utf8).write(to: repo.appendingPathComponent("fake.png"))
        try Data("<svg><script>evil()</script></svg>".utf8).write(to: repo.appendingPathComponent("diagram.svg"))
        try Data(LFSPointer.make(oid: String(repeating: "a", count: 64), size: 20).raw.utf8).write(to: repo.appendingPathComponent("lfs.png"))
        for path in ["link.png", "linked/image.png", "fake.png", "diagram.svg", "lfs.png", "missing.png"] {
            let url = URL(string: "gitling-image://test/0")!
            let loader = MarkdownImageLoader(context: .init(repo: repo, source: .worktree("README.md")), references: [url.absoluteString: path], cache: store)
            do { _ = try await loader.load(url, token: PreviewCancellation()); XCTFail("Unsafe image served: \(path)") } catch {}
            XCTAssertEqual(store.liveBytes, 0)
        }
    }

    func testHistoricalImagesUseSameFixedCommitAndIgnoreIndexWorktreeAndBookmarks() async throws {
        let fixture = try CommitComparisonFixture(self), store = PreviewCache(root: try directory(), byteBudget: 1024 * 1024)
        let markdown = try fixture.blob("![x](../image.png)")
        let red = try fixture.commit(["docs/README.md": (markdown, 0o100644), "image.png": (try fixture.blob(MarkdownImageFixtures.red), 0o100644)])
        let blue = try fixture.commit(["docs/README.md": (markdown, 0o100644), "image.png": (try fixture.blob(MarkdownImageFixtures.blue), 0o100644)], parents: [red])
        try fixture.reference("refs/heads/main", blue)
        try MarkdownImageFixtures.blue.write(to: fixture.repo.appendingPathComponent("image.png"))
        try Data("broken index".utf8).write(to: fixture.repo.appendingPathComponent(".git/index"))
        try WorktreeLink.save(repoName: fixture.repo.lastPathComponent, data: Data("expired".utf8))
        let before = try fixture.snapshot(), url = URL(string: "gitling-image://test/0")!
        for (commit, width) in [(red, 8), (blue, 3)] {
            let loader = MarkdownImageLoader(context: .init(repo: fixture.repo, source: .blob(oid: commit, path: "docs/README.md")), references: [url.absoluteString: "image.png"], cache: store)
            let data = try await loader.load(url, token: PreviewCancellation())
            XCTAssertEqual(MarkdownImageFixtures.width(data), width); XCTAssertEqual(store.liveBytes, 0)
        }
        XCTAssertEqual(try fixture.snapshot(), before)
    }

    func testLinkedWorktreeUsesExternalImageAndDoesNotFallBackWhenAccessExpires() async throws {
        let root = try directory(), name = "linked-md-" + UUID().uuidString
        try GitClient.initialize(name: name, root: root)
        let repo = root.appendingPathComponent(name), parent = try directory()
        defer { WorktreeLink.remove(repoName: name) }
        try MarkdownImageFixtures.red.write(to: repo.appendingPathComponent("image.png"))
        try GitClient.link(at: repo, bookmark: WorktreeLink.bookmark(for: parent))
        try MarkdownImageFixtures.blue.write(to: parent.appendingPathComponent(name + "/image.png"))
        let url = URL(string: "gitling-image://test/0")!, context = MarkdownImageContext(repo: repo, source: .worktree("README.md"))
        let loader = MarkdownImageLoader(context: context, references: [url.absoluteString: "image.png"])
        let image = try await loader.load(url, token: PreviewCancellation())
        XCTAssertEqual(MarkdownImageFixtures.width(image), 3)
        try MarkdownImageFixtures.red.write(to: repo.appendingPathComponent("image.png"))
        try WorktreeLink.save(repoName: name, data: Data("invalid".utf8))
        let denied = MarkdownImageLoader(context: context, references: [url.absoluteString: "image.png"])
        do { _ = try await denied.load(url, token: PreviewCancellation()); XCTFail("Fell back to internal worktree") } catch {}
    }
}

@MainActor
final class MarkdownRepositoryImageInterfaceTests: XCTestCase {
    func testActualPreviewLoadsWorktreeAndFixedVersionsWithIdenticalMarkdown() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("md-view-" + UUID().uuidString), name = "md-repo-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(at: root); WorktreeLink.remove(repoName: name) }
        try GitClient.initialize(name: name, root: root)
        let repo = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("docs"), withIntermediateDirectories: true)
        let markdown = "# Relative image\n\n![local](../image.png)"
        try markdown.write(to: repo.appendingPathComponent("docs/README.md"), atomically: true, encoding: .utf8)
        try MarkdownImageFixtures.red.write(to: repo.appendingPathComponent("image.png"))
        try GitClient.stageAll(at: repo); try GitClient.commit(at: repo, message: "Red", name: "Fixture", email: "test@example.invalid")
        let first = try GitClient.history(at: repo, limit: 1)[0].id
        try MarkdownImageFixtures.blue.write(to: repo.appendingPathComponent("image.png"))
        try GitClient.stageAll(at: repo); try GitClient.commit(at: repo, message: "Blue", name: "Fixture", email: "test@example.invalid")
        let second = try GitClient.history(at: repo, limit: 1)[0].id
        let index = try Data(contentsOf: repo.appendingPathComponent(".git/index"))
        let host = UIHostingController(rootView: PreviewContentsPage(repo: repo, source: .worktree("docs/README.md")))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 346, height: 640)
        window.rootViewController = host; window.makeKeyAndVisible(); host.view.layoutIfNeeded()
        defer { window.isHidden = true; window.rootViewController = nil }
        func find(_ view: UIView) -> WKWebView? { if let web = view as? WKWebView { return web }; return view.subviews.lazy.compactMap { find($0) }.first }
        func waitForImage(_ width: Int) async throws {
            for _ in 0..<240 {
                if let web = find(host.view), (try? await web.evaluateJavaScript("document.images[0]?.naturalWidth")) as? Int == width { return }
                try await Task.sleep(for: .milliseconds(25))
            }
            XCTFail("Relative image did not load with width \(width)")
        }
        try await waitForImage(3)
        host.rootView = PreviewContentsPage(repo: repo, source: .blob(oid: first, path: "docs/README.md"))
        try await waitForImage(8)
        host.rootView = PreviewContentsPage(repo: repo, source: .blob(oid: second, path: "docs/README.md"))
        try await waitForImage(3)
        for index in 0..<10 {
            host.rootView = PreviewContentsPage(repo: repo, source: .blob(oid: index.isMultiple(of: 2) ? first : second, path: "docs/README.md"))
            await Task.yield()
        }
        host.rootView = PreviewContentsPage(repo: repo, source: .blob(oid: first, path: "docs/README.md"))
        try await waitForImage(8)
        let web = try XCTUnwrap(find(host.view))
        XCTAssertFalse(web.configuration.defaultWebpagePreferences.allowsContentJavaScript)
        let url = try await web.evaluateJavaScript("document.images[0].src") as? String
        XCTAssertTrue(url?.hasPrefix("gitling-image:") == true)
        XCTAssertEqual(try Data(contentsOf: repo.appendingPathComponent(".git/index")), index)
        XCTAssertEqual(try GitClient.history(at: repo, limit: 1)[0].id, second)
        XCTAssertEqual(try Data(contentsOf: repo.appendingPathComponent("image.png")), MarkdownImageFixtures.blue)
    }

    func testStoppedAndReplacedSchemeTasksNeverReceiveLateCallbacks() async throws {
        let handler = MarkdownImageSchemeHandler(), context = MarkdownImageContext(repo: FileManager.default.temporaryDirectory, source: .worktree("README.md"))
        let url = URL(string: "gitling-image://document-test/0")!
        handler.install(context: context, references: [url.absoluteString: "missing.png"])
        let web = WKWebView(), first = SchemeTaskFixture(url), second = SchemeTaskFixture(url)
        handler.webView(web, start: first); handler.webView(web, stop: first)
        handler.webView(web, start: second); handler.install(context: nil, references: [:])
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(first.callbacks, 0); XCTAssertEqual(second.callbacks, 0)
    }
}

private final class SchemeTaskFixture: NSObject, WKURLSchemeTask {
    let request: URLRequest
    private let lock = NSLock()
    private var count = 0
    var callbacks: Int { lock.withLock { count } }
    init(_ url: URL) { request = URLRequest(url: url) }
    func didReceive(_ response: URLResponse) { lock.withLock { count += 1 } }
    func didReceive(_ data: Data) { lock.withLock { count += 1 } }
    func didFinish() { lock.withLock { count += 1 } }
    func didFailWithError(_ error: any Error) { lock.withLock { count += 1 } }
}
