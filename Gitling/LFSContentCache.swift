import CryptoKit
import Darwin
import Foundation

/// Cache checksum results only while the file identity and modification/change
/// timestamps match. In particular, restoring mtime must not hide a new edit.
final class LFSContentCache {
    private struct Stamp: Equatable {
        var device: Int32
        var inode: UInt64
        var size: Int64
        var modifiedSeconds: Int
        var modifiedNanos: Int
        var changedSeconds: Int
        var changedNanos: Int
    }

    private struct Entry {
        var stamp: Stamp
        var oid: String
        var matches: Bool
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var order: [String] = []
    private let capacity: Int
    private let hashFile: (URL) throws -> String

    init(capacity: Int = 512, hashFile: @escaping (URL) throws -> String = LFSContentCache.sha256) {
        self.capacity = max(1, capacity)
        self.hashFile = hashFile
    }

    func matches(_ url: URL, pointer: LFSPointer) -> Bool {
        guard let before = stamp(url), before.size == Int64(pointer.size) else { return false }
        let key = url.standardizedFileURL.path
        lock.lock()
        let cached = entries[key]
        lock.unlock()
        if let cached, cached.stamp == before, cached.oid == pointer.oid { return cached.matches }
        guard let digest = try? hashFile(url), stamp(url) == before else { return false }
        let matches = digest == pointer.oid
        lock.lock()
        if entries[key] == nil {
            order.append(key)
            if order.count > capacity { entries.removeValue(forKey: order.removeFirst()) }
        }
        entries[key] = Entry(stamp: before, oid: pointer.oid, matches: matches)
        lock.unlock()
        return matches
    }

    private func stamp(_ url: URL) -> Stamp? {
        var info = stat()
        guard url.path.withCString({ lstat($0, &info) }) == 0,
              info.st_mode & S_IFMT == S_IFREG else { return nil }
        return Stamp(device: info.st_dev, inode: info.st_ino, size: info.st_size,
                     modifiedSeconds: info.st_mtimespec.tv_sec, modifiedNanos: info.st_mtimespec.tv_nsec,
                     changedSeconds: info.st_ctimespec.tv_sec, changedNanos: info.st_ctimespec.tv_nsec)
    }

    private static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
