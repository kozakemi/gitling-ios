import Foundation
import JavaScriptCore
import SwiftUI
import WebKit

struct MarkdownDocument: Sendable {
    let body: String
    let remoteImages: Int
    var localImages: [String: String] = [:]

    func html(pointSize: Double, dark: Bool, imagesAllowed: Bool) -> String {
        let sources = (localImages.isEmpty ? [] : ["gitling-image:"]) + (imagesAllowed ? ["https:", "http:"] : [])
        let imagePolicy = sources.isEmpty ? "'none'" : sources.joined(separator: " ")
        let size = min(96, max(12, pointSize))
        let foreground = dark ? "#e6edf3" : "#1f2328"
        let background = dark ? "#0d1117" : "#ffffff"
        let muted = dark ? "#9198a1" : "#59636e"
        let border = dark ? "#3d444d" : "#d1d9e0"
        let panel = dark ? "#151b23" : "#f6f8fa"
        let link = dark ? "#4493f8" : "#0969da"
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <meta name="referrer" content="no-referrer">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'none'; style-src 'unsafe-inline'; img-src \(imagePolicy); connect-src 'none'; media-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'">
        <style>
        :root { color-scheme: \(dark ? "dark" : "light"); }
        * { box-sizing: border-box; }
        body { margin: 0; padding: 16px; background: \(background); color: \(foreground); font: \(size)px/1.5 -apple-system, BlinkMacSystemFont, sans-serif; overflow-wrap: break-word; -webkit-text-size-adjust: 100%; }
        main { max-width: 1012px; margin: auto; }
        main > :first-child { margin-top: 0 !important; }
        p, ul, ol, blockquote, table, pre, details, .code-block { margin: 0 0 16px; }
        h1,h2,h3,h4,h5,h6 { margin: 24px 0 16px; font-weight: 600; line-height: 1.25; }
        h1 { font-size: 2em; } h2 { font-size: 1.5em; } h3 { font-size: 1.25em; } h4 { font-size: 1em; } h5 { font-size: .875em; } h6 { font-size: .85em; color: \(muted); }
        h1,h2 { padding-bottom: .3em; border-bottom: 1px solid \(border); }
        a,.markdown-link { color: \(link); text-decoration: none; } a:hover { text-decoration: underline; }
        ul,ol { padding-left: 2em; } li+li { margin-top: .25em; } li>p { margin: 8px 0; } li>ul,li>ol { margin-bottom: 0; }
        input[type=checkbox] { pointer-events: none; margin: 0 .5em 0 -1.3em; accent-color: \(link); } li:has(>input[type=checkbox]) { list-style: none; }
        blockquote { padding: 0 1em; border-left: .25em solid \(border); color: \(muted); } blockquote>:last-child { margin-bottom: 0; }
        code,pre,kbd { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
        code { padding: .2em .4em; background: \(panel); border-radius: 6px; font-size: .85em; }
        pre { padding: 16px; overflow: auto; background: \(panel); border-radius: 6px; line-height: 1.45; overflow-wrap: normal; }
        pre code { padding: 0; background: transparent; white-space: pre; font-size: .85em; }
        .code-language { color: \(muted); font-size: .75em; padding: 6px 12px; background: \(panel); border-bottom: 1px solid \(border); border-radius: 6px 6px 0 0; }
        .code-block pre { margin: 0; } .code-block:has(.code-language) pre { border-radius: 0 0 6px 6px; }
        .syntax-keyword { color: \(dark ? "#ff7b72" : "#cf222e"); } .syntax-string { color: \(dark ? "#a5d6ff" : "#0a3069"); } .syntax-comment { color: \(muted); } .syntax-number { color: \(link); }
        .table-scroll { overflow-x: auto; margin-bottom: 16px; } table { border-spacing: 0; border-collapse: collapse; min-width: max-content; margin-bottom: 0; }
        th,td { padding: 6px 13px; border: 1px solid \(border); } th { font-weight: 600; } tr:nth-child(2n) { background: \(panel); }
        hr { height: 4px; padding: 0; margin: 24px 0; background: \(border); border: 0; }
        kbd { padding: 3px 5px; font-size: .75em; border: 1px solid \(border); border-radius: 6px; box-shadow: inset 0 -1px 0 \(border); }
        details { padding: 8px 0; } summary { cursor: pointer; font-weight: 600; }
        img { max-width: 100%; height: auto; } .image-placeholder { display: inline-block; color: \(muted); border: 1px dashed \(border); padding: 4px 8px; border-radius: 6px; }
        .align-center { text-align: center; } .align-right { text-align: right; } .align-left { text-align: left; }
        .markdown-alert { padding: 8px 16px; margin-bottom: 16px; border-left: .25em solid \(link); } .alert-title { color: \(link); font-weight: 600; margin-bottom: 8px; }
        .alert-tip { border-color: #1a7f37; } .alert-tip .alert-title { color: #1a7f37; } .alert-warning { border-color: #9a6700; } .alert-warning .alert-title { color: #9a6700; } .alert-important { border-color: #8250df; } .alert-important .alert-title { color: #8250df; } .alert-caution { border-color: #cf222e; } .alert-caution .alert-title { color: #cf222e; }
        .markdown-alert>:last-child { margin-bottom: 0; } .footnotes { font-size: .875em; color: \(muted); border-top: 1px solid \(border); padding-top: 16px; } .sr-only { position: absolute; width: 1px; height: 1px; overflow: hidden; clip-path: inset(50%); }
        </style></head><body><main>\(body)</main></body></html>
        """
    }
}

/// A dedicated actor keeps JavaScriptCore parsing off the UI and serial. The
/// bundled parser has no DOM, network, filesystem or repository APIs.
actor MarkdownRenderer {
    static let shared = MarkdownRenderer()

    func render(_ source: String, imagesAllowed: Bool = false, localContext: MarkdownImageContext? = nil) throws -> MarkdownDocument {
        try Task.checkCancellation()
        guard source.utf8.count <= FileInspection.maximumBytes else { throw CocoaError(.fileReadTooLarge) }
        guard let context = JSContext() else { throw CocoaError(.coderInvalidValue) }
        let remote: @convention(block) (String) -> String? = { MarkdownRenderer.remoteURL($0) }
        let highlight: @convention(block) (String, String) -> String = { MarkdownRenderer.highlight($0, language: $1) }
        let namespace = UUID().uuidString.lowercased()
        var localImages: [String: String] = [:]
        var urlsByPath: [String: String] = [:]
        let local: @convention(block) (String) -> String? = { raw in
            guard let localContext, let path = MarkdownImagePath.resolve(raw, document: localContext.source.path) else { return nil }
            if let existing = urlsByPath[path] { return existing }
            guard localImages.count < 64 else { return nil }
            let url = "gitling-image://document-" + namespace + "/" + String(localImages.count)
            localImages[url] = path; urlsByPath[path] = url
            return url
        }
        context.setObject(local, forKeyedSubscript: "gitlingLocalImageURL" as NSString)
        context.setObject(remote, forKeyedSubscript: "gitlingRemoteURL" as NSString)
        context.setObject(highlight, forKeyedSubscript: "gitlingHighlight" as NSString)
        for name in ["marked.bundle", "marked-footnote.bundle", "renderer.js"] {
            guard let url = Bundle.main.url(forResource: name, withExtension: "txt") else { throw CocoaError(.fileNoSuchFile) }
            context.evaluateScript(try String(contentsOf: url, encoding: .utf8))
            guard context.exception == nil else { throw CocoaError(.coderInvalidValue) }
        }
        guard let value = context.objectForKeyedSubscript("gitlingMarkdown")?.call(withArguments: [source, imagesAllowed]), context.exception == nil,
              let body = value.forProperty("body")?.toString() else { throw CocoaError(.coderInvalidValue) }
        try Task.checkCancellation()
        return MarkdownDocument(body: body, remoteImages: Int(value.forProperty("remoteImages")?.toInt32() ?? 0), localImages: localImages)
    }

    nonisolated static func remoteURL(_ raw: String) -> String? {
        guard raw.utf8.count <= 8192, !raw.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        let text = raw.hasPrefix("//") ? "https:" + raw : raw
        guard let parts = URLComponents(string: text), ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil else { return nil }
        return parts.url?.absoluteString
    }

    nonisolated static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    nonisolated static func highlight(_ text: String, language: String) -> String {
        let extensions = ["swift": "swift", "c": "c", "cpp": "cpp", "c++": "cpp", "objc": "m", "objective-c": "m", "python": "py", "py": "py", "javascript": "js", "js": "js", "typescript": "ts", "ts": "ts", "json": "json", "sh": "sh", "bash": "sh", "zsh": "sh", "java": "java", "kotlin": "kt", "kt": "kt", "rust": "rs", "rs": "rs", "go": "go"]
        guard let ext = extensions[language.lowercased()] else { return escape(text) }
        let source = text as NSString
        var result = "", offset = 0
        for span in SyntaxHighlighter.spans(in: text, path: "code." + ext) {
            guard span.location >= offset, span.location + span.length <= source.length else { continue }
            result += escape(source.substring(with: NSRange(location: offset, length: span.location - offset)))
            let kind: String
            switch span.kind { case .keyword: kind = "keyword"; case .string: kind = "string"; case .comment: kind = "comment"; case .number: kind = "number" }
            result += "<span class=\"syntax-\(kind)\">" + escape(source.substring(with: NSRange(location: span.location, length: span.length))) + "</span>"
            offset = span.location + span.length
        }
        return result + escape(source.substring(from: offset))
    }
}

struct PreviewMarkdownView: View {
    let markdown: String
    var localContext: MarkdownImageContext? = nil
    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .body) private var pointSize = 17.0
    @State private var remoteImages = 0
    @State private var approvedSource: String?

    var body: some View {
        VStack(spacing: 0) {
            if remoteImages > 0 {
                Button {
                    approvedSource = approvedSource == markdown ? nil : markdown
                } label: {
                    if approvedSource == markdown { Text("Block remote images") }
                    else { Text(String(format: String(localized: "%lld remote images · Tap to load"), remoteImages)) }
                }
                .font(.footnote)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal).padding(.vertical, 8)
                .accessibilityIdentifier("file.preview.markdown.remote-images")
            }
            MarkdownWebPreview(markdown: markdown, pointSize: pointSize, dark: colorScheme == .dark, imagesAllowed: approvedSource == markdown, localContext: localContext) {
                remoteImages = $0
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: markdown) { _, _ in approvedSource = nil; remoteImages = 0 }
    }
}

struct MarkdownWebPreview: UIViewRepresentable {
    let markdown: String
    let pointSize: Double
    let dark: Bool
    let imagesAllowed: Bool
    var localContext: MarkdownImageContext? = nil
    var discoveredImages: (Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(context.coordinator.images, forURLScheme: MarkdownImageSchemeHandler.scheme)
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.isOpaque = false
        view.backgroundColor = .clear
        view.accessibilityIdentifier = "file.preview.markdown"
        view.allowsLinkPreview = false
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) {
        let key = Key(source: markdown, size: pointSize, dark: dark, images: imagesAllowed, context: localContext)
        guard context.coordinator.key != key else { return }
        let coordinator = context.coordinator
        coordinator.key = key
        coordinator.task?.cancel()
        coordinator.images.cancelAll()
        // Revoke an old document's image requests before parsing its replacement.
        view.stopLoading()
        view.loadHTMLString("<html><body></body></html>", baseURL: nil)
        coordinator.task = Task { @MainActor [weak view, weak coordinator] in
            let document: MarkdownDocument
            do { document = try await MarkdownRenderer.shared.render(key.source, imagesAllowed: key.images, localContext: key.context) }
            catch is CancellationError { return }
            catch { document = MarkdownDocument(body: "<pre>" + MarkdownRenderer.escape(key.source) + "</pre>", remoteImages: 0) }
            guard !Task.isCancelled, let view, let coordinator, coordinator.key == key else { return }
            coordinator.images.install(context: key.context, references: document.localImages)
            discoveredImages(document.remoteImages)
            view.loadHTMLString(document.html(pointSize: key.size, dark: key.dark, imagesAllowed: key.images), baseURL: nil)
        }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: WKWebView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 320, height: proposal.height ?? 400)
    }
    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        coordinator.task?.cancel(); coordinator.key = nil
        coordinator.images.cancelAll()
        view.stopLoading(); view.navigationDelegate = nil
        view.loadHTMLString("<html><body></body></html>", baseURL: nil)
    }
    struct Key: Equatable { var source: String; var size: Double; var dark: Bool; var images: Bool; var context: MarkdownImageContext? }
    final class Coordinator: NSObject, WKNavigationDelegate {
        let images = MarkdownImageSchemeHandler()
        var key: Key?
        var task: Task<Void, Never>?
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // Only the locally generated document and its footnote anchors navigate.
            let url = action.request.url
            decisionHandler(url?.scheme == "about" && action.targetFrame?.isMainFrame == true ? .allow : .cancel)
        }
    }
}
