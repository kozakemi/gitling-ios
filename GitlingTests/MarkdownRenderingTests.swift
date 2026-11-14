import SwiftUI
import UIKit
import WebKit
import Network
import XCTest
@testable import Gitling

final class MarkdownRenderingTests: XCTestCase {
    func testGFMBlocksInlineStylesAndFootnotes() async throws {
        let source = """
        # Heading

        Setext
        ------

        **bold** *italic* ~~deleted~~ `inline` [link](https://example.invalid)

        - first
          - nested
        - [x] done
        - [ ] pending

        3. third
        4. fourth

        > quoted

        ---

        | Left | Right |
        | :--- | ---: |
        | A | B |

        ```swift
        let title = "<script>"
        // comment
        ```

        note[^sample]

        [^sample]: Footnote text
        """
        let result = try await MarkdownRenderer.shared.render(source)
        for fragment in ["<h1>", "<h2>", "<strong>bold</strong>", "<em>italic</em>", "<del>deleted</del>", "<code>inline</code>", "<ul>", "<ol start=\"3\">", "type=\"checkbox\"", "checked", "disabled", "<blockquote>", "<hr>", "<table>", "align=\"right\"", "syntax-keyword", "syntax-string", "Footnote text", "footnotes"] {
            XCTAssertTrue(result.body.contains(fragment), "Missing \(fragment): \(result.body)")
        }
        XCTAssertFalse(result.body.contains("<script>"))
        XCTAssertFalse(result.body.contains("href=\"https://"))
        XCTAssertEqual(result.remoteImages, 0)
    }

    func testRemoteImagesRequireExplicitApprovalAndKeepUnsafeResourcesBlocked() async throws {
        let source = """
        ![remote](https://example.invalid/a.png)
        ![second](//example.invalid/b.png)
        ![local](../private.png)
        ![unsafe](javascript:alert)
        ![credentials](https://name:secret@example.invalid/image.png)
        <img src="https://example.invalid/html.png" onerror="alert(1)" alt="HTML">
        <script>alert(1)</script><iframe src="https://example.invalid/frame"></iframe>
        <style>body{display:none}</style><form action="https://example.invalid/post"><input></form>
        <p style="display:none" onclick="alert(1)">safe</p>
        <a href="file:///private">link</a>
        """
        let blocked = try await MarkdownRenderer.shared.render(source)
        XCTAssertEqual(blocked.remoteImages, 3)
        XCTAssertFalse(blocked.body.contains("<img"))
        let allowed = try await MarkdownRenderer.shared.render(source, imagesAllowed: true)
        XCTAssertEqual(allowed.remoteImages, 3)
        XCTAssertEqual(allowed.body.components(separatedBy: "<img ").count - 1, 3)
        for bad in ["onerror", "onclick", "<script", "<iframe", "<style", "<form", "<input", "javascript:", "secret", "file:", "../private"] {
            XCTAssertFalse(allowed.body.contains(bad), bad)
        }
        XCTAssertTrue(allowed.body.contains("referrerpolicy=\"no-referrer\""))
        XCTAssertTrue(blocked.html(pointSize: 17, dark: false, imagesAllowed: false).contains("img-src 'none'"))
        XCTAssertTrue(allowed.html(pointSize: 17, dark: true, imagesAllowed: true).contains("script-src 'none'"))
        XCTAssertNil(MarkdownRenderer.remoteURL("https://name:pass@example.invalid/a"))
        XCTAssertNil(MarkdownRenderer.remoteURL("data:image/png;base64,AA"))
    }

    func testAlertsSafeHTMLAndCodeCannotChangeDocumentPolicy() async throws {
        let source = """
        > [!WARNING]
        > Be **careful**.

        note[^combined]

        [^combined]: Footnote after alert

        <details open><summary>Summary</summary><kbd>Cmd</kbd><sup>2</sup></details>

        ```html
        <img src="https://example.invalid/code.png"><script>evil()</script>
        ```

        <meta http-equiv="refresh" content="0;url=https://example.invalid"><link rel="stylesheet" href="https://example.invalid/a.css">
        """
        let rendered = try await MarkdownRenderer.shared.render(source)
        XCTAssertTrue(rendered.body.contains("alert-warning"))
        XCTAssertTrue(rendered.body.contains("Footnote after alert"))
        XCTAssertTrue(rendered.body.contains("<strong>careful</strong>"))
        XCTAssertTrue(rendered.body.contains("<details open>"))
        XCTAssertTrue(rendered.body.contains("<kbd>Cmd</kbd>"))
        XCTAssertEqual(rendered.remoteImages, 0)
        XCTAssertTrue(rendered.body.contains("&lt;img"))
        XCTAssertFalse(rendered.body.contains("<meta")); XCTAssertFalse(rendered.body.contains("<link"))
        let maliciousLabel = try await MarkdownRenderer.shared.render("note[^x\" onclick=\"evil]\n\n[^x\" onclick=\"evil]: Content")
        XCTAssertFalse(maliciousLabel.body.contains("onclick=\"evil"))
    }

    func testDocumentBudgetAndCancellation() async throws {
        do { _ = try await MarkdownRenderer.shared.render(String(repeating: "x", count: FileInspection.maximumBytes + 1)); XCTFail("Oversized document accepted") } catch {}
        let task = Task { try Task.checkCancellation(); return try await MarkdownRenderer.shared.render("# Cancelled") }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancellation ignored") } catch is CancellationError {} catch { XCTFail("Unexpected \(error)") }
        let start = Date()
        let result = try await MarkdownRenderer.shared.render(String(repeating: "- **item** `code`\n", count: 2000))
        XCTAssertTrue(result.body.contains("<ul>"))
        print("MARKDOWN_PERF 2000 items: \(Date().timeIntervalSince(start)) seconds")
    }
}

@MainActor
final class SourceLineNumberTests: XCTestCase {
    func testLogicalLineStartsIncludeCRLFUnicodeAndTrailingEmptyLine() {
        XCTAssertEqual(NumberedSourceTextView.starts(in: ""), [0])
        XCTAssertEqual(NumberedSourceTextView.starts(in: "😀first\r\nsecond\rthird\n"), [0, 9, 16, 22])
        XCTAssertEqual(NumberedSourceTextView.starts(in: "一\u{2028}二\u{2029}"), [0, 2, 4])
    }

    func testGutterTogglePreservesTextSelectionAndSyntaxAttributes() throws {
        let text = "let title = \"😀\"\n" + String(repeating: "wrapped text ", count: 40) + "\n"
        let host = UIHostingController(rootView: SourceTextView(text: text, spans: SyntaxHighlighter.spans(in: text, path: "code.swift"), lineNumbers: true))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 240, height: 400))
        window.rootViewController = host; window.makeKeyAndVisible(); host.view.layoutIfNeeded()
        defer { window.isHidden = true; window.rootViewController = nil }
        func find(_ view: UIView) -> NumberedSourceTextView? { if let view = view as? NumberedSourceTextView { return view }; return view.subviews.lazy.compactMap { find($0) }.first }
        let view = try XCTUnwrap(find(host.view))
        XCTAssertTrue(view.showsLineNumbers); XCTAssertEqual(view.lineStarts.count, 3)
        let attributed = view.attributedText!.copy() as! NSAttributedString
        view.selectedRange = NSRange(location: 0, length: 3)
        let width = view.textContainerInset.left
        view.configureLineNumbers(false, pointSize: 17)
        XCTAssertFalse(view.showsLineNumbers); XCTAssertLessThan(view.textContainerInset.left, width)
        XCTAssertEqual(view.text, text); XCTAssertEqual(view.attributedText, attributed)
        XCTAssertEqual(view.selectedRange, NSRange(location: 0, length: 3))
        view.configureLineNumbers(true, pointSize: 40)
        view.layoutIfNeeded(); view.draw(view.bounds)
        XCTAssertEqual(view.text, text); XCTAssertEqual(view.lineStarts.count, 3)
    }

    func testWebPreviewDoesNotRequestImagesUntilAllowedAndDropsOldDocument() async throws {
        let server = try MarkdownImageServer()
        defer { server.stop() }
        let source = "# Image consent\n\n![fixture](\(server.url))"
        let host = UIHostingController(rootView: MarkdownWebPreview(markdown: source, pointSize: 17, dark: false, imagesAllowed: false, discoveredImages: { _ in }))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 346, height: 640)
        window.rootViewController = host; window.makeKeyAndVisible(); host.view.layoutIfNeeded()
        defer { window.isHidden = true; window.rootViewController = nil }
        func find(_ view: UIView) -> WKWebView? { if let view = view as? WKWebView { return view }; return view.subviews.lazy.compactMap { find($0) }.first }
        let web = try XCTUnwrap(find(host.view))
        func text() async -> String { (try? await web.evaluateJavaScript("document.querySelector('h1')?.textContent")) as? String ?? "" }
        for _ in 0..<200 { if await text() == "Image consent" { break }; try await Task.sleep(for: .milliseconds(25)) }
        let title = await text(); XCTAssertEqual(title, "Image consent")
        XCTAssertEqual(server.requests.count, 0)
        host.rootView = MarkdownWebPreview(markdown: source, pointSize: 17, dark: false, imagesAllowed: true, discoveredImages: { _ in })
        for _ in 0..<200 { if server.requests.count > 0 { break }; try await Task.sleep(for: .milliseconds(25)) }
        if server.requests.isEmpty {
            let diagnostic = try? await web.evaluateJavaScript("JSON.stringify({html:document.body.innerHTML, images:Array.from(document.images).map(i=>({src:i.src,complete:i.complete,width:i.naturalWidth,rect:i.getBoundingClientRect().toJSON()})),h:innerHeight})")
            print("MARKDOWN_IMAGE_DIAGNOSTIC \(String(describing: diagnostic)) frame=\(web.frame)")
        }
        XCTAssertEqual(server.requests.count, 1)
        let request = try XCTUnwrap(server.requests.first).lowercased()
        XCTAssertFalse(request.contains("authorization:")); XCTAssertFalse(request.contains("referer:")); XCTAssertFalse(request.contains("cookie:"))
        var loaded = false
        for _ in 0..<200 {
            loaded = (try? await web.evaluateJavaScript("Boolean(document.querySelector('img')?.naturalWidth)")) as? Bool ?? false
            if loaded { break }; try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertTrue(loaded)
        host.rootView = MarkdownWebPreview(markdown: "# New document\n\n![fixture](\(server.url)?new)", pointSize: 17, dark: true, imagesAllowed: false, discoveredImages: { _ in })
        for _ in 0..<200 { if await text() == "New document" { break }; try await Task.sleep(for: .milliseconds(25)) }
        let images = try await web.evaluateJavaScript("document.images.length") as? Int
        XCTAssertEqual(images, 0); XCTAssertEqual(server.requests.count, 1)
        let csp = try await web.evaluateJavaScript("document.querySelector('meta[http-equiv]').content") as? String
        XCTAssertTrue(csp?.contains("img-src 'none'") == true)
    }

    func testMarkdownDefaultsToRenderedOnEveryNewPreview() {
        let model = WorkspacePreviewModel()
        XCTAssertEqual(model.markdownMode, .rendered)
        model.markdownMode = .source
        _ = model.begin()
        XCTAssertEqual(model.markdownMode, .rendered)
        model.markdownMode = .source
        model.cancel()
        XCTAssertEqual(model.markdownMode, .rendered)
    }
}

/// Loopback PNG endpoint counts requests, without any Git server traffic.
private final class MarkdownImageServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "GitlingTests.markdown-images", qos: .userInitiated)
    private let listener: NWListener
    private var connections: [NWConnection] = []
    private var headers: [String] = []
    private(set) var port: UInt16 = 0
    var url: String { "http://127.0.0.1:\(port)/pixel.png" }
    var requests: [String] { queue.sync { headers } }
    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in if case .ready = state { ready.signal() }; if case .failed = state { ready.signal() } }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.connections.append(connection); connection.start(queue: self.queue)
            self.receive(connection, data: Data())
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success, let bound = listener.port, bound.rawValue > 0 else { listener.cancel(); throw CocoaError(.fileReadUnknown) }
        port = bound.rawValue

    }
    func stop() { queue.sync { listener.cancel(); connections.forEach { $0.cancel() }; connections.removeAll() } }
    private func receive(_ connection: NWConnection, data: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] next, _, done, error in
            guard let self else { connection.cancel(); return }
            var data = data; if let next { data.append(next) }
            guard data.count <= 16384, error == nil else { connection.cancel(); return }
            if data.range(of: Data("\r\n\r\n".utf8)) != nil {
                self.headers.append(String(decoding: data, as: UTF8.self))
                let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGNQ6AgAAAHEAPl61O9hAAAAAElFTkSuQmCC")!
                let header = "HTTP/1.1 200 OK\r\nContent-Type: image/png\r\nContent-Length: \(png.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
                connection.send(content: Data(header.utf8) + png, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
            } else if done { connection.cancel() } else { self.receive(connection, data: data) }
        }
    }
}
