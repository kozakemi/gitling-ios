import Darwin
import Foundation

/// A confirmation authorizes exactly one index version and one observed work file.
struct FileRestorePlan: Identifiable, Sendable {
    let id = UUID()
    let path: String
    let root: URL
    let indexOID: String
    let indexMode: UInt32
    let snapshot: RestoreFileAccess.Snapshot
    var restoresDeletedFile: Bool { snapshot.file == nil }
}

/// Descriptor-relative access keeps symlink ancestors and literal pathspecs out of
/// the write path. Only a regular leaf can be replaced; directories are never removed.
enum RestoreFileAccess {
    static var changed: GitFailure { .message(String(localized: "The file, index, or working folder changed. Review the changes and try again.")) }
    static var unsupported: GitFailure { .message(String(localized: "Only regular tracked files can be restored. Symbolic links, folders, and submodules are protected.")) }

    struct Identity: Equatable, Sendable {
        let device: Int32
        let inode: UInt64
        init(_ info: stat) { device = info.st_dev; inode = info.st_ino }
    }
    struct Stamp: Equatable, Sendable {
        let identity: Identity
        let size: Int64
        let mode: UInt16
        let modified: Int, modifiedNanos: Int, changed: Int, changedNanos: Int
        init(_ info: stat) {
            identity = Identity(info); size = info.st_size; mode = info.st_mode
            modified = info.st_mtimespec.tv_sec; modifiedNanos = info.st_mtimespec.tv_nsec
            changed = info.st_ctimespec.tv_sec; changedNanos = info.st_ctimespec.tv_nsec
        }
    }
    struct Snapshot: Equatable, Sendable {
        let directories: [Identity]
        let file: Stamp?
    }

    private static func failure() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

    private static func withParent<T>(root: URL, path: String, create: Bool,
                                      _ body: (Int32?, String, [Identity]) throws -> T) throws -> T {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty, !path.contains("\0"), parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.lowercased() != ".git" }) else { throw WorkingTreeError.outside }
        var fd = root.path.withCString { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        guard fd >= 0 else { throw unsupported }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw failure() }
        var directories = [Identity(info)]
        for component in parts.dropLast() {
            var next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if next < 0, errno == ENOENT {
                if !create { return try body(nil, parts.last!, directories) }
                guard mkdirat(fd, component, 0o755) == 0 || errno == EEXIST else { throw failure() }
                next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard next >= 0 else { throw unsupported }
            close(fd); fd = next
            guard fstat(fd, &info) == 0 else { throw failure() }
            directories.append(Identity(info))
        }
        return try body(fd, parts.last!, directories)
    }

    private static func stamp(parent: Int32?, leaf: String) throws -> Stamp? {
        guard let parent else { return nil }
        var info = stat()
        if fstatat(parent, leaf, &info, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return nil }
            throw failure()
        }
        guard info.st_mode & S_IFMT == S_IFREG else { throw unsupported }
        return Stamp(info)
    }

    static func snapshot(root: URL, path: String) throws -> Snapshot {
        try withParent(root: root, path: path, create: false) { parent, leaf, directories in
            Snapshot(directories: directories, file: try stamp(parent: parent, leaf: leaf))
        }
    }

    static func replace(plan: FileRestorePlan, bytes: UnsafeRawPointer?, count: Int) throws {
        guard try snapshot(root: plan.root, path: plan.path) == plan.snapshot else { throw changed }
        try withParent(root: plan.root, path: plan.path, create: true) { parent, leaf, directories in
            guard let parent, directories.starts(with: plan.snapshot.directories),
                  try stamp(parent: parent, leaf: leaf) == plan.snapshot.file else { throw changed }
            let temporary = ".gitling-restore-" + UUID().uuidString
            let output = openat(parent, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard output >= 0 else { throw failure() }
            defer { close(output); unlinkat(parent, temporary, 0) }
            var offset = 0
            while offset < count {
                let written = Darwin.write(output, bytes!.advanced(by: offset), min(count - offset, 1_048_576))
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { throw failure() }
                offset += written
            }
            let permissions: mode_t = plan.indexMode & 0o111 != 0 ? 0o755 : 0o644
            guard fchmod(output, permissions) == 0, fsync(output) == 0 else { throw failure() }
            // Revalidate after writing the temporary file, before publishing it.
            let current = try snapshot(root: plan.root, path: plan.path)
            guard current.directories == directories, current.file == plan.snapshot.file else { throw changed }
            let flags = plan.snapshot.file == nil ? UInt32(RENAME_EXCL) : 0
            guard renameatx_np(parent, temporary, parent, leaf, flags) == 0 else { throw failure() }
        }
    }
}
