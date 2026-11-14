import Foundation
import WebKit

struct MarkdownImageContext: Hashable, Sendable {
    let repo: URL
    let source: PreviewSource
}

enum MarkdownImagePath {
    /// Resolve URL-path syntax once, relative to the document (or repository
    /// root for /images/a.png). Parent components may never escape that root.
    static func resolve(_ raw: String, document: String) -> String? {
        let source = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty, source.utf8.count <= 8192, !source.hasPrefix("//"),
              !source.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              URLComponents(string: source)?.scheme == nil,
              let base = try? SearchWorktreeAccess.components(document), !base.isEmpty else { return nil }
        let urlPath = String(source.prefix { $0 != "?" && $0 != "#" })
        guard !urlPath.isEmpty, let decoded = urlPath.removingPercentEncoding, !decoded.contains("\\"),
              !decoded.hasPrefix("//"), URLComponents(string: decoded)?.scheme == nil,
              !decoded.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        var parts = decoded.hasPrefix("/") ? [] : Array(base.dropLast())
        for component in decoded.split(separator: "/") {
            let part = String(component)
            if part == "." { continue }
            if part == ".." {
                guard !parts.isEmpty else { return nil }
                parts.removeLast()
            } else {
                guard part.lowercased() != ".git" else { return nil }
                parts.append(part)
            }
        }
        guard !parts.isEmpty else { return nil }
        let result = parts.joined(separator: "/")
        guard (try? SearchWorktreeAccess.components(result)) != nil else { return nil }
        return result
    }
}

/// One document generation, bounded and serial. Images reuse the safe snapshot,
/// image validation and downsampling path; WebKit never gets a worktree URL.
actor MarkdownImageLoader {
    private let context: MarkdownImageContext
    private let references: [String: String]
    private let cache: PreviewCache
    private let inputLimit: Int64
    private let outputLimit: Int
    private let pixelLimit: Int
    private var pixels = 0
    private var inputBytes: Int64 = 0
    private var outputBytes = 0
    private var images: [String: Data] = [:]

    init(context: MarkdownImageContext, references: [String: String], cache: PreviewCache = .shared,
         inputLimit: Int64 = 64 * 1024 * 1024, outputLimit: Int = 32 * 1024 * 1024, pixelLimit: Int = 16 * 1024 * 1024) {
        self.context = context; self.references = references; self.cache = cache
        self.inputLimit = max(0, inputLimit); self.outputLimit = max(0, outputLimit); self.pixelLimit = max(0, pixelLimit)
    }

    func load(_ url: URL, token: PreviewCancellation) throws -> Data {
        try token.check()
        guard references.count <= 64, let path = references[url.absoluteString] else { throw CocoaError(.fileReadNoPermission) }
        if let image = images[path] { return image }
        guard inputBytes < inputLimit, outputBytes < outputLimit, pixels < pixelLimit else { throw CocoaError(.fileReadTooLarge) }
        var budget = PreviewBudget.standard
        budget.fileBytes = min(budget.fileBytes, inputLimit - inputBytes)
        let result = try PreviewCoordinator.shared.run {
            try token.check()
            switch context.source {
            case .worktree:
                return try GitClient.previewWorktree(at: context.repo, path: path, budget: budget, cache: cache, token: token)
            case .blob(let oid, _):
                return try GitClient.previewRevision(at: context.repo, commit: oid, path: path, budget: budget, cache: cache, token: token)
            }
        }
        defer { result.close() }
        try token.check()
        if result.descriptor.byteCount > 0, result.descriptor.byteCount <= inputLimit - inputBytes { inputBytes += result.descriptor.byteCount }
        guard result.descriptor.kind == .image, result.descriptor.status == .ready, let image = result.thumbnail else { throw CocoaError(.fileReadCorruptFile) }
        let width = result.descriptor.displayedWidth ?? 0, height = result.descriptor.displayedHeight ?? 0
        let area = width.multipliedReportingOverflow(by: height)
        guard width > 0, height > 0, !area.overflow, area.partialValue <= pixelLimit - pixels,
              image.count <= outputLimit - outputBytes else { throw CocoaError(.fileReadTooLarge) }
        images[path] = image; outputBytes += image.count; pixels += area.partialValue
        return image
    }
}

/// WebKit callbacks are serialized on the UI actor. Stopped or obsolete scheme
/// tasks are removed before cancellation so late reads never call into WebKit.
@MainActor
final class MarkdownImageSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "gitling-image"
    private var loader: MarkdownImageLoader?
    private var pending: [ObjectIdentifier: Request] = [:]
    private struct Request {
        let id: UUID
        let token: PreviewCancellation
        let work: Task<Void, Never>
    }

    func install(context: MarkdownImageContext?, references: [String: String]) {
        cancelAll()
        loader = context.map { MarkdownImageLoader(context: $0, references: references) }
    }

    func cancelAll() {
        let requests = pending.values
        pending.removeAll(); loader = nil
        for request in requests { request.token.cancel(); request.work.cancel() }
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let loader, let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(CocoaError(.fileReadNoPermission)); return
        }
        let key = ObjectIdentifier(urlSchemeTask), id = UUID(), token = PreviewCancellation()
        let work = Task { @MainActor [weak self] in
            do {
                let image = try await loader.load(url, token: token)
                guard let self, self.pending[key]?.id == id, !Task.isCancelled else { return }
                self.pending.removeValue(forKey: key)
                urlSchemeTask.didReceive(URLResponse(url: url, mimeType: "image/png", expectedContentLength: image.count, textEncodingName: nil))
                urlSchemeTask.didReceive(image)
                urlSchemeTask.didFinish()
            } catch {
                guard let self, self.pending[key]?.id == id, !Task.isCancelled else { return }
                self.pending.removeValue(forKey: key)
                urlSchemeTask.didFailWithError(CocoaError(.fileReadUnknown))
            }
        }
        pending[key] = Request(id: id, token: token, work: work)
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        let request = pending.removeValue(forKey: ObjectIdentifier(urlSchemeTask))
        request?.token.cancel(); request?.work.cancel()
    }
}
