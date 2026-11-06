import Darwin
import Foundation

/// Cross-process lock for one repository working tree.
/// Git operations take the exclusive lock. File Provider writes take a shared lock and fail immediately if Git holds it.
enum RepoWriteLock {
    final class Hold {
        let fd: Int32
        init(fd: Int32) { self.fd = fd }
        deinit {
            _ = flock(fd, LOCK_UN)
            close(fd)
        }
    }

    static func withLock<T>(at repoURL: URL, _ body: () throws -> T) throws -> T {
        let fd = try openLock(at: repoURL)
        if flock(fd, LOCK_EX) != 0 {
            close(fd)
            throw WorkingTreeError.busy
        }
        let hold = Hold(fd: fd)
        defer { withExtendedLifetime(hold) {} }
        return try body()
    }

    static func withSharedLock<T>(at repoURL: URL, _ body: () throws -> T) throws -> T {
        let fd = try openLock(at: repoURL)
        if flock(fd, LOCK_SH | LOCK_NB) != 0 {
            close(fd)
            throw WorkingTreeError.busy
        }
        let hold = Hold(fd: fd)
        defer { withExtendedLifetime(hold) {} }
        return try body()
    }

    static func holdExclusive(at repoURL: URL) throws -> Hold {
        let fd = try openLock(at: repoURL)
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            throw WorkingTreeError.busy
        }
        return Hold(fd: fd)
    }

    private static func openLock(at repoURL: URL) throws -> Int32 {
        let directory = repoURL.deletingLastPathComponent().appendingPathComponent(".locks", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(repoURL.lastPathComponent + ".lock")
        let fd = file.path.withCString { open($0, O_CREAT | O_RDWR, 0o644) }
        if fd < 0 { throw WorkingTreeError.busy }
        return fd
    }
}
