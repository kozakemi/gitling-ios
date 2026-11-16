import CryptoKit
import Darwin
import Foundation

/// A conservative, cross-process gate for the single embedded Guest runtime.
/// Native operations share it; a running Guest holds it exclusively. A managed
/// session can release it only after every Guest thread is parked, and must
/// reacquire it before any thread resumes. This also covers aliases/nested repositories and avoids
/// treating File Provider's shared *write* lock as a read-only reservation.
enum RepositoryAccessGate {
    static func holdNative(base: URL? = nil) throws -> RepoWriteLock.Hold {
        try hold(exclusive: false, base: base)
    }

    static func holdGuest(base: URL? = nil) throws -> RepoWriteLock.Hold {
        try hold(exclusive: true, base: base)
    }

    /// The selected workspace's identity remains fixed even while its guest is
    /// parked. Reads, staging and commits remain available; delete/link/unlink
    /// require ending that session so open guest descriptors cannot go stale.
    static func holdBinding(repoName: String, guest: Bool) throws -> RepoWriteLock.Hold {
        let key = SHA256.hash(data: Data(repoName.precomposedStringWithCanonicalMapping.lowercased().utf8)).map { String(format: "%02x", $0) }.joined()
        do { return try hold(exclusive: guest, base: nil, filename: ".guest-binding-" + key + ".lock") }
        catch { throw guest ? WorkingTreeError.busy : WorkingTreeError.terminalWorkspaceBusy }
    }

    private static func hold(exclusive: Bool, base: URL?, filename: String = ".guest-repository-access.lock") throws -> RepoWriteLock.Hold {
        let directory = base ?? RepoStorage.groupContainer ?? RepoStorage.storageBase()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(filename)
        let fd = url.path.withCString { open($0, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600) }
        guard fd >= 0 else { throw WorkingTreeError.busy }
        if flock(fd, (exclusive ? LOCK_EX : LOCK_SH) | LOCK_NB) != 0 {
            close(fd); throw WorkingTreeError.busy
        }
        return RepoWriteLock.Hold(fd: fd)
    }
}
