import AVKit
import Clibgit2
import CoreGraphics
import ImageIO
import PDFKit
import QuickLook
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import WebKit
import XCTest
import zlib
@testable import Gitling

final class WorkspacePreviewTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("preview-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func cache(budget: Int64) throws -> PreviewCache {
        PreviewCache(root: try temporaryDirectory(), byteBudget: budget)
    }

    private func place(_ data: Data, at path: String, in root: URL) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return url
    }

    private func bitmap(width: Int, height: Int, red: CGFloat) throws -> CGImage {
        let row = width * 4
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: row * height, alignment: 16)
        buffer.initializeMemory(as: UInt8.self, repeating: 0, count: row * height)
        defer { buffer.deallocate() }
        guard let context = CGContext(
            data: buffer, width: width, height: height, bitsPerComponent: 8, bytesPerRow: row,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw CocoaError(.fileWriteUnknown) }
        context.setFillColor(red: red, green: 0.2, blue: 0.4, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }

    private func encoded(_ image: CGImage, type: UTType) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return data as Data
    }

    private func png(width: Int, height: Int, red: CGFloat = 0.1) throws -> Data {
        try encoded(try bitmap(width: width, height: height, red: red), type: .png)
    }

    private func budget(file: Int64 = 1024 * 1024, text: Int64 = 256 * 1024, edge: Int = 2048, side: Int = 32_768, pixels: Int64 = 64 * 1024 * 1024) -> PreviewBudget {
        var budget = PreviewBudget.standard
        budget.fileBytes = file
        budget.textBytes = text
        budget.imageLongEdge = edge
        budget.maxImageSide = side
        budget.maxImagePixels = pixels
        return budget
    }

    private func load(_ root: URL, _ path: String, budget: PreviewBudget, cache: PreviewCache, token: PreviewCancellation = PreviewCancellation(), whileReading: (@Sendable () -> Void)? = nil) throws -> PreviewLoadResult {
        try WorkspacePreview.load(root: root, path: path, budget: budget, cache: cache, token: token, whileReading: whileReading)
    }

    private func storedEntries(_ cache: PreviewCache) -> [URL] {
        (FileManager.default.enumerator(at: cache.root, includingPropertiesForKeys: nil)?.allObjects as? [URL]) ?? []
    }

    func testBudgetsMatchTheStartingPlan() {
        XCTAssertEqual(PreviewBudget.standard.textBytes, Int64(FileInspection.maximumBytes))
        XCTAssertEqual(PreviewBudget.standard.textBytes, 256 * 1024)
        XCTAssertEqual(PreviewBudget.standard.fileBytes, 32 * 1024 * 1024)
        XCTAssertEqual(PreviewBudget.standard.cacheBytes, 128 * 1024 * 1024)
        XCTAssertEqual(PreviewBudget.standard.imageLongEdge, 2048)
        XCTAssertEqual(PreviewBudget.standard.maxImageSide, 32_768)
        XCTAssertEqual(PreviewBudget.standard.maxImagePixels, 64 * 1024 * 1024)
    }

    func testExtensionDoesNotOverrideFileContents() throws {
        let root = try temporaryDirectory()
        let store = try cache(budget: 8 * 1024 * 1024)
        let limits = budget(edge: 40)
        let image = try png(width: 180, height: 60)
        try place(image, at: "notes.txt", in: root)
        try place(Data("plain text\n".utf8), at: "photo.png", in: root)
        let disguisedText = try load(root, "photo.png", budget: limits, cache: store)
        XCTAssertEqual(disguisedText.descriptor.kind, .text)
        XCTAssertEqual(disguisedText.descriptor.status, .ready)
        XCTAssertEqual(disguisedText.text, "plain text\n")
        XCTAssertNil(disguisedText.asset)

        let clock = ContinuousClock()
        let started = clock.now
        let disguisedImage = try load(root, "notes.txt", budget: limits, cache: store)
        let elapsed = clock.now - started
        defer { disguisedImage.close() }
        XCTAssertEqual(disguisedImage.descriptor.kind, .image)
        XCTAssertEqual(disguisedImage.descriptor.status, .ready)
        XCTAssertEqual(disguisedImage.descriptor.pixelWidth, 180)
        XCTAssertEqual(disguisedImage.descriptor.pixelHeight, 60)
        XCTAssertLessThanOrEqual(disguisedImage.descriptor.displayedLongEdge ?? 0, 40)
        XCTAssertLessThan(disguisedImage.thumbnail?.count ?? .max, 180 * 60 * 4)
        let caption = PreviewLabels.imageCaption(disguisedImage.descriptor)
        XCTAssertTrue(caption.contains("180"))
        XCTAssertTrue(caption.contains("60"))
        XCTAssertTrue(caption.contains("\(disguisedImage.descriptor.displayedLongEdge ?? 0)"))
        XCTAssertFalse(disguisedImage.asset!.directory.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path))
        print("PREVIEW_SAMPLE elapsed=\(elapsed) thumbnailBytes=\(disguisedImage.thumbnail?.count ?? 0) displayed=\(disguisedImage.descriptor.displayedWidth ?? 0)x\(disguisedImage.descriptor.displayedHeight ?? 0)")
    }

    func testJPEGHEICAndGIFUseOneDownsampledFrame() throws {
        let root = try temporaryDirectory()
        let store = try cache(budget: 8 * 1024 * 1024)
        let limits = budget(edge: 32)
        let jpeg = try encoded(try bitmap(width: 80, height: 40, red: 0.8), type: .jpeg)
        try place(jpeg, at: "shot.jpg", in: root)
        let jpegResult = try load(root, "shot.jpg", budget: limits, cache: store)
        defer { jpegResult.close() }
        XCTAssertEqual(jpegResult.descriptor.kind, .image)
        XCTAssertEqual(jpegResult.descriptor.typeIdentifier, UTType.jpeg.identifier)
        XCTAssertEqual(jpegResult.descriptor.pixelWidth, 80)
        XCTAssertLessThanOrEqual(jpegResult.descriptor.displayedLongEdge ?? 0, 32)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(jpegResult.asset).fileURL), jpeg)

        let heicData = NSMutableData()
        guard let heic = CGImageDestinationCreateWithData(heicData, UTType.heic.identifier as CFString, 1, nil) else {
            throw XCTSkip("This runtime cannot encode HEIC.")
        }
        CGImageDestinationAddImage(heic, try bitmap(width: 24, height: 16, red: 0.3), nil)
        guard CGImageDestinationFinalize(heic) else { throw XCTSkip("This runtime cannot encode HEIC.") }
        try place(heicData as Data, at: "still.heic", in: root)
        let heicResult = try load(root, "still.heic", budget: limits, cache: store)
        defer { heicResult.close() }
        XCTAssertEqual(heicResult.descriptor.kind, .image)
        XCTAssertEqual(heicResult.descriptor.status, .ready)
        XCTAssertEqual(heicResult.descriptor.pixelWidth, 24)
        XCTAssertEqual(heicResult.descriptor.pixelHeight, 16)

        let gifData = NSMutableData()
        guard let gif = CGImageDestinationCreateWithData(gifData, UTType.gif.identifier as CFString, 2, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationSetProperties(gif, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let frame = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]] as CFDictionary
        CGImageDestinationAddImage(gif, try bitmap(width: 12, height: 8, red: 0.2), frame)
        CGImageDestinationAddImage(gif, try bitmap(width: 12, height: 8, red: 0.9), frame)
        guard CGImageDestinationFinalize(gif) else { throw CocoaError(.fileWriteUnknown) }
        try place(gifData as Data, at: "motion.gif", in: root)
        let gifResult = try load(root, "motion.gif", budget: limits, cache: store)
        defer { gifResult.close() }
        XCTAssertEqual(gifResult.descriptor.kind, .image)
        XCTAssertGreaterThanOrEqual(gifResult.descriptor.frameCount ?? 0, 2)
        XCTAssertFalse(PreviewLabels.imageCaption(gifResult.descriptor).isEmpty)
        XCTAssertNotNil(UIImage(data: try XCTUnwrap(gifResult.thumbnail)))
    }

    func testPixelBudgetRejectsSmallFilesWithHugeDimensions() throws {
        let root = try temporaryDirectory()
        let store = try cache(budget: 1024 * 1024)
        var ihdr = Data()
        ihdr.append(uint32(40_000))
        ihdr.append(uint32(1))
        ihdr.append(contentsOf: [8, 2, 0, 0, 0])
        var crafted = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        crafted.append(chunk("IHDR", ihdr))
        crafted.append(chunk("IEND", Data()))
        try place(crafted, at: "bomb.png", in: root)
        let bomb = try load(root, "bomb.png", budget: budget(), cache: store)
        XCTAssertNil(bomb.thumbnail)
        XCTAssertNil(bomb.asset)
        XCTAssertNotEqual(bomb.descriptor.status, .ready)
        XCTAssertTrue(storedEntries(store).isEmpty)
        if case .pixelBudget = bomb.descriptor.status {
            XCTAssertEqual(bomb.descriptor.pixelWidth, 40_000)
            XCTAssertEqual(bomb.descriptor.pixelHeight, 1)
        } else {
            XCTAssertEqual(bomb.descriptor.status, .damaged)
        }

        let real = try png(width: 40, height: 40)
        try place(real, at: "large.png", in: root)
        let limited = try load(root, "large.png", budget: budget(pixels: 100), cache: store)
        XCTAssertEqual(limited.descriptor.status, .pixelBudget)
        XCTAssertEqual(limited.descriptor.pixelWidth, 40)
        XCTAssertEqual(limited.descriptor.pixelHeight, 40)
        XCTAssertNil(limited.thumbnail)
        XCTAssertTrue(storedEntries(store).isEmpty)
        let message = PreviewLabels.message(limited.descriptor)
        XCTAssertTrue(message.contains("40"))
    }

    func testPDFBrowsingRejectsEncryptedAndDamagedFiles() throws {
        let root = try temporaryDirectory()
        let store = try cache(budget: 1024 * 1024)
        let document = try pdf(pages: 2)
        let source = try place(document, at: "notes/spec.pdf", in: root)
        let result = try load(root, "notes/spec.pdf", budget: budget(), cache: store)
        defer { result.close() }
        XCTAssertEqual(result.descriptor.kind, .pdf)
        XCTAssertEqual(result.descriptor.status, .ready)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(result.asset).fileURL), document)
        XCTAssertEqual(try Data(contentsOf: source), document)
        let classified = PreviewPDF.classify(url: try XCTUnwrap(result.asset).fileURL)
        XCTAssertEqual(classified.status, .ready)
        XCTAssertEqual(classified.pageCount, 2)
        let caption = PreviewLabels.pdfCaption(PreviewDescriptor(source: .worktree("notes/spec.pdf"), kind: .pdf, status: .ready, byteCount: Int64(document.count), pageCount: 2))
        XCTAssertTrue(caption.contains("2"))

        try place(try pdf(pages: 1, password: "secret"), at: "locked.pdf", in: root)
        let encrypted = try load(root, "locked.pdf", budget: budget(), cache: store)
        XCTAssertEqual(encrypted.descriptor.status, .encrypted)
        XCTAssertNil(encrypted.asset)
        XCTAssertEqual(PreviewPDF.classify(url: root.appendingPathComponent("locked.pdf")).status, .encrypted)
        let damaged = try place(Data("%PDF-1.7\nthis is not a pdf".utf8), at: "broken.pdf", in: root)
        let damagedKind = PreviewPDF.classify(url: damaged).status
        XCTAssertTrue(damagedKind == .damaged || damagedKind == .unreadable)
        try place(Data("not really a pdf".utf8), at: "fake.pdf", in: root)
        let fake = try load(root, "fake.pdf", budget: budget(), cache: store)
        XCTAssertEqual(fake.descriptor.kind, .text)
        XCTAssertEqual(fake.descriptor.status, .ready)
        XCTAssertEqual(fake.text, "not really a pdf")
        XCTAssertNil(fake.asset)
    }

    func testSymlinksDirectoriesAndTraversalAreNotFollowed() throws {
        let root = try temporaryDirectory()
        let store = try cache(budget: 1024 * 1024)
        let image = try png(width: 8, height: 8)
        try place(image, at: "real/photo.png", in: root)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("photo.png"), withDestinationURL: root.appendingPathComponent("real/photo.png"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked"), withDestinationURL: root.appendingPathComponent("real"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("folder"), withIntermediateDirectories: true)
        let limits = budget()
        XCTAssertEqual(try load(root, "photo.png", budget: limits, cache: store).descriptor.status, .symlink)
        XCTAssertEqual(try load(root, "linked/photo.png", budget: limits, cache: store).descriptor.status, .symlink)
        XCTAssertEqual(try load(root, "folder", budget: limits, cache: store).descriptor.status, .directory)
        XCTAssertEqual(try load(root, "../secret.txt", budget: limits, cache: store).descriptor.status, .missing)
        XCTAssertEqual(try load(root, ".git/config", budget: limits, cache: store).descriptor.status, .missing)
        XCTAssertEqual(try load(root, "missing.png", budget: limits, cache: store).descriptor.status, .missing)
        XCTAssertTrue(storedEntries(store).isEmpty)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("real/photo.png")), image)
    }

    func testAChangeWhileCopyingDropsTheSnapshot() throws {
        let root = try temporaryDirectory()
        let store = try cache(budget: 1024 * 1024)
        let file = try place(try png(width: 16, height: 16), at: "photo.png", in: root)
        let original = try Data(contentsOf: file).count
        let result = try load(root, "photo.png", budget: budget(), cache: store, whileReading: {
            let handle = try? FileHandle(forWritingTo: file)
            try? handle?.seekToEnd()
            try? handle?.write(contentsOf: Data([7]))
            try? handle?.close()
        })
        XCTAssertEqual(result.descriptor.status, .changed)
        XCTAssertNil(result.asset)
        XCTAssertNil(result.thumbnail)
        XCTAssertTrue(storedEntries(store).isEmpty)
        XCTAssertGreaterThan(try Data(contentsOf: file).count, original)

        let replacement = try place(try png(width: 8, height: 8), at: "stable.png", in: root)
        let swapped = try load(root, "stable.png", budget: budget(), cache: store, whileReading: {
            try? FileManager.default.removeItem(at: replacement)
            try? FileManager.default.createSymbolicLink(at: replacement, withDestinationURL: file)
        })
        XCTAssertEqual(swapped.descriptor.status, .changed)
        XCTAssertNil(swapped.asset)
        XCTAssertTrue(storedEntries(store).isEmpty)
        let values = try replacement.resourceValues(forKeys: [.isSymbolicLinkKey])
        XCTAssertEqual(values.isSymbolicLink, true)
    }

    func testCancellationAndCacheLimitsRemoveSnapshots() throws {
        let root = try temporaryDirectory()
        let store = try cache(budget: 1024 * 1024)
        let file = try place(try png(width: 8, height: 8), at: "photo.png", in: root)
        let token = PreviewCancellation()
        XCTAssertThrowsError(try load(root, "photo.png", budget: budget(), cache: store, token: token, whileReading: { token.cancel() })) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertTrue(storedEntries(store).isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))

        let firstData = try png(width: 12, height: 12, red: 0.2)
        let secondData = firstData
        try place(firstData, at: "a.png", in: root)
        try place(secondData, at: "b.png", in: root)
        let tight = try cache(budget: Int64(firstData.count))
        let first = try load(root, "a.png", budget: budget(), cache: tight)
        XCTAssertEqual(first.descriptor.status, .ready)
        XCTAssertEqual(tight.liveBytes, Int64(firstData.count))
        let blocked = try load(root, "b.png", budget: budget(), cache: tight)
        XCTAssertEqual(blocked.descriptor.status, .cacheFull)
        XCTAssertNil(blocked.asset)
        let directory = try XCTUnwrap(first.asset).directory
        first.close()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertEqual(tight.liveBytes, 0)
        let second = try load(root, "b.png", budget: budget(), cache: tight)
        defer { second.close() }
        XCTAssertEqual(second.descriptor.status, .ready)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(second.asset).fileURL), secondData)
    }

    func testLFSPointersSVGAndHTMLStayPassive() throws {
        let root = try temporaryDirectory()
        let store = try cache(budget: 1024 * 1024)
        let oid = String(repeating: "ab", count: 32)
        let pointer = "version https://git-lfs.github.com/spec/v1\noid sha256:\(oid)\nsize 4096\n"
        try place(Data(pointer.utf8), at: "assets/picture.png", in: root)
        let lfs = try load(root, "assets/picture.png", budget: budget(), cache: store)
        XCTAssertEqual(lfs.descriptor.status, .lfsPointer)
        XCTAssertEqual(lfs.descriptor.lfsOID, oid)
        XCTAssertEqual(lfs.descriptor.lfsObjectBytes, 4096)
        XCTAssertNil(lfs.asset)
        XCTAssertNil(lfs.thumbnail)
        XCTAssertTrue(PreviewLabels.message(lfs.descriptor).contains(String(oid.prefix(12))))
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("assets/picture.png"), encoding: .utf8), pointer)

        try place(Data("<svg xmlns=\"http://www.w3.org/2000/svg\"></svg>\n".utf8), at: "icon.svg", in: root)
        try place(Data("<!DOCTYPE html><html><body>Hi</body></html>\n".utf8), at: "page.html", in: root)
        let svg = try load(root, "icon.svg", budget: budget(), cache: store)
        let html = try load(root, "page.html", budget: budget(), cache: store)
        XCTAssertEqual(svg.descriptor.kind, .svg)
        XCTAssertEqual(svg.descriptor.status, .ready)
        XCTAssertTrue(svg.text?.contains("<svg") == true)
        XCTAssertEqual(html.descriptor.kind, .html)
        XCTAssertEqual(html.text?.contains("<html>") ?? false, true)
        XCTAssertFalse(PreviewLabels.note(svg.descriptor)?.isEmpty ?? true)
        XCTAssertFalse(PreviewLabels.note(html.descriptor)?.isEmpty ?? true)

        let longSVG = Data(("<svg xmlns=\"http://www.w3.org/2000/svg\">" + String(repeating: "a", count: 80) + "</svg>").utf8)
        try place(longSVG, at: "big.svg", in: root)
        let oversizedSVG = try load(root, "big.svg", budget: budget(text: 32), cache: store)
        XCTAssertEqual(oversizedSVG.descriptor.status, .tooLarge(limit: 32))
        XCTAssertEqual(oversizedSVG.descriptor.kind, .svg)
        XCTAssertNil(oversizedSVG.text)
        XCTAssertFalse(PreviewLabels.message(oversizedSVG.descriptor).isEmpty)
    }

    func testTextLimitAndUnsupportedBytesDoNotCopy() throws {
        let root = try temporaryDirectory()
        let store = try cache(budget: 1024 * 1024)
        try place(Data(String(repeating: "a", count: 100).utf8), at: "long.txt", in: root)
        try place(Data(), at: "empty.txt", in: root)
        try place(Data([0, 1, 2, 3, 4]), at: "blob.bin", in: root)
        let limits = budget(text: 16)
        let long = try load(root, "long.txt", budget: limits, cache: store)
        XCTAssertEqual(long.descriptor.status, .tooLarge(limit: 16))
        XCTAssertEqual(long.descriptor.byteCount, 100)
        XCTAssertNil(long.asset)
        XCTAssertEqual(try load(root, "empty.txt", budget: limits, cache: store).text, "")
        let binary = try load(root, "blob.bin", budget: limits, cache: store)
        XCTAssertEqual(binary.descriptor.status, .ready)
        XCTAssertEqual(binary.hex?.data, Data([0, 1, 2, 3, 4]))
        binary.close()
        XCTAssertEqual(binary.descriptor.byteCount, 5)
        let image = try png(width: 8, height: 8)
        XCTAssertGreaterThan(image.count, 32)
        try place(image, at: "big.png", in: root)
        let oversized = try load(root, "big.png", budget: budget(file: 32), cache: store)
        XCTAssertEqual(oversized.descriptor.kind, .image)
        XCTAssertEqual(oversized.descriptor.status, .tooLarge(limit: 32))
        XCTAssertNil(oversized.asset)
        XCTAssertTrue(storedEntries(store).isEmpty)
        XCTAssertFalse(PreviewLabels.message(oversized.descriptor).isEmpty)
    }

    func testByteOrderMarksAreExplicitAndLegacyEncodingsAreNotGuessed() async throws {
        let root = try temporaryDirectory()
        let store = try cache(budget: 1024 * 1024)
        let limits = budget()
        let hello = "你好"
        var utf16 = Data([0xFF, 0xFE])
        utf16.append(try XCTUnwrap(hello.data(using: .utf16LittleEndian)))
        try place(utf16, at: "hello.txt", in: root)
        let marked = try load(root, "hello.txt", budget: limits, cache: store)
        XCTAssertEqual(marked.descriptor.status, .ready)
        XCTAssertEqual(marked.text, hello)
        XCTAssertEqual(marked.encoding, .utf16LE)
        XCTAssertEqual(marked.encodingConfidence, .byteOrderMark)
        XCTAssertEqual(PreviewLabels.encodingCaption(encoding: marked.encoding, confidence: marked.encodingConfidence, locale: Locale(identifier: "en")).contains("UTF-16 LE"), true)
        XCTAssertThrowsError(try GitClient.readText(at: root, relative: "hello.txt"))

        var utf16BE = Data([0xFE, 0xFF])
        utf16BE.append(try XCTUnwrap(hello.data(using: .utf16BigEndian)))
        XCTAssertEqual(try XCTUnwrap(PreviewText.interpret(utf16BE, path: "a.txt")).encoding, .utf16BE)
        var utf32 = Data([0xFF, 0xFE, 0x00, 0x00])
        utf32.append(try XCTUnwrap("A".data(using: .utf32LittleEndian)))
        let wide = try XCTUnwrap(PreviewText.interpret(utf32, path: "a.txt"))
        XCTAssertEqual(wide.encoding, .utf32LE)
        XCTAssertEqual(wide.text, "A")
        XCTAssertEqual(wide.confidence, .byteOrderMark)
        var utf8BOM = Data([0xEF, 0xBB, 0xBF])
        utf8BOM.append(Data("plain\n".utf8))
        let bom8 = try XCTUnwrap(PreviewText.interpret(utf8BOM, path: "a.txt"))
        XCTAssertEqual(bom8.text, "plain\n")
        XCTAssertEqual(bom8.encoding, .utf8)
        XCTAssertEqual(bom8.confidence, .byteOrderMark)

        let markdown = "# 标题\n\nSee [docs](https://example.com/secret) and ![cat](https://cdn.example/a.png).\n<script>alert(1)</script>\n<img src=\"file:///etc/passwd\" alt=\"secret\">\n[local](../README.md)\n"
        let legacy = try XCTUnwrap(markdown.data(using: PreviewTextEncoding.gb18030.stringEncoding))
        XCTAssertNil(String(data: legacy, encoding: .utf8))
        try place(legacy, at: "readme.md", in: root)
        let undecided = try load(root, "readme.md", budget: limits, cache: store)
        XCTAssertEqual(undecided.descriptor.status, .chooseEncoding)
        XCTAssertEqual(undecided.descriptor.kind, .markdown)
        XCTAssertNil(undecided.encoding)
        XCTAssertNil(undecided.text)
        XCTAssertEqual(PreviewText.decode(legacy, as: .gb18030)?.contains("标题"), true)
        XCTAssertNil(PreviewText.decode(Data([0x41]), as: .utf16LE))
        XCTAssertNil(PreviewText.decode(Data([0x41]), as: .utf32LE))
        let utf8 = try XCTUnwrap(PreviewText.interpret(Data("# Title\n".utf8), path: "readme.md"))
        XCTAssertEqual(utf8.encoding, .utf8)
        XCTAssertEqual(utf8.confidence, .unicode)
        XCTAssertEqual(utf8.kind, .markdown)
        XCTAssertNotEqual(utf8.encoding, .gb18030)

        let oversized = Data([0xFF, 0xFE]) + Data(repeating: 0x41, count: 40)
        try place(oversized, at: "big.txt", in: root)
        let tooBig = try load(root, "big.txt", budget: budget(text: 8), cache: store)
        XCTAssertEqual(tooBig.descriptor.status, .tooLarge(limit: 8))
        XCTAssertNil(tooBig.text)

        let rendered = try await MarkdownRenderer.shared.render(markdown).body
        XCTAssertTrue(rendered.contains("标题"))
        XCTAssertTrue(rendered.contains("docs"))
        XCTAssertTrue(rendered.contains("cat"))
        XCTAssertTrue(rendered.contains("local"))
        XCTAssertFalse(rendered.contains("https://"))
        XCTAssertFalse(rendered.contains("cdn.example"))
        XCTAssertFalse(rendered.contains("alert(1)"))
        XCTAssertFalse(rendered.contains("passwd"))
        XCTAssertFalse(rendered.contains("href=\"../"))
        let coded = "Before `https://keep.example/in-code` after.\n![x](https://drop.example/a.png)\n"
        let kept = try await MarkdownRenderer.shared.render(coded).body
        XCTAssertTrue(kept.contains("keep.example"))
        XCTAssertFalse(kept.contains("drop.example"))
        XCTAssertEqual(try Self.translation("This file is not valid UTF-8. Choose an encoding; none was guessed.", "zh-Hans"), "这个文件不是有效的 UTF-8。请选择编码，应用不会猜测。")
        XCTAssertEqual(try Self.translation("Remote images, scripts, and other repository files are not loaded.", "ja"), "リモート画像、スクリプト、リポジトリ内の他のファイルは読み込みません。")
    }

    func testOfficeAndMediaStayReadOnlyAndDoNotGuessArchives() throws {
        XCTAssertEqual(PreviewPackage.match(sample: Data("{\\rtf1 hello}".utf8), path: "notes.txt")?.suffix, "rtf")
        XCTAssertNil(PreviewPackage.match(sample: Data("hello".utf8), path: "report.docx"))
        XCTAssertNil(PreviewPackage.match(sample: zipLocal("readme.txt"), path: "files.zip"))
        XCTAssertEqual(PreviewPackage.match(sample: zipFiles(["[Content_Types].xml", "word/document.xml"]), path: "x.bin")?.suffix, "docx")
        var ole = Data([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1])
        ole.append(Data(count: 8))
        XCTAssertEqual(PreviewPackage.match(sample: ole, path: "sheet.xls")?.suffix, "xls")
        XCTAssertNil(PreviewPackage.match(sample: ole, path: "sheet.txt")?.suffix)
        XCTAssertEqual(PreviewPackage.match(sample: ole, path: "sheet.txt")?.kind, .document)
        XCTAssertEqual(PreviewPackage.match(sample: Data("ID3".utf8) + Data(count: 4), path: "a.bin")?.kind, .audio)
        var wave = Data("RIFF".utf8)
        wave.append(Data(count: 4))
        wave.append(Data("WAVE".utf8))
        XCTAssertEqual(PreviewPackage.match(sample: wave, path: "sound.txt")?.suffix, "wav")
        XCTAssertNil(PreviewPackage.match(sample: Data([0x00, 0x00, 0x00, 0x18]) + Data("ftypheic".utf8), path: "a.mp4"))

        let root = try temporaryDirectory()
        let store = try cache(budget: 1024 * 1024)
        let allow = PreviewSystemSupport(canPreview: { _ in true }, canPlay: { _ in true })
        let deny = PreviewSystemSupport(canPreview: { _ in false }, canPlay: { _ in false })
        let rtf = Data("{\\rtf1\\ansi hello}".utf8)
        let source = try place(rtf, at: "notes.txt", in: root)
        let opened = try WorkspacePreview.load(root: root, path: "notes.txt", cache: store, support: allow)
        defer { opened.close() }
        XCTAssertEqual(opened.descriptor.kind, .document)
        XCTAssertEqual(opened.descriptor.status, .ready)
        let snapshot = try XCTUnwrap(opened.asset)
        XCTAssertEqual(snapshot.fileURL.lastPathComponent, "content.rtf")
        XCTAssertEqual(try Data(contentsOf: snapshot.fileURL), rtf)
        XCTAssertFalse(snapshot.directory.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path))
        XCTAssertEqual(try Data(contentsOf: source), rtf)
        let refused = try WorkspacePreview.load(root: root, path: "notes.txt", cache: store, support: deny)
        XCTAssertEqual(refused.descriptor.status, .systemUnavailable)
        XCTAssertNil(refused.asset)
        XCTAssertTrue(PreviewLabels.message(refused.descriptor, locale: Locale(identifier: "en")).contains("cannot preview") || !PreviewLabels.message(refused.descriptor).isEmpty)

        try place(Data("not a spreadsheet".utf8), at: "report.docx", in: root)
        let textDocument = try load(root, "report.docx", budget: budget(), cache: store)
        XCTAssertEqual(textDocument.descriptor.kind, .text)
        XCTAssertEqual(textDocument.text, "not a spreadsheet")
        try place(zipLocal("readme.txt"), at: "bundle.zip", in: root)
        let archive = try load(root, "bundle.zip", budget: budget(), cache: store)
        XCTAssertEqual(archive.descriptor.status, .ready)
        XCTAssertEqual(archive.archive?.entries.map(\.path), ["readme.txt"])
        XCTAssertNil(archive.asset)
        XCTAssertNotEqual(archive.descriptor.kind, .document)
        try place(ole, at: "mystery.txt", in: root)
        let vague = try load(root, "mystery.txt", budget: budget(), cache: store)
        XCTAssertEqual(vague.descriptor.kind, .document)
        XCTAssertEqual(vague.descriptor.status, .unsupported)
        XCTAssertNil(vague.asset)

        let pointer = "version https://git-lfs.github.com/spec/v1\noid sha256:\(String(repeating: "ab", count: 32))\nsize 99\n"
        try place(Data(pointer.utf8), at: "song.mp3", in: root)
        XCTAssertEqual(try load(root, "song.mp3", budget: budget(), cache: store).descriptor.status, .lfsPointer)
        let wav = wavSample()
        try place(wav, at: "clip.wav", in: root)
        let playable = try WorkspacePreview.load(root: root, path: "clip.wav", cache: store, support: allow)
        defer { playable.close() }
        XCTAssertEqual(playable.descriptor.kind, .audio)
        XCTAssertEqual(playable.descriptor.status, .ready)
        XCTAssertEqual(try XCTUnwrap(playable.asset).fileURL.lastPathComponent, "content.wav")
        let silent = try WorkspacePreview.load(root: root, path: "clip.wav", cache: store, support: deny)
        XCTAssertEqual(silent.descriptor.status, .systemUnavailable)
        XCTAssertNil(silent.asset)
        let tooBig = try WorkspacePreview.load(root: root, path: "clip.wav", budget: budget(file: 8), cache: store, support: allow)
        XCTAssertEqual(tooBig.descriptor.kind, .audio)
        XCTAssertEqual(tooBig.descriptor.status, .tooLarge(limit: 8))
        XCTAssertNil(tooBig.asset)
        _ = PreviewPlayback.canPlay(try place(wav, at: "live.wav", in: root), timeout: 0)
        _ = PreviewQuickLook.canPreview(source)
        XCTAssertEqual(try Self.translation("Press play to start. Playback does not start automatically.", "zh-Hans"), "按下播放后才开始。不会自动播放。")
        XCTAssertEqual(try Self.translation("Preview is read-only. Changes in the preview are not saved.", "ja"), "プレビューは読み取り専用です。プレビュー内の変更は保存されません。")
    }

    func testMissingHistoryRepositoryAndMessagesAreTranslated() throws {
        let store = try cache(budget: 1)
        let deferred = try WorkspacePreview.load(source: .blob(oid: String(repeating: "c", count: 40), path: "a.png"), root: store.root, cache: store)
        XCTAssertEqual(deferred.descriptor.status, .missingObject)
        XCTAssertEqual(try Self.translation("This PDF is encrypted and was not unlocked.", "zh-Hans"), "这份 PDF 已加密，没有解锁。")
        XCTAssertEqual(try Self.translation("This PDF is encrypted and was not unlocked.", "ja"), "このPDFは暗号化されており、ロックは解除していません。")
        XCTAssertEqual(try Self.translation("This PDF is damaged and could not be opened.", "zh-Hans"), "这份 PDF 已损坏，无法打开。")
        XCTAssertEqual(try Self.translation("This PDF could not be read.", "ja"), "このPDFを読み取れません。")
        XCTAssertEqual(try Self.translation("SVG is shown as source text and is not rendered.", "zh-Hans"), "SVG 以源码显示，不会按图像渲染。")
        XCTAssertEqual(try Self.translation("HTML is shown as source text and is not loaded as a page.", "ja"), "HTMLはソースとして表示し、ページとしては読み込みません。")
    }

    func testFixedCommitPreviewsIgnoreBrokenIndexMissingWorktreeAndMovedReferences() throws {
        let fixture = try CommitComparisonFixture(self)
        let old = try fixture.blob(png(width: 12, height: 7)), new = try fixture.blob(png(width: 23, height: 9))
        let legacy = try fixture.blob(try XCTUnwrap("历史文本".data(using: PreviewTextEncoding.gb18030.stringEncoding)))
        let link = try fixture.blob("/outside/must-not-open")
        let base = try fixture.commit(["folder/photo.png": (old, 0o100644), "legacy.md": (legacy, 0o100644), "link": (link, 0o120000), "module": (String(repeating: "a", count: 40), 0o160000)])
        let target = try fixture.commit(["folder/photo.png": (new, 0o100644)], parents: [base])
        try fixture.reference("refs/heads/main", target)
        try Data("broken index".utf8).write(to: fixture.repo.appendingPathComponent(".git/index"))
        try WorktreeLink.save(repoName: fixture.repo.lastPathComponent, data: Data("invalid bookmark".utf8))
        let before = try fixture.snapshot(), store = try cache(budget: 1024 * 1024)
        let a = try GitClient.previewRevision(at: fixture.repo, commit: base, path: "folder/photo.png", cache: store)
        let b = try GitClient.previewRevision(at: fixture.repo, commit: target, path: "folder/photo.png", cache: store)
        XCTAssertEqual(a.descriptor.pixelWidth, 12); XCTAssertEqual(b.descriptor.pixelWidth, 23)
        XCTAssertEqual(a.descriptor.source, .blob(oid: base, path: "folder/photo.png"))
        let text = try GitClient.previewRevision(at: fixture.repo, commit: base, path: "legacy.md", cache: store)
        XCTAssertEqual(text.descriptor.status, .chooseEncoding)
        XCTAssertEqual(PreviewText.decode(try XCTUnwrap(text.textBytes), as: .gb18030), "历史文本")
        let symlink = try GitClient.previewRevision(at: fixture.repo, commit: base, path: "link", cache: store)
        XCTAssertEqual(symlink.descriptor.status, .symlink)
        XCTAssertEqual(symlink.descriptor.recordedTarget, "/outside/must-not-open")
        let module = try GitClient.previewRevision(at: fixture.repo, commit: base, path: "module", cache: store)
        XCTAssertEqual(module.descriptor.status, .gitlink)
        XCTAssertEqual(module.descriptor.recordedTarget, String(repeating: "a", count: 40))
        XCTAssertEqual(try GitClient.previewRevision(at: fixture.repo, commit: base, path: "folder", cache: store).descriptor.status, .directory)
        XCTAssertEqual(try GitClient.previewRevision(at: fixture.repo, commit: target, path: "legacy.md", cache: store).descriptor.status, .missing)
        a.close(); b.close(); text.close()
        XCTAssertEqual(store.liveBytes, 0)
        XCTAssertEqual(try fixture.snapshot(), before)
    }

    func testHistoricalObjectBudgetMissingCorruptAndCancelledReadsReleaseCache() throws {
        let fixture = try CommitComparisonFixture(self), data = Data(repeating: 0x91, count: 256 * 1024)
        let blob = try fixture.blob(data), commit = try fixture.commit(["blob.bin": (blob, 0o100644)])
        let store = try cache(budget: 2 * 1024 * 1024)
        let small = try GitClient.previewRevision(at: fixture.repo, commit: commit, path: "blob.bin", budget: budget(file: 16), cache: store)
        XCTAssertEqual(small.descriptor.status, .tooLarge(limit: 16)); XCTAssertEqual(store.liveBytes, 0)
        XCTAssertEqual(try GitClient.previewRevision(at: fixture.repo, commit: blob, path: "blob.bin", cache: store).descriptor.status, .unreadable)
        XCTAssertEqual(try GitClient.previewRevision(at: fixture.repo, commit: String(repeating: "f", count: 40), path: "blob.bin", cache: store).descriptor.status, .missingObject)
        XCTAssertEqual(try GitClient.previewRevision(at: fixture.repo, commit: "HEAD", path: "blob.bin", cache: store).descriptor.status, .unreadable)
        let quota = try cache(budget: 1)
        XCTAssertEqual(try GitClient.previewRevision(at: fixture.repo, commit: commit, path: "blob.bin", cache: quota).descriptor.status, .cacheFull)
        let token = PreviewCancellation()
        let progress = PreviewProgressRelay(schedule: { $0() }, deliver: { _ in token.cancel() })
        XCTAssertThrowsError(try GitClient.previewRevision(at: fixture.repo, commit: commit, path: "blob.bin", cache: store, token: token, progress: progress)) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(store.liveBytes, 0); XCTAssertTrue(storedEntries(store).isEmpty)
        let loose = fixture.repo.appendingPathComponent(".git/objects/" + blob.prefix(2) + "/" + blob.dropFirst(2))
        try Data("corrupted".utf8).write(to: loose, options: .atomic)
        XCTAssertEqual(try GitClient.previewRevision(at: fixture.repo, commit: commit, path: "blob.bin", cache: store).descriptor.status, .unreadable)
        try FileManager.default.removeItem(at: loose)
        XCTAssertEqual(try GitClient.previewRevision(at: fixture.repo, commit: commit, path: "blob.bin", cache: store).descriptor.status, .missingObject)
    }

    func testArchiveUsesCentralDirectoryAndNeverExtractsUnsafeEntries() throws {
        let root = try temporaryDirectory(), store = try cache(budget: 2 * 1024 * 1024)
        let names = ["safe.txt", "../outside.txt", "/absolute", "目录/中文.txt"]
        try place(zipFiles(names), at: "archive.zip", in: root)
        let loaded = try WorkspacePreview.load(root: root, path: "archive.zip", cache: store)
        XCTAssertEqual(loaded.archive?.entries.map(\.path), names)
        XCTAssertEqual(loaded.archive?.entries.filter(\.unsafePath).count, 2)
        XCTAssertNil(loaded.asset); XCTAssertEqual(store.liveBytes, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["archive.zip"])
        XCTAssertNil(PreviewPackage.match(sample: Data([0x50, 0x4b, 3, 4]) + Data("word/document.xml".utf8), path: "spoof.docx"))
        XCTAssertNil(PreviewPackage.match(sample: zipFiles(["word/document.xml"]), path: "spoof.docx"))
        let index = try PreviewArchive.index(data: zipFiles((0..<2005).map { "file-\($0)" }))
        XCTAssertEqual(index.entries.count, 2000); XCTAssertEqual(index.total, 2005); XCTAssertTrue(index.truncated)
        var corrupt = zipFiles(["x"]); corrupt.removeLast()
        XCTAssertThrowsError(try PreviewArchive.index(data: corrupt))
        var zip64 = zipFiles(["x"])
        zip64.replaceSubrange((zip64.count - 12)..<(zip64.count - 10), with: [0xff, 0xff])
        XCTAssertThrowsError(try PreviewArchive.index(data: zip64))
    }

    func testOfficeMarkerPastFirst256KiBIsRecognizedWithoutScanningPayload() throws {
        let root = try temporaryDirectory(), store = try cache(budget: 4 * 1024 * 1024)
        let names = (0..<1500).map { String(repeating: "a", count: 100) + "-\($0)" } + ["[Content_Types].xml", "word/document.xml"]
        let package = zipFiles(names)
        XCTAssertGreaterThan(package.count, 256 * 1024)
        try place(package, at: "large-package.bin", in: root)
        let loaded = try WorkspacePreview.load(root: root, path: "large-package.bin", cache: store,
                                              support: .init(canPreview: { _ in true }, canPlay: { _ in false }))
        XCTAssertEqual(loaded.descriptor.kind, .document)
        XCTAssertEqual(loaded.asset?.fileURL.pathExtension, "docx")
        loaded.close(); XCTAssertEqual(store.liveBytes, 0)
        XCTAssertThrowsError(try PreviewArchive.index(data: zipFiles((0..<8000).map { String(repeating: "b", count: 128) + "\($0)" })))
    }

    func testHexPagesStayBoundedAndUseAnImmutableSnapshot() throws {
        let root = try temporaryDirectory(), store = try cache(budget: 1024 * 1024)
        let data = Data((0..<10000).map { UInt8($0 % 256) })
        let source = try place(data, at: "raw.bin", in: root)
        let loaded = try WorkspacePreview.load(root: root, path: "raw.bin", cache: store)
        XCTAssertEqual(loaded.descriptor.kind, .binary)
        XCTAssertEqual(loaded.hex?.data, data.prefix(4096))
        let url = try XCTUnwrap(loaded.asset?.fileURL)
        try Data([0]).write(to: source)
        let second = try PreviewHexPage.read(url: url, offset: 4096, token: PreviewCancellation())
        XCTAssertEqual(second.data, data.subdata(in: 4096..<8192)); XCTAssertTrue(second.hasNext)
        XCTAssertTrue(second.text.hasPrefix("00001000"))
        let last = try PreviewHexPage.read(url: url, offset: 8192, token: PreviewCancellation())
        XCTAssertEqual(last.data.count, 1808); XCTAssertFalse(last.hasNext)
        XCTAssertThrowsError(try PreviewHexPage.read(url: url, offset: -1, token: PreviewCancellation()))
        XCTAssertThrowsError(try PreviewHexPage.read(url: url, offset: 10001, token: PreviewCancellation()))
        loaded.close(); XCTAssertFalse(FileManager.default.fileExists(atPath: url.path)); XCTAssertEqual(store.liveBytes, 0)
    }

    func testReplacingParentDirectoryDuringSnapshotIsDetected() throws {
        let root = try temporaryDirectory(), store = try cache(budget: 1024 * 1024)
        try place(png(width: 12, height: 12), at: "nested/a.png", in: root)
        let result = try WorkspacePreview.load(root: root, path: "nested/a.png", cache: store, whileReading: {
            try? FileManager.default.moveItem(at: root.appendingPathComponent("nested"), to: root.appendingPathComponent("parked"))
            try? FileManager.default.createDirectory(at: root.appendingPathComponent("nested"), withIntermediateDirectories: true)
        })
        XCTAssertEqual(result.descriptor.status, .changed); XCTAssertNil(result.asset); XCTAssertEqual(store.liveBytes, 0)
    }

    func testMarkdownAppliesSemanticStylesAndUnicodeFontRanges() async throws {
        let text = try await MarkdownRenderer.shared.render("# 标题\n\n**重点** and *斜体* and `代码`")
        XCTAssertTrue(text.body.contains("<h1>标题</h1>"))
        XCTAssertTrue(text.body.contains("<p><strong>重点</strong> and <em>斜体</em> and <code>代码</code></p>"))
        let html = text.html(pointSize: 28, dark: false, imagesAllowed: false)
        XCTAssertTrue(html.contains("28.0px/1.5"))
        XCTAssertEqual(PreviewText.interpret(Data([0xff, 0xfe, 0x41]), path: "odd.txt")?.status, .chooseEncoding)
    }

    func testMediaProbeHasADeadlineAndRejectsExternalReferences() throws {
        let root = try temporaryDirectory(), url = try place(wavSample(), at: "clip.wav", in: root)
        XCTAssertEqual(PreviewPlayback.asset(url).referenceRestrictions, .forbidAll)
        let start = Date()
        _ = PreviewPlayback.canPlay(url, timeout: 0)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    private static func translation(_ key: String, _ language: String) throws -> String {
        let path = try XCTUnwrap(Bundle.main.path(forResource: language, ofType: "lproj"))
        let bundle = try XCTUnwrap(Bundle(path: path))
        let value = bundle.localizedString(forKey: key, value: "MISSING", table: "Localizable")
        XCTAssertNotEqual(value, "MISSING")
        XCTAssertNotEqual(value, key)
        return value
    }

    func testPreviewLeavesHeadIndexAndWorktreeUnchanged() throws {
        let container = try temporaryDirectory()
        let name = "preview-" + UUID().uuidString
        try GitClient.initialize(name: name, root: container)
        let repo = container.appendingPathComponent(name)
        addTeardownBlock { WorktreeLink.remove(repoName: name) }
        let image = try png(width: 20, height: 12)
        let deep = "资料/嵌入式英语/截图/screen.png"
        try place(image, at: deep, in: repo)
        try place(Data("tracked\n".utf8), at: "readme.txt", in: repo)
        try GitClient.stageAll(at: repo)
        try GitClient.commit(at: repo, message: "add preview files", name: "Preview Author", email: "preview@example.invalid")
        try place(Data("unstaged\n".utf8), at: "readme.txt", in: repo)
        try place(Data("untracked\n".utf8), at: "note.txt", in: repo)
        try place(Data("staged\n".utf8), at: "staged.txt", in: repo)
        try GitClient.stage(at: repo, path: "staged.txt")
        try FileManager.default.createSymbolicLink(at: repo.appendingPathComponent("link.png"), withDestinationURL: repo.appendingPathComponent(deep))
        let head = try GitClient.history(at: repo, limit: 1)[0].id
        let index = try Data(contentsOf: repo.appendingPathComponent(".git/index"))
        let status = try GitClient.status(at: repo)
        let store = try cache(budget: 1024 * 1024)
        let result = try GitClient.previewWorktree(at: repo, path: deep, budget: budget(), cache: store)
        defer { result.close() }
        XCTAssertEqual(result.descriptor.kind, .image)
        XCTAssertEqual(result.descriptor.status, .ready)
        XCTAssertEqual(try GitClient.history(at: repo, limit: 1)[0].id, head)
        XCTAssertEqual(try Data(contentsOf: repo.appendingPathComponent(".git/index")), index)
        XCTAssertEqual(try GitClient.status(at: repo), status)
        XCTAssertEqual(try Data(contentsOf: repo.appendingPathComponent(deep)), image)
        XCTAssertEqual(try String(contentsOf: repo.appendingPathComponent("readme.txt"), encoding: .utf8), "unstaged\n")
        XCTAssertEqual(try String(contentsOf: repo.appendingPathComponent("note.txt"), encoding: .utf8), "untracked\n")
        XCTAssertEqual(try String(contentsOf: repo.appendingPathComponent("staged.txt"), encoding: .utf8), "staged\n")
        XCTAssertEqual(try GitClient.previewWorktree(at: repo, path: "link.png", budget: budget(), cache: store).descriptor.status, .symlink)

        try WorktreeLink.save(repoName: name, data: Data("not-a-bookmark".utf8))
        let denied = try GitClient.previewWorktree(at: repo, path: deep, budget: budget(), cache: store)
        XCTAssertEqual(denied.descriptor.status, .accessDenied)
        XCTAssertNil(denied.asset)
        XCTAssertEqual(try Data(contentsOf: repo.appendingPathComponent(deep)), image)
    }

    func testProgressKeepsTheLatestCopyCountAndWorkStaysSerial() async throws {
        final class Box: @unchecked Sendable { var scheduled: [() -> Void] = []; var seen: [PreviewCopyProgress] = [] }
        let box = Box()
        let relay = PreviewProgressRelay(schedule: { work in box.scheduled.append(work) }, deliver: { box.seen.append($0) })
        relay.update(copied: 1, total: 100)
        relay.update(copied: 40, total: 100)
        relay.update(copied: 100, total: 100)
        XCTAssertEqual(box.scheduled.count, 1)
        box.scheduled[0]()
        XCTAssertEqual(box.seen, [PreviewCopyProgress(copied: 100, total: 100)])
        relay.invalidate()
        relay.update(copied: 5, total: 100)
        box.scheduled[0]()
        XCTAssertEqual(box.seen.count, 1)

        let coordinator = PreviewCoordinator()
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let first = Task.detached {
            coordinator.run { () -> Int in
                entered.signal()
                release.wait()
                return 1
            }
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        let second = Task.detached { coordinator.run { 2 } }
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(coordinator.currentActive, 1)
        XCTAssertEqual(coordinator.peak, 1)
        release.signal()
        let firstValue = try await first.value
        let secondValue = try await second.value
        XCTAssertEqual(firstValue, 1)
        XCTAssertEqual(secondValue, 2)
        XCTAssertEqual(coordinator.peak, 1)
        XCTAssertEqual(coordinator.currentActive, 0)
    }

    private func zipLocal(_ name: String) -> Data { zipFiles([name]) }
    private func zipFiles(_ names: [String]) -> Data {
        var data = Data(), directory = Data()
        for name in names {
            let offset = UInt32(data.count), bytes = Data(name.utf8)
            data.append(little(UInt32(0x04034b50)))
            data.append(little(UInt16(20))); data.append(little(UInt16(0x800)))
            data.append(Data(count: 18)); data.append(little(UInt16(bytes.count))); data.append(little(UInt16(0)))
            data.append(bytes)
            directory.append(little(UInt32(0x02014b50)))
            directory.append(little(UInt16(20))); directory.append(little(UInt16(20))); directory.append(little(UInt16(0x800)))
            directory.append(Data(count: 18)); directory.append(little(UInt16(bytes.count)))
            directory.append(Data(count: 12)); directory.append(little(offset)); directory.append(bytes)
        }
        let start = UInt32(data.count); data.append(directory)
        data.append(little(UInt32(0x06054b50))); data.append(Data(count: 4))
        data.append(little(UInt16(names.count))); data.append(little(UInt16(names.count)))
        data.append(little(UInt32(directory.count))); data.append(little(start)); data.append(little(UInt16(0)))
        return data
    }

    private func wavSample() -> Data {
        var data = Data("RIFF".utf8)
        data.append(little(UInt32(38)))
        data.append(Data("WAVEfmt ".utf8))
        data.append(little(UInt32(16)))
        data.append(little(UInt16(1)))
        data.append(little(UInt16(1)))
        data.append(little(UInt32(8_000)))
        data.append(little(UInt32(8_000)))
        data.append(little(UInt16(1)))
        data.append(little(UInt16(8)))
        data.append(Data("data".utf8))
        data.append(little(UInt32(1)))
        data.append(0x80)
        return data
    }

    private func little<T: FixedWidthInteger>(_ value: T) -> Data {
        var little = value.littleEndian
        return Data(bytes: &little, count: MemoryLayout<T>.size)
    }

    private func uint32(_ value: UInt32) -> Data {
        var big = value.bigEndian
        return Data(bytes: &big, count: 4)
    }

    private func chunk(_ type: String, _ payload: Data) -> Data {
        var output = uint32(UInt32(payload.count))
        let name = Data(type.utf8)
        output.append(name)
        output.append(payload)
        let crc = (name + payload).withUnsafeBytes { buffer in
            UInt32(truncatingIfNeeded: crc32(0, buffer.bindMemory(to: UInt8.self).baseAddress, uInt(buffer.count)))
        }
        output.append(uint32(crc))
        return output
    }

    private func pdf(pages: Int, password: String? = nil) throws -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16))
        let image = renderer.image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        }
        let document = PDFDocument()
        let page = try XCTUnwrap(PDFPage(image: image))
        for index in 0..<pages {
            if index == 0 { document.insert(page, at: 0) }
            else { document.insert(try XCTUnwrap(PDFPage(image: image)), at: document.pageCount) }
        }
        guard let password else { return try XCTUnwrap(document.dataRepresentation()) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(document.write(to: url, withOptions: [
            PDFDocumentWriteOption.userPasswordOption: password,
            PDFDocumentWriteOption.ownerPasswordOption: password + "-owner",
        ]))
        return try Data(contentsOf: url)
    }
}

@MainActor
final class WorkspacePreviewInterfaceTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("preview-ui-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testHistorySwitchingAndHexPagingKeepOnlyTheCurrentSnapshot() async throws {
        let fixture = try CommitComparisonFixture(self)
        let first = try fixture.commit(["note.txt": (try fixture.blob("first version"), 0o100644),
                                        "raw.bin": (try fixture.blob(Data((0..<10000).map { UInt8($0 % 256) })), 0o100644)])
        let second = try fixture.commit(["note.txt": (try fixture.blob("second version"), 0o100644)], parents: [first])
        let cache = PreviewCache(root: try temporaryDirectory(), byteBudget: 1024 * 1024)
        let model = WorkspacePreviewModel(cache: cache, coordinator: PreviewCoordinator())
        await model.load(repo: fixture.repo, source: .blob(oid: first, path: "note.txt"))
        if case .text(let state) = model.phase { XCTAssertEqual(state.text, "first version") } else { XCTFail("Expected first fixed version") }
        await model.load(repo: fixture.repo, source: .blob(oid: second, path: "note.txt"))
        if case .text(let state) = model.phase { XCTAssertEqual(state.text, "second version") } else { XCTFail("Expected second fixed version") }
        await model.load(repo: fixture.repo, source: .blob(oid: first, path: "raw.bin"))
        await model.moveHexPage(1)
        if case .hex(let page, false) = model.phase { XCTAssertEqual(page.offset, 4096) } else { XCTFail("Expected second hex page") }
        await model.moveHexPage(1)
        if case .hex(let page, false) = model.phase { XCTAssertEqual(page.offset, 8192); XCTAssertFalse(page.hasNext) } else { XCTFail("Expected last hex page") }
        await model.load(repo: fixture.repo, source: .blob(oid: second, path: "note.txt"))
        XCTAssertEqual(cache.liveBytes, 0)
        await model.moveHexPage(-1)
        if case .text(let state) = model.phase { XCTAssertEqual(state.text, "second version") } else { XCTFail("Stale hex state replaced text") }
        model.cancel(); XCTAssertEqual(cache.liveBytes, 0)
    }

    func testPlayerSwitchesAssetsAndDismantleStopsPlayback() async throws {
        let root = try temporaryDirectory()
        let first = root.appendingPathComponent("a.wav"), second = root.appendingPathComponent("b.wav")
        try Data().write(to: first); try Data().write(to: second)
        let host = UIHostingController(rootView: WorkspacePlayerPreview(url: first))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 346, height: 640)
        window.rootViewController = host; window.makeKeyAndVisible(); host.view.layoutIfNeeded()
        defer { window.isHidden = true; window.rootViewController = nil }
        let controller: AVPlayerViewController = try XCTUnwrap(findController(from: host.view))
        let old = try XCTUnwrap(controller.player)
        host.rootView = WorkspacePlayerPreview(url: second)
        for _ in 0..<50 {
            if (controller.player?.currentItem?.asset as? AVURLAsset)?.url == second { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual((controller.player?.currentItem?.asset as? AVURLAsset)?.url, second)
        XCTAssertEqual((controller.player?.currentItem?.asset as? AVURLAsset)?.referenceRestrictions, .forbidAll)
        XCTAssertNil(old.currentItem)
        XCTAssertEqual(controller.player?.rate, 0)
        WorkspacePlayerPreview.dismantleUIViewController(controller, coordinator: WorkspacePlayerPreview.Coordinator())
        XCTAssertNil(controller.player)
    }

    func testDocumentPreviewSwitchesFixedSnapshotsWithoutRecreatingController() async throws {
        let root = try temporaryDirectory()
        let first = root.appendingPathComponent("base.rtf"), second = root.appendingPathComponent("target.rtf")
        try Data("{\\rtf1 Base}".utf8).write(to: first)
        try Data("{\\rtf1 Target}".utf8).write(to: second)
        let host = UIHostingController(rootView: WorkspaceQuickLookPreview(url: first))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 346, height: 640)
        window.rootViewController = host; window.makeKeyAndVisible(); host.view.layoutIfNeeded()
        defer { window.isHidden = true; window.rootViewController = nil }
        let controller: QLPreviewController = try XCTUnwrap(findController(from: host.view))
        func itemURL() -> URL? { controller.dataSource?.previewController(controller, previewItemAt: 0).previewItemURL }
        XCTAssertEqual(itemURL(), first)
        host.rootView = WorkspaceQuickLookPreview(url: second)
        for _ in 0..<50 where itemURL() != second { try await Task.sleep(for: .milliseconds(10)) }
        let current: QLPreviewController? = findController(from: host.view)
        XCTAssertTrue(current === controller)
        XCTAssertEqual(itemURL(), second)
        XCTAssertEqual(try Data(contentsOf: first), Data("{\\rtf1 Base}".utf8))
    }

    private final class MarkdownState: ObservableObject {
        @Published var source = "**same**"
        @Published var size = DynamicTypeSize.large
    }
    private struct MarkdownHarness: View {
        @ObservedObject var state: MarkdownState
        var body: some View { PreviewMarkdownView(markdown: state.source).environment(\.dynamicTypeSize, state.size) }
    }

    func testMarkdownUpdatesFormattingWithSameTextAndTracksDynamicType() async throws {
        let state = MarkdownState(), host = UIHostingController(rootView: MarkdownHarness(state: MarkdownState()))
        host.rootView = MarkdownHarness(state: state)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 346, height: 640)
        window.rootViewController = host; window.makeKeyAndVisible(); host.view.layoutIfNeeded()
        defer { window.isHidden = true; window.rootViewController = nil }
        func descendants(_ view: UIView) -> [UIView] { view.subviews.flatMap { [$0] + descendants($0) } }
        let view = try XCTUnwrap(descendants(host.view).compactMap { $0 as? WKWebView }.first)
        func value(_ script: String) async -> String { (try? await view.evaluateJavaScript(script)) as? String ?? "" }
        for _ in 0..<200 {
            if await value("document.querySelector('strong')?.textContent") == "same" { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let boldText = await value("document.querySelector('strong')?.textContent")
        XCTAssertEqual(boldText, "same")
        let normal = await value("getComputedStyle(document.body).fontSize")
        state.source = "same"
        for _ in 0..<200 {
            if await value("document.querySelector('p')?.textContent") == "same", await value("String(document.querySelector('strong'))") == "null" { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let strong = await value("String(document.querySelector('strong'))")
        XCTAssertEqual(strong, "null")
        state.size = .accessibility3
        for _ in 0..<200 {
            if await value("document.querySelector('p')?.textContent") == "same", await value("getComputedStyle(document.body).fontSize") != normal { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let large = await value("getComputedStyle(document.body).fontSize")
        XCTAssertGreaterThan(Double(large.replacingOccurrences(of: "px", with: "")) ?? 0, (Double(normal.replacingOccurrences(of: "px", with: "")) ?? 17) * 1.3)
        XCTAssertFalse(view.configuration.defaultWebpagePreferences.allowsContentJavaScript)
        XCTAssertFalse(view.configuration.websiteDataStore.isPersistent)
        window.frame.size.width = 619
        host.view.frame = window.bounds
        host.view.setNeedsLayout(); host.view.layoutIfNeeded()
        for _ in 0..<100 where view.bounds.width < host.view.bounds.width - 2 {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertEqual(view.bounds.width, host.view.bounds.width, accuracy: 2)
    }

    func testVersionPreviewHeaderRemainsScrollableAndLeavesRoomForContent() async throws {
        let repo = try temporaryDirectory()
        let base = ComparisonEndpoint(oid: String(repeating: "a", count: 40), input: "base", source: .oidPrefix, summary: "Base", author: "Test", date: .distantPast)
        let target = ComparisonEndpoint(oid: String(repeating: "b", count: 40), input: "target", source: .oidPrefix, summary: "Target", author: "Test", date: .distantPast)
        let path = String(repeating: "很长的目录/", count: 18) + "image.png"
        let file = ComparisonFile(baseOID: base.oid, targetOID: target.oid, change: .modified, oldPath: path, newPath: path)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        for locale in ["en", "zh-Hans", "ja"] {
            for width: CGFloat in [240, 346, 466, 619, 951] {
                let host = UIHostingController(rootView: ComparisonVersionPreviewPage(repo: repo, comparison: .init(base: base, target: target), file: file)
                    .environment(\.locale, Locale(identifier: locale)).environment(\.dynamicTypeSize, .accessibility3))
                let window = UIWindow(windowScene: scene)
                window.frame = CGRect(x: 0, y: 0, width: width, height: 640)
                window.rootViewController = host; window.makeKeyAndVisible(); host.view.layoutIfNeeded(); window.layoutIfNeeded()
                defer { window.isHidden = true; window.rootViewController = nil }
                try await Task.sleep(for: .milliseconds(20))
                func descendants(_ view: UIView) -> [UIView] { view.subviews.flatMap { [$0] + descendants($0) } }
                let scrolls = descendants(host.view).compactMap { $0 as? UIScrollView }
                let scroll = try XCTUnwrap(scrolls.first)
                // HostingScrollView extends under the safe area. Test its visible
                // viewport rather than counting the status-bar inset as header space.
                let visible = scroll.bounds.height - scroll.adjustedContentInset.top - scroll.adjustedContentInset.bottom
                XCTAssertLessThanOrEqual(visible, 241)
                XCTAssertGreaterThan(visible, 0)
                XCTAssertGreaterThan(scroll.contentSize.height, scroll.bounds.height)
            }
        }
    }

    func testLateResultsAreDroppedAndEncryptedPDFsStayClosed() async throws {
        let root = try temporaryDirectory()
        let store = PreviewCache(root: try temporaryDirectory(), byteBudget: 1024 * 1024)
        let image = NSMutableData()
        let picture = try bitmap(width: 16, height: 16)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(image, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, picture, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let firstURL = root.appendingPathComponent("a.png")
        let secondURL = root.appendingPathComponent("b.png")
        try (image as Data).write(to: firstURL)
        try (image as Data).write(to: secondURL)
        let model = WorkspacePreviewModel(cache: store, coordinator: PreviewCoordinator())
        let first = model.begin()
        let second = model.begin()
        let stale = try WorkspacePreview.load(root: root, path: "a.png", cache: store)
        XCTAssertFalse(model.receive(generation: first, result: stale))
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(stale.asset).directory.path))
        if case .loading = model.phase {} else { XCTFail("Late preview changed the visible phase") }
        let fresh = try WorkspacePreview.load(root: root, path: "b.png", cache: store)
        XCTAssertTrue(model.receive(generation: second, result: fresh))
        guard case .image = model.phase else { return XCTFail("Expected the current image") }

        let encrypted = try encryptedPDF()
        try encrypted.write(to: root.appendingPathComponent("secret.pdf"))
        await model.load(repo: root, path: "secret.pdf")
        guard case .notice(let message) = model.phase else { return XCTFail("Encrypted PDF was presented") }
        XCTAssertEqual(message, PreviewLabels.message(PreviewDescriptor(source: .worktree("secret.pdf"), kind: .pdf, status: .encrypted)))
        XCTAssertTrue(((FileManager.default.enumerator(at: store.root, includingPropertiesForKeys: nil)?.allObjects as? [URL]) ?? []).isEmpty)
        model.cancel()
    }

    func testManualEncodingIsLabeledAndMarkdownRenderingStaysLocal() async throws {
        let root = try temporaryDirectory()
        let store = PreviewCache(root: try temporaryDirectory(), byteBudget: 1024 * 1024)
        let markdown = "# 标题\n\n![cat](https://cdn.example/a.png)\n"
        let bytes = try XCTUnwrap(markdown.data(using: PreviewTextEncoding.gb18030.stringEncoding))
        try bytes.write(to: root.appendingPathComponent("readme.md"))
        let loaded = try WorkspacePreview.load(root: root, path: "readme.md", cache: store)
        let model = WorkspacePreviewModel(cache: store, coordinator: PreviewCoordinator())
        let generation = model.begin()
        XCTAssertTrue(model.receive(generation: generation, result: loaded))
        model.choose(.utf8)
        if case .text(let failed) = model.phase {
            XCTAssertEqual(failed.confidence, .manual)
            XCTAssertFalse(failed.failure?.isEmpty ?? true)
            XCTAssertTrue(failed.text.isEmpty)
        } else {
            XCTFail("Expected the rejected encoding to stay on the text page")
        }
        model.choose(.gb18030)
        guard case .text(let decoded) = model.phase else { return XCTFail("Expected decoded Markdown") }
        XCTAssertEqual(decoded.confidence, .manual)
        XCTAssertEqual(decoded.kind, .markdown)
        XCTAssertTrue(decoded.text.contains("标题"))
        XCTAssertNotEqual(decoded.confidence, .unicode)
        XCTAssertNotEqual(decoded.confidence, .byteOrderMark)
        let rendered = try await MarkdownRenderer.shared.render(decoded.text).body
        XCTAssertFalse(rendered.contains("cdn.example"))
        XCTAssertTrue(rendered.contains("cat"))

        let host = UIHostingController(rootView: PreviewMarkdownView(markdown: decoded.text))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        let web = find(WKWebView.self, in: host.view)
        XCTAssertNotNil(web)
        XCTAssertFalse(web?.configuration.defaultWebpagePreferences.allowsContentJavaScript ?? true)
        XCTAssertFalse(web?.configuration.websiteDataStore.isPersistent ?? true)
        window.isHidden = true
    }

    func testEncodingAndMarkdownControlsFitDuoWidths() {
        struct Harness: View {
            @State var mode = PreviewMarkdownMode.rendered
            var body: some View {
                PreviewTextPage(
                    state: WorkspacePreviewModel.TextState(
                        text: "# 标题", spans: [], note: nil, kind: .markdown, encoding: .gb18030, confidence: .manual,
                        detectedEncoding: nil, detectedConfidence: nil, bytes: Data(), prompt: nil, failure: nil
                    ),
                    markdownMode: $mode,
                    choose: { _ in }
                )
            }
        }
        for width: CGFloat in [240, 346, 466, 951] {
            let host = UIHostingController(rootView: Harness().environment(\.dynamicTypeSize, .accessibility3))
            let size = host.sizeThatFits(in: CGSize(width: width, height: 10_000))
            XCTAssertLessThanOrEqual(size.width, width + 0.5)
            XCTAssertGreaterThan(size.height, 20)
            XCTAssertTrue(size.height.isFinite)
        }
    }

    func testPlaybackDoesNotStartByItself() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        var data = Data("RIFF".utf8)
        func put<T: FixedWidthInteger>(_ value: T) { var little = value.littleEndian; data.append(Data(bytes: &little, count: MemoryLayout<T>.size)) }
        data.append(Data(count: 4))
        data.append(Data("WAVEfmt ".utf8))
        put(UInt32(16)); put(UInt16(1)); put(UInt16(1)); put(UInt32(8_000)); put(UInt32(8_000)); put(UInt16(1)); put(UInt16(8))
        data.append(Data("data".utf8)); put(UInt32(1)); data.append(0x80)
        let size = UInt32(data.count - 8)
        data.replaceSubrange(4..<8, with: Data(bytes: [UInt8(size & 0xFF), UInt8((size >> 8) & 0xFF), UInt8((size >> 16) & 0xFF), UInt8((size >> 24) & 0xFF)]))
        try data.write(to: url)
        let host = UIHostingController(rootView: WorkspacePlayerPreview(url: url))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        let player: AVPlayerViewController? = findController(from: host.view)
        XCTAssertEqual(player?.player?.rate, 0)
        XCTAssertNotEqual(player?.player?.timeControlStatus, .playing)
        XCTAssertEqual(player?.view.accessibilityIdentifier, "file.preview.player")
        let quick = UIHostingController(rootView: WorkspaceQuickLookPreview(url: url))
        let quickWindow = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        quickWindow.rootViewController = quick
        quickWindow.makeKeyAndVisible()
        quick.view.layoutIfNeeded()
        let preview: QLPreviewController? = findController(from: quick.view)
        let controller = try XCTUnwrap(preview)
        XCTAssertEqual(controller.dataSource?.numberOfPreviewItems(in: controller), 1)
        XCTAssertEqual(controller.dataSource?.previewController(controller, previewItemAt: 0).previewItemURL, url)
        window.isHidden = true
        quickWindow.isHidden = true
        player?.player?.pause()
    }

    func testImageZoomAndPDFViewUseSystemControls() throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 20)).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
        }
        let canvas = PreviewImageCanvas(image: image)
        canvas.frame = CGRect(x: 0, y: 0, width: 180, height: 180)
        let window = UIWindow(frame: canvas.frame)
        window.addSubview(canvas)
        window.makeKeyAndVisible()
        canvas.layoutIfNeeded()
        XCTAssertEqual(canvas.minimumZoomScale, 1)
        XCTAssertEqual(canvas.maximumZoomScale, 8)
        XCTAssertTrue(canvas.viewForZooming(in: canvas) === canvas.imageView)
        XCTAssertEqual(canvas.zoomScale, 1, accuracy: 0.01)
        canvas.setZoomScale(4, animated: false)
        XCTAssertEqual(canvas.zoomScale, 4, accuracy: 0.01)
        XCTAssertTrue(canvas.gestureRecognizers?.contains { ($0 as? UITapGestureRecognizer)?.numberOfTapsRequired == 2 } == true)
        XCTAssertEqual(canvas.accessibilityIdentifier, "file.preview.zoom")
        window.isHidden = true

        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        let document = PDFDocument()
        document.insert(try XCTUnwrap(PDFPage(image: image)), at: 0)
        document.insert(try XCTUnwrap(PDFPage(image: image)), at: 1)
        XCTAssertTrue(document.write(to: url))
        let host = UIHostingController(rootView: WorkspacePDFPreview(url: url))
        let pdfWindow = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        pdfWindow.rootViewController = host
        pdfWindow.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        let pdf = find(PDFView.self, in: host.view)
        XCTAssertEqual(pdf?.document?.pageCount, 2)
        XCTAssertEqual(pdf?.autoScales, true)
        XCTAssertEqual(pdf?.displayMode, .singlePageContinuous)
        XCTAssertEqual(pdf?.accessibilityIdentifier, "file.preview.pdf")
        pdfWindow.isHidden = true
    }

    func testCaptionsFitDuoWidthsAndLargeType() {
        let image = PreviewDescriptor(source: .worktree("资料/嵌入式英语/截图/screen.png"), kind: .image, status: .ready, byteCount: 1_800_000, pixelWidth: 4096, pixelHeight: 3072, frameCount: 8, displayedWidth: 2048, displayedHeight: 1536)
        let notices = [
            PreviewLabels.imageCaption(image, locale: Locale(identifier: "en")),
            PreviewLabels.message(PreviewDescriptor(source: .worktree("a.pdf"), kind: .pdf, status: .encrypted), locale: Locale(identifier: "en")),
            PreviewLabels.message(PreviewDescriptor(source: .worktree("a.png"), kind: .image, status: .pixelBudget, pixelWidth: 40000, pixelHeight: 40000), locale: Locale(identifier: "zh-Hans")),
            PreviewLabels.message(PreviewDescriptor(source: .worktree("a.png"), status: .changed), locale: Locale(identifier: "ja")),
            String(localized: "Copying preview…", locale: Locale(identifier: "en")),
        ]
        for locale in ["en", "zh-Hans", "ja"] {
            for width: CGFloat in [240, 346, 466, 951] {
                for text in notices {
                    let host = UIHostingController(rootView: Text(text)
                        .font(.footnote)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .environment(\.locale, Locale(identifier: locale))
                        .environment(\.dynamicTypeSize, .accessibility3))
                    let size = host.sizeThatFits(in: CGSize(width: width, height: 10_000))
                    XCTAssertLessThanOrEqual(size.width, width + 0.5, "\(locale) \(width) \(text)")
                    XCTAssertGreaterThan(size.height, 12, text)
                    XCTAssertTrue(size.height.isFinite)
                }
            }
        }
    }

    private func bitmap(width: Int, height: Int) throws -> CGImage {
        let row = width * 4
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: row * height, alignment: 16)
        defer { buffer.deallocate() }
        guard let context = CGContext(data: buffer, width: width, height: height, bitsPerComponent: 8, bytesPerRow: row, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw CocoaError(.fileWriteUnknown)
        }
        context.setFillColor(UIColor.systemOrange.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }

    private func encryptedPDF() throws -> Data {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 12, height: 12)).image { $0.fill(CGRect(x: 0, y: 0, width: 12, height: 12)) }
        let document = PDFDocument()
        document.insert(try XCTUnwrap(PDFPage(image: image)), at: 0)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(document.write(to: url, withOptions: [
            PDFDocumentWriteOption.userPasswordOption: "secret",
            PDFDocumentWriteOption.ownerPasswordOption: "owner-secret",
        ]))
        return try Data(contentsOf: url)
    }

    private func findController<T: UIViewController>(from view: UIView) -> T? {
        var responder: UIResponder? = view
        while let current = responder {
            if let match = current as? T { return match }
            responder = current.next
        }
        for child in view.subviews {
            if let match: T = findController(from: child) { return match }
        }
        return nil
    }

    private func find<T: UIView>(_ type: T.Type, in view: UIView) -> T? {
        if let match = view as? T { return match }
        for child in view.subviews {
            if let match = find(type, in: child) { return match }
        }
        return nil
    }
}
