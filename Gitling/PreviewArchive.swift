import Foundation

struct PreviewArchiveEntry: Identifiable, Equatable, Sendable {
    let id: Int
    let path: String
    let bytes: UInt32
    let compressedBytes: UInt32
    let encrypted: Bool
    var unsafePath: Bool {
        path.hasPrefix("/") || path.contains("\\") || path.split(separator: "/").contains("..") || path.contains(":") || path.rangeOfCharacter(from: .controlCharacters) != nil
    }
}

struct PreviewArchiveIndex: Equatable, Sendable {
    var entries: [PreviewArchiveEntry]
    var total: Int
    var truncated: Bool
}

/// Central-directory metadata only: never inflate, extract or follow entry paths.
enum PreviewArchive {
    enum Failure: Error { case damaged, unsupported, limit }
    static let maximumEntries = 2000
    static let maximumDirectoryBytes = 1024 * 1024

    static func index(data: Data) throws -> PreviewArchiveIndex {
        try index(size: data.count) { offset, count in
            guard offset >= 0, count >= 0, offset <= data.count, count <= data.count - offset else { throw Failure.damaged }
            return data.subdata(in: offset..<(offset + count))
        }
    }

    static func index(size: Int, token: PreviewCancellation? = nil, read: (Int, Int) throws -> Data) throws -> PreviewArchiveIndex {
        guard size >= 22 else { throw Failure.damaged }
        let tailSize = min(size, 65557), tail = try read(size - min(size, 65557), tailSize)
        guard tail.count == tailSize else { throw Failure.damaged }
        var end: Int?
        for offset in stride(from: tail.count - 22, through: 0, by: -1) {
            if u32(tail, offset) == 0x06054b50, offset + 22 + Int(u16(tail, offset + 20)) == tail.count {
                end = offset; break
            }
        }
        guard let end else { throw Failure.damaged }
        guard u16(tail, end + 4) == 0, u16(tail, end + 6) == 0 else { throw Failure.unsupported }
        let count = Int(u16(tail, end + 10)), length = Int(u32(tail, end + 12)), start = Int(u32(tail, end + 16))
        guard count != 0xffff, length != Int(UInt32.max), start != Int(UInt32.max),
              Int(u16(tail, end + 8)) == count else { throw Failure.unsupported }
        guard length <= maximumDirectoryBytes else { throw Failure.limit }
        let endPosition = size - tailSize + end
        guard start <= endPosition, length <= endPosition - start else { throw Failure.damaged }
        let directory = try read(start, length)
        guard directory.count == length else { throw Failure.damaged }
        var entries: [PreviewArchiveEntry] = [], cursor = 0
        for number in 0..<count {
            try token?.check()
            guard cursor <= directory.count - 46, u32(directory, cursor) == 0x02014b50 else { throw Failure.damaged }
            let nameLength = Int(u16(directory, cursor + 28)), extra = Int(u16(directory, cursor + 30)), comment = Int(u16(directory, cursor + 32))
            let next = cursor + 46 + nameLength + extra + comment
            guard next <= directory.count, nameLength > 0, nameLength <= 4096,
                  u16(directory, cursor + 34) == 0 else { throw Failure.damaged }
            guard u32(directory, cursor + 42) < UInt32(start),
                  u32(directory, cursor + 20) != UInt32.max, u32(directory, cursor + 24) != UInt32.max else { throw Failure.unsupported }
            if number < maximumEntries {
                let name = directory.subdata(in: (cursor + 46)..<(cursor + 46 + nameLength))
                let flags = u16(directory, cursor + 8)
                let encoding: String.Encoding = flags & 0x800 != 0 ? .utf8 : .ascii
                let decoded = String(data: name, encoding: encoding)
                let path = decoded ?? "[encoded: " + name.prefix(64).map { String(format: "%02X", $0) }.joined() + "]"
                entries.append(.init(id: number, path: path, bytes: u32(directory, cursor + 24), compressedBytes: u32(directory, cursor + 20), encrypted: flags & 1 != 0))
            }
            cursor = next
        }
        guard cursor == directory.count else { throw Failure.damaged }
        return .init(entries: entries, total: count, truncated: count > maximumEntries)
    }

    static func u16(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }
    static func u32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(u16(data, offset)) | (UInt32(u16(data, offset + 2)) << 16)
    }
}

struct PreviewHexPage: Sendable, Equatable {
    static let pageBytes = 4096
    let offset: Int
    let total: Int
    let data: Data
    var hasPrevious: Bool { offset > 0 }
    var hasNext: Bool { offset + data.count < total }
    var text: String {
        stride(from: 0, to: data.count, by: 16).map { start in
            let row = data.subdata(in: start..<min(start + 16, data.count))
            let hex = row.map { String(format: "%02X", $0) }.joined(separator: " ")
            let ascii = String(row.map { (32...126).contains($0) ? Character(UnicodeScalar($0)) : "." })
            return String(format: "%08X  ", offset + start) + hex.padding(toLength: 47, withPad: " ", startingAt: 0) + "  " + ascii
        }.joined(separator: "\n")
    }
    static func read(url: URL, offset: Int, token: PreviewCancellation) throws -> Self {
        try token.check()
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let total = try handle.seekToEnd()
        guard total <= UInt64(PreviewBudget.standard.fileBytes), offset >= 0, UInt64(offset) <= total else { throw PreviewArchive.Failure.limit }
        try handle.seek(toOffset: UInt64(offset))
        let bytes = try handle.read(upToCount: min(pageBytes, Int(total) - offset)) ?? Data()
        try token.check()
        return .init(offset: offset, total: Int(total), data: bytes)
    }
}
