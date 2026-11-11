import Foundation

/// The app owns the workspace. A simulator extension must not derive the host's
/// Documents/Application Support paths from its own sandbox.
enum ProviderWorkspace {
    struct Record: Codable {
        var version = 1
        var repositories: Data
        var metadata: Data
    }
    static let filename = "provider-workspace-v1.json"

    static func publish(repositories: URL, metadata: URL, sharedGroup: URL) throws {
        guard try repositories.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
        let record = try Record(repositories: repositories.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil),
                                metadata: metadata.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil))
        try FileManager.default.createDirectory(at: sharedGroup, withIntermediateDirectories: true)
        let file = sharedGroup.appendingPathComponent(filename)
        let data = try JSONEncoder().encode(record)
        if (try? Data(contentsOf: file)) != data { try data.write(to: file, options: .atomic) }
    }

    static func withAccess<T>(sharedGroup: URL, _ body: (URL, URL) throws -> T) throws -> T {
        let record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: sharedGroup.appendingPathComponent(filename)))
        guard record.version == 1 else { throw CocoaError(.fileReadCorruptFile) }
        func resolve(_ data: Data) throws -> URL {
            var stale = false
            return try URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
        }
        let repositories = try resolve(record.repositories)
        let metadata = try resolve(record.metadata)
        let repositoryScope = repositories.startAccessingSecurityScopedResource()
        defer { if repositoryScope { repositories.stopAccessingSecurityScopedResource() } }
        let metadataScope = metadata.startAccessingSecurityScopedResource()
        defer { if metadataScope { metadata.stopAccessingSecurityScopedResource() } }
        guard try repositories.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true,
              try metadata.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw CocoaError(.fileReadNoSuchFile) }
        return try body(repositories, metadata)
    }

    static func withCurrentRoots<T>(_ body: (URL, URL) throws -> T) throws -> T {
#if targetEnvironment(simulator)
        guard let group = RepoStorage.groupContainer else { throw CocoaError(.fileReadNoPermission) }
        return try withAccess(sharedGroup: group, body)
#else
        return try body(RepoStorage.sharedRepositoriesRoot(), RepoStorage.storageBase())
#endif
    }
}
