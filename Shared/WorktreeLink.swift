import Foundation

/// A working folder the user picked in the Files app.
/// Git metadata stays in the app. The bookmark is the only record of the folder.
enum WorktreeLink {
    final class Access {
        /// Folder that contains the working files: the chosen location plus the repository name.
        let url: URL
        /// Folder the user picked. Security scope belongs to this URL.
        let scope: URL
        private let started: Bool
        private let lock = NSLock()
        private var stopped = false
        init(url: URL, scope: URL, started: Bool) {
            self.url = url
            self.scope = scope
            self.started = started
        }
        func stop() {
            lock.lock()
            let shouldStop = started && !stopped
            stopped = true
            lock.unlock()
            if shouldStop { scope.stopAccessingSecurityScopedResource() }
        }
        deinit { stop() }
    }

    static func repoName(in identifier: String) -> String? {
        guard identifier.hasPrefix("repo:") else { return nil }
        let body = identifier.dropFirst("repo:".count)
        guard !body.isEmpty else { return nil }
        let name = body.split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
        return name.isEmpty ? nil : name
    }

    static func save(repoName: String, data: Data) throws {
        let file = directory().appendingPathComponent(safeFileName(repoName))
        try data.write(to: file, options: .atomic)
    }

    static func remove(repoName: String) {
        RepoStorage.removeLink(fileName: safeFileName(repoName))
    }

    static func begin(repoName: String, storageBase: URL? = nil) -> Access? {
        let file = directory(base: storageBase).appendingPathComponent(safeFileName(repoName))
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? makeAccess(from: data, repoName: repoName)
    }

    /// Destructive single-file recovery must not silently fall back to the app
    /// sandbox or recreate a missing linked workspace while resolving a bookmark.
    static func beginForFileRestore(repoName: String) throws -> Access? {
        let file = directory().appendingPathComponent(safeFileName(repoName))
        let data: Data
        do { data = try Data(contentsOf: file) }
        catch CocoaError.fileReadNoSuchFile { return nil }
        return try makeAccess(from: data, repoName: repoName, createWorkingDirectory: false)
    }

    static func makeAccess(from data: Data, repoName: String, createWorkingDirectory: Bool = true) throws -> Access {
        var stale = false
        let scope = try URL(
            resolvingBookmarkData: data,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        let started = scope.startAccessingSecurityScopedResource()
        if !started && !FileManager.default.isReadableFile(atPath: scope.path) {
            throw CocoaError(.fileReadNoPermission)
        }
        let work = workDirectory(parent: scope, repoName: repoName)
        if !createWorkingDirectory {
            guard (try? work.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                if started { scope.stopAccessingSecurityScopedResource() }
                throw CocoaError(.fileNoSuchFile)
            }
        } else if work.standardizedFileURL.path != scope.standardizedFileURL.path {
            do {
                try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            } catch {
                if started { scope.stopAccessingSecurityScopedResource() }
                throw error
            }
        }
        return Access(url: work, scope: scope, started: started)
    }

    /// Working files live in `<chosen folder>/<repository name>`.
    /// If the chosen folder is already named after the repository, it is used as-is.
    static func workDirectory(parent: URL, repoName: String) -> URL {
        if parent.lastPathComponent == repoName { return parent }
        return parent.appendingPathComponent(repoName, isDirectory: true)
    }

    static func bookmark(for folder: URL) throws -> Data {
        try folder.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    static func displayName(repoName: String) -> String? {
        guard let access = begin(repoName: repoName) else { return nil }
        defer { access.stop() }
        return displayName(for: access)
    }

    static func displayName(for access: Access) -> String {
        if access.url.standardizedFileURL.path == access.scope.standardizedFileURL.path {
            return access.url.lastPathComponent
        }
        return "\(access.scope.lastPathComponent)/\(access.url.lastPathComponent)"
    }

    private static func directory(base: URL? = nil) -> URL {
        let base = base ?? RepoStorage.storageBase()
        let directory = base.appendingPathComponent("worktree-links", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func safeFileName(_ repoName: String) -> String {
        repoName.replacingOccurrences(of: "/", with: "_") + ".bookmark"
    }
}
