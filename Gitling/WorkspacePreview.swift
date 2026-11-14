import Combine
import CoreGraphics
import Darwin
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// Read-only preview budgets shared by worktree and fixed-commit previews.
///
/// These are starting limits for what this process will copy or ask Image I/O to
/// expand. They are not a guarantee of peak decoder memory, CPU, or time.
/// Text preview keeps its own 256 KiB ceiling. Archive directory metadata has
/// a separate bounded reader. Markdown rendering stays local.
struct PreviewBudget: Equatable, Sendable {
    var textBytes: Int64 = 256 * 1024
    var fileBytes: Int64 = 32 * 1024 * 1024
    var cacheBytes: Int64 = 128 * 1024 * 1024
    /// Longest side of the bitmap handed to the image view.
    var imageLongEdge: Int = 2048
    /// Refuse before thumbnailing when either side exceeds this.
    var maxImageSide: Int = 32_768
    /// Refuse before thumbnailing when width times height exceeds this.
    var maxImagePixels: Int64 = 64 * 1024 * 1024
    /// Copies at least this large publish byte progress. Smaller copies keep a spinner.
    var progressThreshold: Int64 = 1024 * 1024

    static let standard = PreviewBudget()
}

enum PreviewSource: Hashable, Sendable {
    /// A regular file in the linked worktree, or in the repository directory when no link exists.
    case worktree(String)
    /// Full fixed commit OID plus the path in that commit tree.
    case blob(oid: String, path: String)
    var path: String {
        switch self { case .worktree(let path), .blob(_, let path): return path }
    }
}

enum PreviewKind: Equatable, Sendable {
    case text, markdown, image, pdf, svg, html, document, audio, video, lfsPointer, other, binary, archive
}

enum PreviewStatus: Equatable, Sendable {
    case ready
    case tooLarge(limit: Int64)
    case pixelBudget
    case encrypted
    case damaged
    case unreadable
    case unsupported
    case changed
    case symlink
    case directory
    case missing
    case accessDenied
    case cacheFull
    case lfsPointer
    case deferred
    /// The bytes are not valid UTF-8 and have no byte-order mark. No legacy encoding was guessed.
    case chooseEncoding
    /// Quick Look or the system player declined this snapshot. The file was not opened.
    case systemUnavailable
    case missingObject
    case gitlink
    case archiveLimited
}

struct PreviewDescriptor: Equatable, Sendable {
    var source: PreviewSource
    var kind: PreviewKind = .other
    var status: PreviewStatus
    var byteCount: Int64 = 0
    var typeIdentifier: String? = nil
    var pixelWidth: Int? = nil
    var pixelHeight: Int? = nil
    var frameCount: Int? = nil
    var displayedWidth: Int? = nil
    var displayedHeight: Int? = nil
    var pageCount: Int? = nil
    var recordedTarget: String? = nil
    var limitBytes: Int64? = nil
    var lfsOID: String? = nil
    var lfsObjectBytes: Int64? = nil

    var displayedLongEdge: Int? {
        guard let displayedWidth, let displayedHeight else { return nil }
        return max(displayedWidth, displayedHeight)
    }
}

struct PreviewLoadResult: Sendable {
    var descriptor: PreviewDescriptor
    var asset: PreviewAsset?
    var text: String?
    var textBytes: Data?
    var encoding: PreviewTextEncoding?
    var encodingConfidence: PreviewEncodingConfidence?
    var archive: PreviewArchiveIndex?
    var hex: PreviewHexPage?
    var thumbnail: Data?

    func close() { asset?.close() }
}

struct PreviewCopyProgress: Equatable, Sendable {
    var copied: Int64
    var total: Int64
}

/// Same publication rule as `GitProgressRelay`: one pending delivery, and the latest
/// byte count replaces any count that has not been delivered yet.
final class PreviewProgressRelay: @unchecked Sendable {
    typealias Schedule = @Sendable (@escaping @Sendable () -> Void) -> Void
    private let lock = NSLock()
    private let schedule: Schedule
    private let deliver: @Sendable (PreviewCopyProgress) -> Void
    private var latest: PreviewCopyProgress?
    private var pending = false
    private var closed = false

    init(schedule: @escaping Schedule = { work in
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100), execute: work)
    }, deliver: @escaping @Sendable (PreviewCopyProgress) -> Void) {
        self.schedule = schedule
        self.deliver = deliver
    }

    func update(copied: Int64, total: Int64) {
        let enqueue = lock.withLock { () -> Bool in
            guard !closed else { return false }
            latest = PreviewCopyProgress(copied: copied, total: total)
            guard !pending else { return false }
            pending = true
            return true
        }
        if enqueue { schedule { [weak self] in self?.drain() } }
    }

    func invalidate() {
        lock.withLock { closed = true; latest = nil }
    }

    private func drain() {
        let value = lock.withLock { () -> PreviewCopyProgress? in
            pending = false
            guard !closed else { return nil }
            let value = latest
            latest = nil
            return value
        }
        if let value { deliver(value) }
    }
}

final class PreviewCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func check() throws {
        lock.lock(); let value = cancelled; lock.unlock()
        if value || Task.isCancelled { throw CancellationError() }
    }
}

/// Snapshot preparation shares one queue so two previews cannot decode at once.
final class PreviewCoordinator: @unchecked Sendable {
    static let shared = PreviewCoordinator()
    private let queue = DispatchQueue(label: "gitling.workspace-preview")
    private let lock = NSLock()
    private var active = 0
    private var peakValue = 0
    var peak: Int { lock.withLock { peakValue } }

    var currentActive: Int { lock.withLock { active } }

    func run<T>(_ body: () throws -> T) rethrows -> T {
        try queue.sync {
            lock.lock()
            active += 1
            peakValue = max(peakValue, active)
            lock.unlock()
            defer { lock.lock(); active -= 1; lock.unlock() }
            return try body()
        }
    }
}

struct PreviewStamp: Equatable, Sendable {
    var device: Int32
    var inode: UInt64
    var size: Int64
    var modified: Int
    var modifiedNanos: Int
    var changed: Int
    var changedNanos: Int
    var mode: mode_t

    init(_ info: stat) {
        device = info.st_dev
        inode = info.st_ino
        size = Int64(info.st_size)
        modified = info.st_mtimespec.tv_sec
        modifiedNanos = info.st_mtimespec.tv_nsec
        changed = info.st_ctimespec.tv_sec
        changedNanos = info.st_ctimespec.tv_nsec
        mode = info.st_mode
    }

    var isRegular: Bool { mode & S_IFMT == S_IFREG }
    var isDirectory: Bool { mode & S_IFMT == S_IFDIR }
    var isLink: Bool { mode & S_IFMT == S_IFLNK }
    func sameFile(as other: PreviewStamp) -> Bool { device == other.device && inode == other.inode }
    func sameContents(as other: PreviewStamp) -> Bool {
        sameFile(as: other) && size == other.size && modified == other.modified && modifiedNanos == other.modifiedNanos && changed == other.changed && changedNanos == other.changedNanos
    }
}

/// App-private copies of worktree files. Closing a preview deletes its directory.
/// Live copies share `byteBudget`; this process does not keep a preview after it closes.
final class PreviewCache: @unchecked Sendable {
    static let shared: PreviewCache = {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gitling-preview", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        return PreviewCache(root: root, byteBudget: PreviewBudget.standard.cacheBytes)
    }()

    let root: URL
    let byteBudget: Int64
    private let lock = NSLock()
    private var items: [UUID: Item] = [:]

    struct Reservation: Sendable {
        let id: UUID
        let directory: URL
    }

    private struct Item {
        var directory: URL
        var bytes: Int64
    }

    init(root: URL, byteBudget: Int64) {
        self.root = root
        self.byteBudget = byteBudget
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    var liveBytes: Int64 { lock.withLock { items.values.reduce(0) { $0 + $1.bytes } } }

    func reserve(bytes: Int64) throws -> Reservation {
        try lock.withLock {
            let used = items.values.reduce(Int64(0)) { $0 + $1.bytes }
            guard bytes >= 0, bytes <= byteBudget, used <= byteBudget - bytes else { throw PreviewControl.cacheFull }
            let id = UUID()
            let directory = root.appendingPathComponent(id.uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            items[id] = Item(directory: directory, bytes: bytes)
            return Reservation(id: id, directory: directory)
        }
    }

    func release(_ id: UUID) {
        let directory = lock.withLock { items.removeValue(forKey: id)?.directory }
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }
}

final class PreviewAsset: @unchecked Sendable {
    let id: UUID
    let directory: URL
    let fileURL: URL
    private let cache: PreviewCache
    private let lock = NSLock()
    private var closed = false

    init(id: UUID, directory: URL, fileURL: URL, cache: PreviewCache) {
        self.id = id
        self.directory = directory
        self.fileURL = fileURL
        self.cache = cache
    }

    func close() {
        let should = lock.withLock { () -> Bool in
            if closed { return false }
            closed = true
            return true
        }
        if should { cache.release(id) }
    }

    deinit { close() }
}

private enum PreviewControl: Error {
    case changed
    case cacheFull
}

private final class Descriptor {
    private var fd: Int32
    init(_ fd: Int32) { self.fd = fd }
    var raw: Int32 { fd }
    deinit { if fd >= 0 { close(fd) } }
}

enum PreviewLabels {
    static func message(_ descriptor: PreviewDescriptor, locale: Locale = .current) -> String {
        switch descriptor.status {
        case .missingObject:
            return String(localized: "The object for this version is missing.", locale: locale)
        case .gitlink:
            return String(localized: "Only the recorded submodule OID is shown; no submodule is opened.", locale: locale) + "\n" + (descriptor.recordedTarget ?? "")
        case .archiveLimited:
            return String(localized: "This ZIP uses an unsupported layout or exceeds the directory metadata budget. No files were extracted.", locale: locale)
        case .ready:
            return ""
        case .tooLarge(let limit):
            let limitText = bytes(limit, locale: locale)
            let sizeText = bytes(descriptor.byteCount, locale: locale)
            switch descriptor.kind {
            case .svg:
                return String(format: String(localized: "SVG source is larger than the %@ text preview limit and is not rendered.", locale: locale), limitText)
            case .html:
                return String(format: String(localized: "HTML source is larger than the %@ text preview limit and is not loaded as a page.", locale: locale), limitText)
            case .image, .pdf, .document, .audio, .video, .binary, .archive:
                return String(format: String(localized: "This file is %@, larger than the %@ preview limit.", locale: locale), sizeText, limitText)
            default:
                return String(format: String(localized: "Text preview stops at %@. This file is %@.", locale: locale), limitText, sizeText)
            }
        case .pixelBudget:
            let width = Int64(descriptor.pixelWidth ?? 0)
            let height = Int64(descriptor.pixelHeight ?? 0)
            return String(format: String(localized: "This image is %lld by %lld pixels, above the decode budget, so it was not expanded.", locale: locale), width, height)
        case .encrypted:
            return String(localized: "This PDF is encrypted and was not unlocked.", locale: locale)
        case .damaged:
            return descriptor.kind == .pdf
                ? String(localized: "This PDF is damaged and could not be opened.", locale: locale)
                : String(localized: "This image is damaged and could not be decoded.", locale: locale)
        case .unreadable:
            return descriptor.kind == .pdf
                ? String(localized: "This PDF could not be read.", locale: locale)
                : String(localized: "Could not read this file.", locale: locale)
        case .unsupported:
            if descriptor.kind == .document {
                return String(localized: "This document's type is not specific enough to preview.", locale: locale)
            }
            return String(format: String(localized: "This file type cannot be previewed. Size: %@.", locale: locale), bytes(descriptor.byteCount, locale: locale))
        case .systemUnavailable:
            return String(localized: "This system cannot preview this file.", locale: locale)
        case .changed:
            return String(localized: "This file changed while it was being read. Open it again to preview the current version.", locale: locale)
        case .symlink:
            return String(localized: "This file is a symbolic link and was not followed.", locale: locale) + (descriptor.recordedTarget.map { "\n" + $0 } ?? "")
        case .directory:
            return String(localized: "This path is a directory.", locale: locale)
        case .missing:
            return String(localized: "Could not find that file.", locale: locale)
        case .accessDenied:
            return String(localized: "The working folder is not available.", locale: locale)
        case .cacheFull:
            return String(localized: "Preview storage is full. Close another preview and try again.", locale: locale)
        case .lfsPointer:
            let oid = descriptor.lfsOID.map { String($0.prefix(12)) } ?? ""
            let size = bytes(descriptor.lfsObjectBytes ?? 0, locale: locale)
            let object = String(format: String(localized: "Git LFS object %1$@ (%2$@).", locale: locale), oid, size)
            return String(localized: "This is a Git LFS pointer. The file was not downloaded.", locale: locale) + "\n" + object
        case .deferred:
            return String(localized: "Preview from history is not available yet.", locale: locale)
        case .chooseEncoding:
            return String(localized: "This file is not valid UTF-8. Choose an encoding; none was guessed.", locale: locale)
        }
    }

    static func encodingCaption(encoding: PreviewTextEncoding?, confidence: PreviewEncodingConfidence?, locale: Locale = .current) -> String {
        guard let encoding else { return String(localized: "Choose an encoding", locale: locale) }
        switch confidence {
        case .byteOrderMark:
            return encoding.title + " · " + String(localized: "Byte order mark", locale: locale)
        case .manual:
            return encoding.title + " · " + String(localized: "Selected manually", locale: locale)
        case .unicode, .none:
            return encoding.title
        }
    }

    static func encodingFailed(locale: Locale = .current) -> String {
        String(localized: "The selected encoding cannot read this file.", locale: locale)
    }

    static func documentCaption(_ descriptor: PreviewDescriptor, locale: Locale = .current) -> String {
        bytes(descriptor.byteCount, locale: locale) + "\n" + String(localized: "Preview is read-only. Changes in the preview are not saved.", locale: locale)
    }

    static func playerCaption(_ descriptor: PreviewDescriptor, locale: Locale = .current) -> String {
        bytes(descriptor.byteCount, locale: locale) + "\n" + String(localized: "Press play to start. Playback does not start automatically.", locale: locale)
    }

    static func note(_ descriptor: PreviewDescriptor, locale: Locale = .current) -> String? {
        switch descriptor.kind {
        case .svg: String(localized: "SVG is shown as source text and is not rendered.", locale: locale)
        case .html: String(localized: "HTML is shown as source text and is not loaded as a page.", locale: locale)
        default: nil
        }
    }

    static func imageCaption(_ descriptor: PreviewDescriptor, locale: Locale = .current) -> String {
        var lines: [String] = []
        if let width = descriptor.pixelWidth, let height = descriptor.pixelHeight {
            lines.append(String(format: String(localized: "%lld × %lld pixels", locale: locale), Int64(width), Int64(height)))
        }
        lines.append(bytes(descriptor.byteCount, locale: locale))
        if let width = descriptor.pixelWidth, let height = descriptor.pixelHeight, let displayed = descriptor.displayedLongEdge, max(width, height) > displayed {
            lines.append(String(format: String(localized: "Long edge limited to %lld pixels.", locale: locale), Int64(displayed)))
        }
        if let frames = descriptor.frameCount, frames > 1 {
            lines.append(String(localized: "Showing the first frame of this animated image.", locale: locale))
        }
        return lines.joined(separator: "\n")
    }

    static func pdfCaption(_ descriptor: PreviewDescriptor, locale: Locale = .current) -> String {
        let pages: String
        if descriptor.pageCount == 1 {
            pages = String(localized: "1 page", locale: locale)
        } else {
            pages = String(format: String(localized: "%lld pages", locale: locale), Int64(descriptor.pageCount ?? 0))
        }
        return pages + "\n" + bytes(descriptor.byteCount, locale: locale)
    }

    static func copying(_ progress: PreviewCopyProgress, locale: Locale = .current) -> String {
        String(format: String(localized: "Copied %1$@ of %2$@.", locale: locale), bytes(progress.copied, locale: locale), bytes(progress.total, locale: locale))
    }

    static func bytes(_ count: Int64, locale: Locale) -> String {
        let formatter = MeasurementFormatter()
        formatter.locale = locale
        formatter.unitOptions = .naturalScale
        formatter.unitStyle = .medium
        return formatter.string(from: Measurement(value: Double(count), unit: UnitInformationStorage.bytes))
    }
}

/// PDFKit objects stay on the main thread. Classification reads the lock state and
/// page count only; it does not draw pages or try a password.
enum PreviewPDF {
    struct Classification: Equatable, Sendable {
        var status: PreviewStatus
        var pageCount: Int?
    }

    static func classify(url: URL) -> Classification {
        if Thread.isMainThread { return inspect(url) }
        return DispatchQueue.main.sync { inspect(url) }
    }

    private static func inspect(_ url: URL) -> Classification {
        guard let document = PDFDocument(url: url) else {
            return Classification(status: .damaged, pageCount: nil)
        }
        if document.isLocked {
            return Classification(status: .encrypted, pageCount: nil)
        }
        guard document.pageCount > 0 else {
            return Classification(status: .unreadable, pageCount: 0)
        }
        return Classification(status: .ready, pageCount: document.pageCount)
    }
}

enum WorkspacePreview {
    static func load(source: PreviewSource, root: URL, budget: PreviewBudget = .standard, cache: PreviewCache, token: PreviewCancellation = PreviewCancellation(), progress: PreviewProgressRelay? = nil, whileReading: (@Sendable () -> Void)? = nil, support: PreviewSystemSupport = .live) throws -> PreviewLoadResult {
        switch source {
        case .blob(let oid, let path):
            return try GitClient.previewRevision(at: root, commit: oid, path: path, budget: budget, cache: cache, token: token, progress: progress)
        case .worktree(let path):
            return try load(root: root, path: path, budget: budget, cache: cache, token: token, progress: progress, whileReading: whileReading, support: support)
        }
    }

    static func load(root: URL, path: String, budget: PreviewBudget = .standard, cache: PreviewCache, token: PreviewCancellation = PreviewCancellation(), progress: PreviewProgressRelay? = nil, whileReading: (@Sendable () -> Void)? = nil, support: PreviewSystemSupport = .live) throws -> PreviewLoadResult {
        try token.check()
        do {
            return try read(root: root, path: path, budget: budget, cache: cache, token: token, progress: progress, whileReading: whileReading, support: support)
        } catch is CancellationError {
            throw CancellationError()
        } catch PreviewControl.changed {
            return result(path: path, status: .changed)
        } catch PreviewControl.cacheFull {
            return result(path: path, status: .cacheFull)
        } catch {
            return result(path: path, status: .unreadable)
        }
    }

    private static func read(root: URL, path: String, budget: PreviewBudget, cache: PreviewCache, token: PreviewCancellation, progress: PreviewProgressRelay?, whileReading: (@Sendable () -> Void)?, support: PreviewSystemSupport) throws -> PreviewLoadResult {
        let opened: Opened
        do { opened = try open(root: root, path: path) }
        catch is WorkingTreeError {
            return result(path: path, status: .missing)
        }
        switch opened {
        case .status(let status):
            return result(path: path, status: status)
        case .file(let parent, let file, let stamp):
            let loaded = try finish(path: path, parent: parent, file: file, leaf: leafName(path), stamp: stamp, budget: budget, cache: cache, token: token, progress: progress, whileReading: whileReading, support: support)
            do {
                try token.check()
                guard case .file(_, _, let current) = try open(root: root, path: path), stamp.sameContents(as: current) else {
                    loaded.close()
                    return result(path: path, status: .changed)
                }
                return loaded
            } catch { loaded.close(); throw error }
        }
    }

    private static func finish(path: String, parent: Descriptor, file: Descriptor, leaf: String, stamp: PreviewStamp, budget: PreviewBudget, cache: PreviewCache, token: PreviewCancellation, progress: PreviewProgressRelay?, whileReading: (@Sendable () -> Void)?, support: PreviewSystemSupport) throws -> PreviewLoadResult {
        if stamp.size <= 1024, stamp.size > 0 {
            let header = try read(fd: file.raw, count: Int(stamp.size), token: token)
            if let text = String(data: header, encoding: .utf8), let pointer = LFSPointer.parse(text) {
                try ensureUnchanged(start: stamp, parent: parent.raw, leaf: leaf, file: file.raw)
                var descriptor = result(path: path, kind: .lfsPointer, status: .lfsPointer, bytes: stamp.size).descriptor
                descriptor.lfsOID = pointer.oid
                descriptor.lfsObjectBytes = Int64(pointer.size)
                return PreviewLoadResult(descriptor: descriptor)
            }
        }
        let prefixCount = Int(min(stamp.size, 4096))
        let prefix = prefixCount == 0 ? Data() : try read(fd: file.raw, count: prefixCount, token: token)
        let sniffedImage = imageType(prefix)
        let sniffedPDF = prefix.starts(with: Data("%PDF-".utf8))
        let textual = textKind(prefix: prefix, path: path)

        let isZIP = prefix.starts(with: [0x50, 0x4b, 0x03, 0x04]) || prefix.starts(with: [0x50, 0x4b, 0x05, 0x06])
        var archive: PreviewArchiveIndex?
        if isZIP {
            do {
                archive = try PreviewArchive.index(size: Int(stamp.size), token: token) { offset, count in
                    try token.check()
                    return try read(fd: file.raw, offset: offset, count: count, token: token)
                }
            } catch is CancellationError { throw CancellationError() }
            catch PreviewArchive.Failure.damaged { return result(path: path, kind: .archive, status: .unreadable, bytes: stamp.size) }
            catch { return result(path: path, kind: .archive, status: .archiveLimited, bytes: stamp.size) }
        }
        let package = archive.flatMap { PreviewPackage.match(archive: $0, path: path) }
            ?? (isZIP ? nil : PreviewPackage.match(sample: prefix, path: path))
        if let archive, package == nil {
            try ensureUnchanged(start: stamp, parent: parent.raw, leaf: leaf, file: file.raw)
            return PreviewLoadResult(descriptor: .init(source: .worktree(path), kind: .archive, status: .ready, byteCount: stamp.size), archive: archive)
        }

        if stamp.size > budget.fileBytes {
            if sniffedImage != nil {
                return result(path: path, kind: .image, status: .tooLarge(limit: budget.fileBytes), bytes: stamp.size, limit: budget.fileBytes, type: sniffedImage?.identifier)
            }
            if sniffedPDF {
                return result(path: path, kind: .pdf, status: .tooLarge(limit: budget.fileBytes), bytes: stamp.size, limit: budget.fileBytes, type: UTType.pdf.identifier)
            }
            if let package {
                return result(path: path, kind: package.kind, status: .tooLarge(limit: budget.fileBytes), bytes: stamp.size, limit: budget.fileBytes, type: package.typeIdentifier)
            }
            if textual != nil {
                let limit = min(budget.textBytes, budget.fileBytes)
                return result(path: path, kind: textual ?? .text, status: .tooLarge(limit: limit), bytes: stamp.size, limit: limit)
            }
            return result(path: path, kind: .binary, status: .tooLarge(limit: budget.fileBytes), bytes: stamp.size, limit: budget.fileBytes)
        }

        if sniffedImage == nil, let package {
            if stamp.size > budget.fileBytes {
                return result(path: path, kind: package.kind, status: .tooLarge(limit: budget.fileBytes), bytes: stamp.size, limit: budget.fileBytes, type: package.typeIdentifier)
            }
            guard let suffix = package.suffix else {
                return result(path: path, kind: package.kind, status: .unsupported, bytes: stamp.size)
            }
            let type = UTType(filenameExtension: suffix) ?? .data
            return try snapshot(path: path, parent: parent, file: file, leaf: leaf, stamp: stamp, kind: package.kind, type: type, name: "content." + suffix, budget: budget, cache: cache, token: token, progress: progress, whileReading: whileReading) { url in
                let allowed = package.kind == .document ? support.canPreview(url) : support.canPlay(url)
                let descriptor = PreviewDescriptor(source: .worktree(path), kind: package.kind, status: allowed ? .ready : .systemUnavailable, byteCount: stamp.size, typeIdentifier: package.typeIdentifier)
                return PreviewLoadResult(descriptor: descriptor)
            }
        }

        if sniffedPDF {
            return try snapshot(path: path, parent: parent, file: file, leaf: leaf, stamp: stamp, kind: .pdf, type: UTType.pdf, name: "content.pdf", budget: budget, cache: cache, token: token, progress: progress, whileReading: whileReading) { url in
                let classified = PreviewPDF.classify(url: url)
                let descriptor = PreviewDescriptor(source: .worktree(path), kind: .pdf, status: classified.status, byteCount: stamp.size, typeIdentifier: UTType.pdf.identifier, pageCount: classified.pageCount)
                return PreviewLoadResult(descriptor: descriptor)
            }
        }

        let hinted = sniffedImage == nil ? extensionImageType(path) : nil
        if sniffedImage != nil || (hinted != nil && textual == nil) {
            let type = sniffedImage ?? hinted ?? .image
            let decoded = try snapshot(path: path, parent: parent, file: file, leaf: leaf, stamp: stamp, kind: .image, type: type, name: "content.imgdata", budget: budget, cache: cache, token: token, progress: progress, whileReading: whileReading) { url -> PreviewLoadResult in
                switch decodeImage(at: url, budget: budget) {
                case .image(let thumbnail, let pixels, let displayed, let frames):
                    let descriptor = PreviewDescriptor(source: .worktree(path), kind: .image, status: .ready, byteCount: stamp.size, typeIdentifier: type.identifier, pixelWidth: pixels.width, pixelHeight: pixels.height, frameCount: frames, displayedWidth: displayed.width, displayedHeight: displayed.height)
                    return PreviewLoadResult(descriptor: descriptor, thumbnail: thumbnail)
                case .pixelBudget(let pixels):
                    var descriptor = PreviewDescriptor(source: .worktree(path), kind: .image, status: .pixelBudget, byteCount: stamp.size, typeIdentifier: type.identifier, pixelWidth: pixels.width, pixelHeight: pixels.height)
                    return PreviewLoadResult(descriptor: descriptor)
                case .failed:
                    if sniffedImage != nil {
                        return result(path: path, kind: .image, status: .damaged, bytes: stamp.size, type: type.identifier)
                    }
                    return PreviewLoadResult(descriptor: PreviewDescriptor(source: .worktree(path), status: .unsupported))
                }
            }
            if decoded.descriptor.status != .unsupported { return decoded }
        }

        if stamp.size > budget.textBytes, let textual {
            return result(path: path, kind: textual, status: .tooLarge(limit: budget.textBytes), bytes: stamp.size, limit: budget.textBytes)
        }
        if stamp.size <= budget.textBytes, sniffedImage == nil {
            let data = stamp.size == 0 ? Data() : try read(fd: file.raw, count: Int(stamp.size), token: token)
            try ensureUnchanged(start: stamp, parent: parent.raw, leaf: leaf, file: file.raw)
            if let decision = PreviewText.interpret(data, path: path) {
                let descriptor = PreviewDescriptor(source: .worktree(path), kind: decision.kind, status: decision.status, byteCount: stamp.size)
                return PreviewLoadResult(descriptor: descriptor, text: decision.text, textBytes: data, encoding: decision.encoding, encodingConfidence: decision.confidence)
            }
        }
        return try snapshot(path: path, parent: parent, file: file, leaf: leaf, stamp: stamp, kind: .binary, type: .data, name: "content.bin", budget: budget, cache: cache, token: token, progress: progress, whileReading: whileReading) { url in
            PreviewLoadResult(descriptor: .init(source: .worktree(path), kind: .binary, status: .ready, byteCount: stamp.size),
                              hex: try PreviewHexPage.read(url: url, offset: 0, token: token))
        }
    }

    /// Copies into a private directory, then keeps that directory only when `body` returns a ready asset.
    /// A fallback `unsupported` result drops the copy so content can be classified another way.
    private static func snapshot(path: String, parent: Descriptor, file: Descriptor, leaf: String, stamp: PreviewStamp, kind: PreviewKind, type: UTType, name: String, budget: PreviewBudget, cache: PreviewCache, token: PreviewCancellation, progress: PreviewProgressRelay?, whileReading: (@Sendable () -> Void)?, body: (URL) throws -> PreviewLoadResult) throws -> PreviewLoadResult {
        try token.check()
        let reservation = try cache.reserve(bytes: stamp.size)
        var keep = false
        defer { if !keep { cache.release(reservation.id) } }
        let url = reservation.directory.appendingPathComponent(name)
        try copy(fd: file.raw, to: url, bytes: stamp.size, token: token, progress: progress, whileReading: whileReading)
        try ensureUnchanged(start: stamp, parent: parent.raw, leaf: leaf, file: file.raw)
        var produced = try body(url)
        try token.check()
        if produced.descriptor.status == .unsupported { return produced }
        let previewFile = kind == .pdf || kind == .document || kind == .audio || kind == .video || kind == .binary
        if produced.descriptor.status == .ready && (previewFile || produced.thumbnail != nil) {
            produced.asset = PreviewAsset(id: reservation.id, directory: reservation.directory, fileURL: url, cache: cache)
            keep = true
        }
        if produced.descriptor.kind == .other { produced.descriptor.kind = kind }
        if produced.descriptor.typeIdentifier == nil { produced.descriptor.typeIdentifier = type.identifier }
        if produced.descriptor.byteCount == 0 { produced.descriptor.byteCount = stamp.size }
        return produced
    }

    private enum Opened {
        case file(parent: Descriptor, file: Descriptor, stamp: PreviewStamp)
        case status(PreviewStatus)
    }

    private enum EntryKind { case missing, link, directory, regular, other }

    private static func open(root: URL, path: String) throws -> Opened {
        let parts = try SearchWorktreeAccess.components(path)
        guard let leaf = parts.last else { return .status(.missing) }
        let rootFD = root.path.withCString { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        guard rootFD >= 0 else { return .status(.missing) }
        var parent = Descriptor(rootFD)
        for part in parts.dropLast() {
            switch try entryKind(parent: parent.raw, name: part) {
            case .missing: return .status(.missing)
            case .link: return .status(.symlink)
            case .directory:
                let next = openat(parent.raw, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { return .status(errno == ELOOP ? .symlink : .missing) }
                parent = Descriptor(next)
            case .regular, .other: return .status(.unsupported)
            }
        }
        switch try entryKind(parent: parent.raw, name: leaf) {
        case .missing: return .status(.missing)
        case .link: return .status(.symlink)
        case .directory: return .status(.directory)
        case .other: return .status(.unsupported)
        case .regular:
            let fd = openat(parent.raw, leaf, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { return .status(errno == ELOOP ? .symlink : .unreadable) }
            let file = Descriptor(fd)
            let info = try fileStatus(file.raw)
            let stamp = PreviewStamp(info)
            guard stamp.isRegular else { return .status(.unsupported) }
            return .file(parent: parent, file: file, stamp: stamp)
        }
    }

    private static func entryKind(parent: Int32, name: String) throws -> EntryKind {
        var info = stat()
        if fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return .missing }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let stamp = PreviewStamp(info)
        if stamp.isLink { return .link }
        if stamp.isDirectory { return .directory }
        if stamp.isRegular { return .regular }
        return .other
    }

    private static func fileStatus(_ fd: Int32) throws -> stat {
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return info
    }

    private static func ensureUnchanged(start: PreviewStamp, parent: Int32, leaf: String, file: Int32) throws {
        let current = PreviewStamp(try fileStatus(file))
        var pathInfo = stat()
        guard current.sameContents(as: start),
              fstatat(parent, leaf, &pathInfo, AT_SYMLINK_NOFOLLOW) == 0 else { throw PreviewControl.changed }
        let path = PreviewStamp(pathInfo)
        guard path.isRegular, path.sameContents(as: start) else { throw PreviewControl.changed }
    }

    private static func read(fd: Int32, offset start: Int = 0, count: Int, token: PreviewCancellation) throws -> Data {
        var data = Data()
        data.reserveCapacity(count)
        var buffer = [UInt8](repeating: 0, count: min(max(count, 1), 65_536))
        var offset = off_t(start)
        while data.count < count {
            try token.check()
            let want = min(buffer.count, count - data.count)
            let n = buffer.withUnsafeMutableBytes { raw -> Int in
                pread(fd, raw.baseAddress!, want, offset)
            }
            if n < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            if n == 0 { throw PreviewControl.changed }
            offset += off_t(n)
            data.append(contentsOf: buffer.prefix(n))
        }
        return data
    }

    private static func copy(fd: Int32, to url: URL, bytes: Int64, token: PreviewCancellation, progress: PreviewProgressRelay?, whileReading: (@Sendable () -> Void)?) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw POSIXError(.EIO)
        }
        let output = try FileHandle(forWritingTo: url)
        defer { try? output.close() }
        var buffer = [UInt8](repeating: 0, count: 65_536)
        var offset: off_t = 0
        var copied: Int64 = 0
        var observed = false
        while copied < bytes {
            try token.check()
            if !observed {
                whileReading?()
                observed = true
                try token.check()
            }
            let want = Int(min(Int64(buffer.count), bytes - copied))
            let n = buffer.withUnsafeMutableBytes { raw -> Int in
                pread(fd, raw.baseAddress!, want, offset)
            }
            if n < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            if n == 0 { throw PreviewControl.changed }
            try output.write(contentsOf: Data(buffer.prefix(n)))
            offset += off_t(n)
            copied += Int64(n)
            progress?.update(copied: copied, total: bytes)
        }
    }

    private enum ImageDecode {
        case image(Data, pixels: (width: Int, height: Int), displayed: (width: Int, height: Int), frames: Int)
        case pixelBudget(pixels: (width: Int, height: Int))
        case failed
    }

    /// Reads image properties, refuses declared pixel bombs, then asks Image I/O for one
    /// thumbnail. Animated images contribute only frame 0. The full bitmap is not cached.
    private static func decodeImage(at url: URL, budget: PreviewBudget) -> ImageDecode {
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary) else { return .failed }
        let frames = CGImageSourceGetCount(source)
        guard frames > 0 else { return .failed }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return .failed }
        let rawWidth = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.int64Value ?? 0
        let rawHeight = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.int64Value ?? 0
        guard rawWidth > 0, rawHeight > 0 else { return .failed }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let swaps = (5...8).contains(orientation)
        let width = swaps ? rawHeight : rawWidth
        let height = swaps ? rawWidth : rawHeight
        let product = width.multipliedReportingOverflow(by: height)
        if width > Int64(budget.maxImageSide) || height > Int64(budget.maxImageSide) || product.overflow || product.partialValue > budget.maxImagePixels {
            return .pixelBudget(pixels: (Int(clamping: width), Int(clamping: height)))
        }
        let edge = max(1, budget.imageLongEdge)
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: edge,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else { return .failed }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return .failed }
        CGImageDestinationAddImage(destination, thumbnail, nil)
        guard CGImageDestinationFinalize(destination) else { return .failed }
        return .image(data as Data, pixels: (Int(width), Int(height)), displayed: (thumbnail.width, thumbnail.height), frames: frames)
    }

    private static func imageType(_ data: Data) -> UTType? {
        if data.starts(with: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) { return .png }
        if data.starts(with: Data([0xFF, 0xD8, 0xFF])) { return .jpeg }
        if data.starts(with: Data("GIF87a".utf8)) || data.starts(with: Data("GIF89a".utf8)) { return .gif }
        if data.starts(with: Data("BM".utf8)) { return .bmp }
        if data.starts(with: Data([0x49, 0x49, 0x2A, 0x00])) || data.starts(with: Data([0x4D, 0x4D, 0x00, 0x2A])) { return .tiff }
        if data.count >= 12, data.prefix(4) == Data("RIFF".utf8), data.subdata(in: 8..<12) == Data("WEBP".utf8) {
            return UTType("org.webmproject.webp") ?? .image
        }
        guard data.count >= 12, data.subdata(in: 4..<8) == Data("ftyp".utf8) else { return nil }
        let brand = String(data: data.subdata(in: 8..<12), encoding: .ascii) ?? ""
        switch brand {
        case "heic", "heix", "hevc", "heim", "heis": return .heic
        case "heif", "mif1", "msf1": return .heif
        case "avif", "avis": return UTType("public.avif") ?? .heic
        default: return nil
        }
    }

    private static func extensionImageType(_ path: String) -> UTType? {
        let ext = (path as NSString).pathExtension
        guard !ext.isEmpty, ext.lowercased() != "svg", let type = UTType(filenameExtension: ext), type.conforms(to: .image) else { return nil }
        return type
    }

    private static func textKind(prefix: Data, path: String) -> PreviewKind? {
        if PreviewText.interpret(prefix, path: path) != nil {
            return PreviewText.kind(path: path, text: String(data: prefix, encoding: .utf8))
        }
        return nil
    }

    private static func leafName(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }

    private static func result(path: String, kind: PreviewKind = .other, status: PreviewStatus, bytes: Int64 = 0, limit: Int64? = nil, type: String? = nil) -> PreviewLoadResult {
        PreviewLoadResult(descriptor: PreviewDescriptor(
            source: .worktree(path),
            kind: kind,
            status: status,
            byteCount: bytes,
            typeIdentifier: type,
            limitBytes: limit
        ))
    }
}

/// Loads one worktree preview. A newer request cancels the previous token and drops a late result.
@MainActor
final class WorkspacePreviewModel: ObservableObject {
    struct TextState {
        var text: String
        var spans: [SyntaxSpan]
        var note: String?
        var kind: PreviewKind
        var encoding: PreviewTextEncoding?
        var confidence: PreviewEncodingConfidence?
        var detectedEncoding: PreviewTextEncoding?
        var detectedConfidence: PreviewEncodingConfidence?
        var bytes: Data
        var prompt: String?
        var failure: String?
    }

    enum Phase {
        case loading
        case copying(PreviewCopyProgress)
        case text(TextState)
        case image(Data, caption: String)
        case pdf(URL, caption: String)
        case quickLook(URL, caption: String)
        case player(URL, caption: String)
        case notice(String)
        case archive(PreviewArchiveIndex)
        case hex(PreviewHexPage, loading: Bool = false)
    }

    @Published private(set) var phase: Phase = .loading
    @Published var markdownMode = PreviewMarkdownMode.rendered
    private let budget: PreviewBudget
    private let cache: PreviewCache
    private let coordinator: PreviewCoordinator
    private var generation = 0
    private var textGeneration = 0
    private var token: PreviewCancellation?
    private var asset: PreviewAsset?
    private var publishing = false

    init(budget: PreviewBudget = .standard, cache: PreviewCache = .shared, coordinator: PreviewCoordinator = .shared) {
        self.budget = budget
        self.cache = cache
        self.coordinator = coordinator
    }

    func cancel() {
        generation += 1
        textGeneration += 1
        publishing = false
        markdownMode = .rendered
        token?.cancel()
        token = nil
        asset?.close()
        asset = nil
    }

    func load(repo: URL, path: String) async { await load(repo: repo, source: .worktree(path)) }

    func load(repo: URL, source: PreviewSource) async {
        let path = source.path
        let generation = begin()
        let token = PreviewCancellation()
        self.token = token
        let budget = budget
        let cache = cache
        let coordinator = coordinator
        let relay = PreviewProgressRelay { [weak self] progress in
            Task { @MainActor in
                guard let self, self.publishing, generation == self.generation else { return }
                guard progress.total >= budget.progressThreshold else { return }
                self.phase = .copying(progress)
            }
        }
        do {
            let result = try await withTaskCancellationHandler {
                try await Task.detached(priority: .userInitiated) {
                    try coordinator.run {
                        switch source {
                        case .worktree(let path): return try GitClient.previewWorktree(at: repo, path: path, budget: budget, cache: cache, token: token, progress: relay)
                        case .blob(let commit, let path): return try GitClient.previewRevision(at: repo, commit: commit, path: path, budget: budget, cache: cache, token: token, progress: relay)
                        }
                    }
                }.value
            } onCancel: {
                token.cancel()
            }
            relay.invalidate()
            guard generation == self.generation else { result.close(); return }
            publishing = false
            guard receive(generation: generation, result: result) else { return }
            await highlight(path: path)
        } catch is CancellationError {
            relay.invalidate()
            guard generation == self.generation else { return }
            publishing = false
            asset?.close(); asset = nil
            phase = .notice(String(localized: "Preview cancelled."))
        } catch {
            relay.invalidate()
            guard generation == self.generation else { return }
            publishing = false
            phase = .notice(error.localizedDescription)
        }
    }

    @discardableResult
    func begin() -> Int {
        generation += 1
        textGeneration += 1
        publishing = true
        markdownMode = .rendered
        token?.cancel()
        token = nil
        asset?.close()
        asset = nil
        phase = .loading
        return generation
    }

    /// Re-decode the bytes already read for this preview. A manual choice stays labeled manual,
    /// including when GB18030 happens to produce characters. It does not read another file.
    func choose(_ encoding: PreviewTextEncoding) {
        guard case .text(var state) = phase else { return }
        textGeneration += 1
        state.encoding = encoding
        if encoding == state.detectedEncoding, let detected = state.detectedConfidence {
            state.confidence = detected
        } else {
            state.confidence = .manual
        }
        if let text = PreviewText.decode(state.bytes, as: encoding) {
            state.text = text
            state.failure = nil
            state.spans = []
            state.kind = PreviewText.kind(path: currentPath ?? "", text: text)
            phase = .text(state)
            if let path = currentPath {
                Task { await highlight(path: path) }
            }
        } else {
            state.text = ""
            state.spans = []
            state.failure = PreviewLabels.encodingFailed()
            phase = .text(state)
        }
    }

    func moveHexPage(_ direction: Int) async {
        guard case .hex(let page, false) = phase, let url = asset?.fileURL, let token else { return }
        let offset = max(0, page.offset + (direction < 0 ? -PreviewHexPage.pageBytes : PreviewHexPage.pageBytes))
        guard offset < page.total else { return }
        let request = generation
        phase = .hex(page, loading: true)
        do {
            let next = try await Task.detached { try PreviewHexPage.read(url: url, offset: offset, token: token) }.value
            guard request == generation else { return }
            phase = .hex(next)
        } catch {
            guard request == generation else { return }
            phase = .notice(String(localized: "Could not read this file."))
        }
    }

    private var currentPath: String? {
        if case .text = phase { return storedPath }
        return storedPath
    }

    private var storedPath: String?

    @discardableResult
    func receive(generation: Int, result: PreviewLoadResult) -> Bool {
        guard generation == self.generation else {
            result.close()
            return false
        }
        present(result)
        return true
    }

    private func present(_ result: PreviewLoadResult) {
        asset?.close()
        asset = result.asset
        storedPath = result.descriptor.source.path
        switch result.descriptor.status {
        case .chooseEncoding:
            phase = .text(TextState(
                text: "", spans: [], note: PreviewLabels.note(result.descriptor), kind: result.descriptor.kind,
                bytes: result.textBytes ?? Data(), prompt: PreviewLabels.message(result.descriptor)
            ))
        case .ready:
            switch result.descriptor.kind {
            case .text, .markdown, .svg, .html:
                phase = .text(TextState(
                    text: result.text ?? "", spans: [], note: PreviewLabels.note(result.descriptor), kind: result.descriptor.kind,
                    encoding: result.encoding, confidence: result.encodingConfidence,
                    detectedEncoding: result.encoding, detectedConfidence: result.encodingConfidence,
                    bytes: result.textBytes ?? Data()
                ))
            case .image:
                if let thumbnail = result.thumbnail, !thumbnail.isEmpty {
                    phase = .image(thumbnail, caption: PreviewLabels.imageCaption(result.descriptor))
                } else {
                    asset?.close()
                    asset = nil
                    phase = .notice(PreviewLabels.message(replacing(result.descriptor, status: .damaged)))
                }
            case .pdf:
                if let url = result.asset?.fileURL {
                    phase = .pdf(url, caption: PreviewLabels.pdfCaption(result.descriptor))
                } else {
                    phase = .notice(PreviewLabels.message(replacing(result.descriptor, status: .unreadable)))
                }
            case .document:
                if let url = result.asset?.fileURL {
                    phase = .quickLook(url, caption: PreviewLabels.documentCaption(result.descriptor))
                } else {
                    phase = .notice(PreviewLabels.message(replacing(result.descriptor, status: .systemUnavailable)))
                }
            case .audio, .video:
                if let url = result.asset?.fileURL {
                    phase = .player(url, caption: PreviewLabels.playerCaption(result.descriptor))
                } else {
                    phase = .notice(PreviewLabels.message(replacing(result.descriptor, status: .systemUnavailable)))
                }
            case .archive:
                if let index = result.archive { phase = .archive(index) }
                else { phase = .notice(PreviewLabels.message(replacing(result.descriptor, status: .unreadable))) }
            case .binary:
                if let page = result.hex { phase = .hex(page) }
                else { phase = .notice(PreviewLabels.message(replacing(result.descriptor, status: .unreadable))) }
            case .lfsPointer:
                phase = .notice(PreviewLabels.message(result.descriptor))
            case .other:
                phase = .notice(PreviewLabels.message(replacing(result.descriptor, status: .unsupported)))
            }
        default:
            phase = .notice(PreviewLabels.message(result.descriptor))
        }
    }

    private func highlight(path: String) async {
        guard case .text(let state) = phase, state.encoding != nil, state.failure == nil else { return }
        let token = textGeneration
        let text = state.text
        let highlighted = await Task.detached(priority: .userInitiated) {
            SyntaxHighlighter.spans(in: text, path: path)
        }.value
        guard token == textGeneration, generation == self.generation, !Task.isCancelled else { return }
        guard case .text(var latest) = phase, latest.text == text else { return }
        latest.spans = highlighted
        phase = .text(latest)
    }

    private func replacing(_ descriptor: PreviewDescriptor, status: PreviewStatus) -> PreviewDescriptor {
        var copy = descriptor
        copy.status = status
        return copy
    }
}
