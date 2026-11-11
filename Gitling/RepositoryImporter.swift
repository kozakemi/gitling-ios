import Darwin
import Foundation

/// File copying is separate from GitClient's global lock. Only validation and
/// local checkout use libgit2; no transport, filters or Git hooks are executed.
enum RepositoryImporter {
    enum Failure: LocalizedError {
        case invalidSource, externalGitData, sourceChanged, activeOperation, overlappingPaths, incompleteCopy

        var errorDescription: String? {
            switch self {
            case .incompleteCopy: String(localized: "The copied repository is incomplete. Nothing was imported.")
            case .invalidSource: String(localized: "Choose the root folder of a Git repository.")
            case .externalGitData: String(localized: "This repository depends on external Git data. Import a self-contained repository instead.")
            case .sourceChanged: String(localized: "The source changed during import. Nothing was imported. Try again when it is idle.")
            case .activeOperation: String(localized: "The source has a Git lock. Finish the Git operation before importing.")
            case .overlappingPaths: String(localized: "The import destination must be outside the source repository.")
            }
        }
    }

    private struct Stamp: Equatable {
        var device: Int32
        var inode: UInt64
        var mode: UInt16
        var size: Int64
        var modifiedSeconds: Int
        var modifiedNanos: Int
        var changedSeconds: Int
        var changedNanos: Int
        var linkTarget: String?
    }

    typealias CopyItem = (URL, URL) throws -> Void

    static func validateLocation(from sourceURL: URL, to destinationURL: URL) throws {
        let source = sourceURL.resolvingSymlinksInPath().standardizedFileURL
        let destination = destinationURL.resolvingSymlinksInPath().standardizedFileURL
        let root = destination.deletingLastPathComponent()
        let staging = root.deletingLastPathComponent().appendingPathComponent(".gitling-imports")
        guard source != root, source != destination,
              !root.path.hasPrefix(source.path + "/"),
              !source.path.hasPrefix(destination.path + "/"),
              !destination.path.hasPrefix(source.path + "/"),
              source != staging, !staging.path.hasPrefix(source.path + "/") else { throw Failure.overlappingPaths }
    }

    /// The copier seam lets regressions simulate partial I/O failures and a
    /// destination appearing mid-copy without relying on timing or permissions.
    static func copy(
        from sourceURL: URL, to destinationURL: URL,
        copyItem: CopyItem = { try FileManager.default.copyItem(at: $0, to: $1) },
        inspect: (URL, Bool) throws -> Void,
        prepare: (URL, Bool) throws -> Void
    ) throws {
        let fm = FileManager.default
        let source = sourceURL.resolvingSymlinksInPath().standardizedFileURL
        let destination = destinationURL.standardizedFileURL
        let root = destination.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        let stagingParent = root.deletingLastPathComponent().appendingPathComponent(".gitling-imports", isDirectory: true)
        try validateLocation(from: source, to: destination)
        if try exists(destination) { throw WorkingTreeError.collision }

        let git = source.appendingPathComponent(".git", isDirectory: true)
        let bare: Bool
        let metadata: URL
        if try exists(git) {
            let values = try git.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { throw Failure.externalGitData }
            bare = false
            metadata = git
        } else {
            guard try exists(source.appendingPathComponent("HEAD")),
                  try exists(source.appendingPathComponent("objects")) else { throw Failure.invalidSource }
            bare = true
            metadata = source
        }
        try validateMetadata(metadata)
        try inspect(source, bare)
        let before = try snapshot(source)
        try Task.checkCancellation()

        // Staging is outside repositories/, so list refreshes and storage backup
        // migration cannot expose or copy an unvalidated repository.
        if try exists(stagingParent), try stagingParent.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
            throw Failure.overlappingPaths
        }
        try fm.createDirectory(at: stagingParent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let transaction = stagingParent.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: transaction, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer {
            try? makeWritable(transaction)
            try? fm.removeItem(at: transaction)
        }
        let staged = transaction.appendingPathComponent(destination.lastPathComponent, isDirectory: true)
        if bare {
            try fm.createDirectory(at: staged, withIntermediateDirectories: false)
            try copyItem(source, staged.appendingPathComponent(".git", isDirectory: true))
        } else {
            try copyItem(source, staged)
        }
        try Task.checkCancellation()
        guard try snapshot(source) == before else { throw Failure.sourceChanged }
        try makeWritable(staged)
        let copied = try snapshot(bare ? staged.appendingPathComponent(".git") : staged)
        guard before.keys.count == copied.keys.count, before.allSatisfy({ path, original in
            guard let copy = copied[path], copy.mode & S_IFMT == original.mode & S_IFMT else { return false }
            if original.mode & S_IFMT == S_IFDIR { return true }
            return copy.size == original.size && copy.linkTarget == original.linkTarget
        }) else { throw Failure.incompleteCopy }
        try validateMetadata(staged.appendingPathComponent(".git", isDirectory: true))
        try prepare(staged, bare)
        // Detect uncoordinated source Git/editor activity during validation too.
        guard try snapshot(source) == before else { throw Failure.sourceChanged }
        try Task.checkCancellation()
        let result = staged.path.withCString { from in
            destination.path.withCString { to in renamex_np(from, to, UInt32(RENAME_EXCL)) }
        }
        if result != 0 {
            if errno == EEXIST || errno == ENOTEMPTY { throw WorkingTreeError.collision }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        // No throwing work after the atomic no-replace rename: it is the commit.
    }

    /// Only touch the owned copy; do not chmod through working-tree symlinks.
    private static func makeWritable(_ root: URL) throws {
        var info = stat()
        guard root.path.withCString({ lstat($0, &info) }) == 0 else { return }
        let kind = info.st_mode & S_IFMT
        if kind == S_IFLNK { return }
        let required: UInt16 = kind == S_IFDIR ? 0o700 : 0o600
        if info.st_mode & required != required {
            guard root.path.withCString({ chmod($0, (info.st_mode & 0o7777) | required) }) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
        if kind == S_IFDIR {
            for child in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
                try makeWritable(child)
            }
        }
    }

    private static func exists(_ url: URL) throws -> Bool {
        var info = stat()
        if url.path.withCString({ lstat($0, &info) }) == 0 { return true }
        if errno == ENOENT { return false }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    private static func walk(_ root: URL, visit: (URL) throws -> Void) throws {
        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: [], errorHandler: { _, error in
            enumerationError = error
            return false
        }) else { throw Failure.invalidSource }
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            try visit(url)
        }
        if let enumerationError { throw enumerationError }
    }

    private static func validateMetadata(_ metadata: URL) throws {
        try walk(metadata) { url in
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
            if values.isSymbolicLink == true || url.lastPathComponent == "commondir" { throw Failure.externalGitData }
            if url.lastPathComponent.hasSuffix(".lock") { throw Failure.activeOperation }
            let name = url.lastPathComponent
            if name == "alternates" || name == "http-alternates" {
                let contents = try String(contentsOf: url, encoding: .utf8)
                if !contents.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw Failure.externalGitData }
            }
            if name.hasSuffix(".promisor") { throw Failure.externalGitData }
        }
    }

    private static func snapshot(_ root: URL) throws -> [String: Stamp] {
        var result: [String: Stamp] = [:]
        func record(_ url: URL) throws {
            var info = stat()
            guard url.path.withCString({ lstat($0, &info) }) == 0 else { throw Failure.sourceChanged }
            let path = url.path == root.path ? "" : String(url.path.dropFirst(root.path.count + 1))
            result[path] = Stamp(device: info.st_dev, inode: info.st_ino, mode: info.st_mode, size: info.st_size,
                                 modifiedSeconds: info.st_mtimespec.tv_sec, modifiedNanos: info.st_mtimespec.tv_nsec,
                                 changedSeconds: info.st_ctimespec.tv_sec, changedNanos: info.st_ctimespec.tv_nsec,
                                 linkTarget: info.st_mode & S_IFMT == S_IFLNK ? try FileManager.default.destinationOfSymbolicLink(atPath: url.path) : nil)
        }
        try record(root)
        try walk(root, visit: record)
        return result
    }
}
