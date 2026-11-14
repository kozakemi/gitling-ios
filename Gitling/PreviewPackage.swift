import AVFoundation
import Foundation
import QuickLook

/// Office, iWork, RTF, and media classification. The extension is only a hint.
/// Ordinary ZIPs are left to the directory-only reader; they are never extracted.
struct PreviewPackageMatch: Equatable, Sendable {
    var kind: PreviewKind
    /// Controlled snapshot suffix. Nil means the container was recognized but
    /// not specifically enough to hand to a previewer.
    var suffix: String?
    var typeIdentifier: String?
}

enum PreviewPackage {
    static func match(sample: Data, path: String) -> PreviewPackageMatch? {
        let ext = (path as NSString).pathExtension.lowercased()
        let body = sample.starts(with: [0xEF, 0xBB, 0xBF]) ? Data(sample.dropFirst(3)) : sample
        if body.starts(with: Data("{\\rtf".utf8)) {
            return PreviewPackageMatch(kind: .document, suffix: "rtf", typeIdentifier: UTType.rtf.identifier)
        }
        if sample.starts(with: [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]) {
            switch ext {
            case "doc", "dot":
                return PreviewPackageMatch(kind: .document, suffix: "doc", typeIdentifier: "com.microsoft.word.doc")
            case "xls", "xlt":
                return PreviewPackageMatch(kind: .document, suffix: "xls", typeIdentifier: "com.microsoft.excel.xls")
            case "ppt", "pot":
                return PreviewPackageMatch(kind: .document, suffix: "ppt", typeIdentifier: "com.microsoft.powerpoint.ppt")
            default:
                return PreviewPackageMatch(kind: .document, suffix: nil, typeIdentifier: nil)
            }
        }
        if sample.starts(with: [0x50, 0x4B, 0x03, 0x04]) || sample.starts(with: [0x50, 0x4B, 0x05, 0x06]) {
            guard let archive = try? PreviewArchive.index(data: sample) else { return nil }
            return match(archive: archive, path: path)
        }
        if sample.starts(with: Data("ID3".utf8)) {
            return PreviewPackageMatch(kind: .audio, suffix: "mp3", typeIdentifier: UTType.mp3.identifier)
        }
        if sample.count >= 12, sample.prefix(4) == Data("RIFF".utf8), sample.subdata(in: 8..<12) == Data("WAVE".utf8) {
            return PreviewPackageMatch(kind: .audio, suffix: "wav", typeIdentifier: UTType.wav.identifier)
        }
        if sample.count >= 12, sample.prefix(4) == Data("FORM".utf8) {
            let kind = sample.subdata(in: 8..<12)
            if kind == Data("AIFF".utf8) || kind == Data("AIFC".utf8) {
                return PreviewPackageMatch(kind: .audio, suffix: "aiff", typeIdentifier: UTType.aiff.identifier)
            }
        }
        if sample.starts(with: Data("caff".utf8)) {
            return PreviewPackageMatch(kind: .audio, suffix: "caf", typeIdentifier: UTType(filenameExtension: "caf")?.identifier)
        }
        if let movie = movie(sample, extension: ext) { return movie }
        return nil
    }

    private static func movie(_ data: Data, extension ext: String) -> PreviewPackageMatch? {
        guard data.count >= 12, data.subdata(in: 4..<8) == Data("ftyp".utf8) else { return nil }
        let brand = String(data: data.subdata(in: 8..<12), encoding: .ascii) ?? ""
        let imageBrands: Set<String> = ["heic", "heix", "hevc", "heif", "mif1", "msf1", "avif", "avis", "heim", "heis"]
        if imageBrands.contains(brand) { return nil }
        let audioBrands: Set<String> = ["M4A ", "M4B ", "M4P "]
        if audioBrands.contains(brand) || ext == "m4a" || ext == "aac" {
            return PreviewPackageMatch(kind: .audio, suffix: "m4a", typeIdentifier: UTType.mpeg4Audio.identifier)
        }
        let videoBrands: Set<String> = ["mp41", "mp42", "isom", "iso2", "avc1", "M4V ", "qt  ", "3gp4", "3gp5", "3gp6"]
        if videoBrands.contains(brand) || ext == "mp4" || ext == "mov" || ext == "m4v" {
            let suffix = brand == "qt  " || ext == "mov" ? "mov" : "mp4"
            let type = suffix == "mov" ? UTType.quickTimeMovie.identifier : UTType.mpeg4Movie.identifier
            return PreviewPackageMatch(kind: .video, suffix: suffix, typeIdentifier: type)
        }
        return nil
    }

    static func match(archive: PreviewArchiveIndex, path: String) -> PreviewPackageMatch? {
        guard !archive.truncated, !archive.entries.contains(where: { $0.encrypted || $0.unsafePath }) else { return nil }
        let names = Set(archive.entries.map(\.path))
        if names.contains("[Content_Types].xml") {
            for (name, suffix, identifier) in [
                ("word/document.xml", "docx", "org.openxmlformats.wordprocessingml.document"),
                ("xl/workbook.xml", "xlsx", "org.openxmlformats.spreadsheetml.sheet"),
                ("ppt/presentation.xml", "pptx", "org.openxmlformats.presentationml.presentation")
            ] where names.contains(name) {
                return .init(kind: .document, suffix: suffix, typeIdentifier: identifier)
            }
        }
        if names.contains(where: { $0.hasPrefix("Index/") && $0.hasSuffix(".iwa") }) {
            switch (path as NSString).pathExtension.lowercased() {
            case "pages": return .init(kind: .document, suffix: "pages", typeIdentifier: "com.apple.iwork.pages.pages")
            case "numbers": return .init(kind: .document, suffix: "numbers", typeIdentifier: "com.apple.iwork.numbers.numbers")
            case "key", "keynote": return .init(kind: .document, suffix: "key", typeIdentifier: "com.apple.iwork.keynote.key")
            default: return nil
            }
        }
        return nil
    }

}

struct PreviewSystemSupport: Sendable {
    var canPreview: @Sendable (URL) -> Bool
    var canPlay: @Sendable (URL) -> Bool

    static let live = PreviewSystemSupport(
        canPreview: { PreviewQuickLook.canPreview($0) },
        canPlay: { PreviewPlayback.canPlay($0) }
    )
}

final class PreviewFileItem: NSObject, QLPreviewItem, @unchecked Sendable {
    let url: URL
    init(url: URL) { self.url = url }
    var previewItemURL: URL? { url }
    var previewItemTitle: String? { nil }
}

enum PreviewQuickLook {
    /// Quick Look decides from the snapshot URL, never from the worktree file.
    static func canPreview(_ url: URL) -> Bool {
        let item = PreviewFileItem(url: url)
        if Thread.isMainThread { return QLPreviewController.canPreview(item) }
        return DispatchQueue.main.sync { QLPreviewController.canPreview(item) }
    }
}

enum PreviewPlayback {
    static func asset(_ url: URL) -> AVURLAsset {
        AVURLAsset(url: url, options: [AVURLAssetReferenceRestrictionsKey: NSNumber(value: AVAssetReferenceRestrictions.forbidAll.rawValue)])
    }
    /// Asks the system whether the snapshot can be played. Does not start playback.
    static func canPlay(_ url: URL, timeout: TimeInterval = 5) -> Bool {
        let asset = asset(url)
        let ready = DispatchSemaphore(value: 0)
        let result = Probe()
        let task = Task.detached(priority: .userInitiated) {
            let playable = (try? await asset.load(.isPlayable)) ?? false
            result.set(playable)
            ready.signal()
        }
        guard ready.wait(timeout: .now() + max(0, timeout)) == .success else {
            task.cancel()
            asset.cancelLoading()
            return false
        }
        return result.get()
    }
    private final class Probe: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set(_ value: Bool) { lock.withLock { self.value = value } }
        func get() -> Bool { lock.withLock { value } }
    }
}
