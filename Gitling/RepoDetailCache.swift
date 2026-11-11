import Foundation

struct RepoDetailSnapshot: Codable {
    var branch = ""
    var detachedOID: String?
    var origin = ""
    var linkedFolder: String?
    var upstream: String?
    var branches: [BranchInfo] = []
    var remotes: [RemoteInfo] = []
    var history: [CommitInfo] = []
    var changes: [StatusEntry] = []
    var statusText = ""
    var sync: SyncCounts?
    var allBranches = true
    var selectedBranch: String?
    var savedAt = Date()
}

enum RepoDetailCache {
    private static let prefix = "gitling.detailCache.v1."

    static func load(_ repoName: String) -> RepoDetailSnapshot? {
        guard let data = UserDefaults.standard.data(forKey: prefix + repoName) else { return nil }
        return try? JSONDecoder().decode(RepoDetailSnapshot.self, from: data)
    }

    static func save(_ snapshot: RepoDetailSnapshot, for repoName: String) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: prefix + repoName)
    }

    static func remove(_ repoName: String) {
        UserDefaults.standard.removeObject(forKey: prefix + repoName)
    }
}
