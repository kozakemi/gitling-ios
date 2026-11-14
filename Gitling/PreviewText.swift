import Foundation

/// How a text preview decided its encoding.
///
/// A byte-order mark or strict UTF-8 is reported as that encoding. Legacy
/// encodings such as GB18030 are never selected automatically: GB18030 can
/// decode almost any byte sequence, so a successful decode is not evidence.
enum PreviewEncodingConfidence: Equatable, Sendable {
    case byteOrderMark
    case unicode
    case manual
}

enum PreviewTextEncoding: String, CaseIterable, Identifiable, Sendable {
    case utf8
    case utf16LE
    case utf16BE
    case utf32LE
    case utf32BE
    case gb18030
    case gbk
    case big5
    case shiftJIS

    var id: String { rawValue }

    var title: String {
        switch self {
        case .utf8: String(localized: "UTF-8")
        case .utf16LE: String(localized: "UTF-16 LE")
        case .utf16BE: String(localized: "UTF-16 BE")
        case .utf32LE: String(localized: "UTF-32 LE")
        case .utf32BE: String(localized: "UTF-32 BE")
        case .gb18030: String(localized: "GB18030")
        case .gbk: String(localized: "GBK")
        case .big5: String(localized: "Big5")
        case .shiftJIS: String(localized: "Shift JIS")
        }
    }

    var stringEncoding: String.Encoding {
        switch self {
        case .utf8: .utf8
        case .utf16LE: .utf16LittleEndian
        case .utf16BE: .utf16BigEndian
        case .utf32LE: .utf32LittleEndian
        case .utf32BE: .utf32BigEndian
        case .gb18030: Self.coreFoundation(.GB_18030_2000)
        case .gbk: Self.coreFoundation(.GBK_95)
        case .big5: Self.coreFoundation(.big5)
        case .shiftJIS: Self.coreFoundation(.shiftJIS)
        }
    }

    private static func coreFoundation(_ encoding: CFStringEncodings) -> String.Encoding {
        let raw = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(encoding.rawValue))
        return String.Encoding(rawValue: raw)
    }
}

enum PreviewMarkdownMode: String, CaseIterable, Identifiable, Hashable, Sendable {
    case source, rendered
    var id: String { rawValue }
    var title: String {
        switch self {
        case .source: String(localized: "Source")
        case .rendered: String(localized: "Rendered")
        }
    }
}

enum PreviewText {
    struct Decision: Equatable, Sendable {
        var kind: PreviewKind
        var status: PreviewStatus
        var text: String?
        var encoding: PreviewTextEncoding?
        var confidence: PreviewEncodingConfidence?
    }

    /// Decode only encodings the bytes prove. Anything else stays undecoded so
    /// the caller can ask the user. This does not read the file or the network.
    static func interpret(_ data: Data, path: String) -> Decision? {
        if let marked = byteOrderMark(data) {
            if let text = decode(data, as: marked.encoding) {
                return Decision(kind: kind(path: path, text: text), status: .ready, text: text, encoding: marked.encoding, confidence: .byteOrderMark)
            }
        }
        if !data.contains(0), let text = String(data: data, encoding: .utf8) {
            return Decision(kind: kind(path: path, text: text), status: .ready, text: text, encoding: .utf8, confidence: .unicode)
        }
        guard offersChoice(data, path: path) else { return nil }
        return Decision(kind: kind(path: path, text: nil), status: .chooseEncoding, text: nil, encoding: nil, confidence: nil)
    }

    /// Manual decode. A nil result means the selected encoding rejected the bytes.
    /// It is not a guess and it does not fall back to another encoding.
    static func decode(_ data: Data, as encoding: PreviewTextEncoding) -> String? {
        let body: Data
        switch encoding {
        case .utf8:
            body = data.starts(with: [0xEF, 0xBB, 0xBF]) ? Data(data.dropFirst(3)) : data
        case .utf16LE:
            body = stripPrefix([0xFF, 0xFE], from: data, unless: [0xFF, 0xFE, 0x00, 0x00])
        case .utf16BE:
            body = data.starts(with: [0xFE, 0xFF]) ? Data(data.dropFirst(2)) : data
        case .utf32LE:
            body = data.starts(with: [0xFF, 0xFE, 0x00, 0x00]) ? Data(data.dropFirst(4)) : data
        case .utf32BE:
            body = data.starts(with: [0x00, 0x00, 0xFE, 0xFF]) ? Data(data.dropFirst(4)) : data
        case .gb18030, .gbk, .big5, .shiftJIS:
            body = data
        }
        switch encoding {
        case .utf16LE, .utf16BE:
            guard body.count.isMultiple(of: 2) else { return nil }
        case .utf32LE, .utf32BE:
            guard body.count.isMultiple(of: 4) else { return nil }
        case .utf8, .gb18030, .gbk, .big5, .shiftJIS:
            break
        }
        return String(data: body, encoding: encoding.stringEncoding)
    }

    static func kind(path: String, text: String?) -> PreviewKind {
        let ext = (path as NSString).pathExtension.lowercased()
        if ext == "md" || ext == "markdown" || ext == "mdown" { return .markdown }
        let head = text?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if ext == "svg" || head.hasPrefix("<svg") || (head.hasPrefix("<?xml") && head.contains("<svg")) { return .svg }
        if ext == "html" || ext == "htm" || head.hasPrefix("<!doctype html") || head.hasPrefix("<html") { return .html }
        return .text
    }

    private struct Mark {
        var encoding: PreviewTextEncoding
        var skip: Int
    }

    private static func byteOrderMark(_ data: Data) -> Mark? {
        if data.starts(with: [0xFF, 0xFE, 0x00, 0x00]) { return Mark(encoding: .utf32LE, skip: 4) }
        if data.starts(with: [0x00, 0x00, 0xFE, 0xFF]) { return Mark(encoding: .utf32BE, skip: 4) }
        if data.starts(with: [0xFF, 0xFE]) { return Mark(encoding: .utf16LE, skip: 2) }
        if data.starts(with: [0xFE, 0xFF]) { return Mark(encoding: .utf16BE, skip: 2) }
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { return Mark(encoding: .utf8, skip: 3) }
        return nil
    }

    private static func stripPrefix(_ prefix: [UInt8], from data: Data, unless longer: [UInt8]) -> Data {
        if data.starts(with: longer) { return data }
        return data.starts(with: prefix) ? Data(data.dropFirst(prefix.count)) : data
    }

    private static let textExtensions: Set<String> = [
        "txt", "text", "md", "markdown", "mdown", "csv", "tsv", "json", "xml", "html", "htm", "svg",
        "swift", "m", "h", "c", "cc", "cpp", "hpp", "py", "rb", "java", "kt", "rs", "go", "sh",
        "bash", "zsh", "yaml", "yml", "toml", "css", "js", "jsx", "ts", "tsx", "strings", "rst",
        "adoc", "log", "ini", "cfg", "conf", "properties", "gradle",
    ]

    private static let binaryExtensions: Set<String> = [
        "bin", "zip", "gz", "tgz", "dmg", "ipa", "png", "jpg", "jpeg", "gif", "heic", "heif", "webp",
        "tiff", "tif", "bmp", "pdf", "mp3", "mp4", "mov", "m4a", "m4v", "wav", "aac", "aiff", "caf",
        "doc", "docx", "xls", "xlsx", "ppt", "pptx", "pages", "numbers", "key", "rtf", "o", "a",
        "dylib", "so", "exe", "wasm", "ico", "ttf", "otf", "woff", "woff2", "sqlite", "db", "car", "plist",
    ]

    private static func offersChoice(_ data: Data, path: String) -> Bool {
        if byteOrderMark(data) != nil { return true }
        let ext = (path as NSString).pathExtension.lowercased()
        if textExtensions.contains(ext) { return true }
        if binaryExtensions.contains(ext) || data.contains(0) { return false }
        return !ext.isEmpty || !data.isEmpty
    }

}
