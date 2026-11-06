import Foundation

enum RepoStorage {
    static let appGroupIdentifier = "group.com.maneeshacooray.gitling.ios"

    static var groupContainer: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)
    }

    /// True when the workspace is exposed through the app's Documents folder rather than
    /// the File Provider. This is the case on the simulator and on builds signed without
    /// the App Groups entitlement. In both cases the File Provider extension is ignored
    /// by the system, so document sharing is the only way the Files app can see the repos.
    static var usesDocumentsFolder: Bool {
        liveBase().standardizedFileURL.path == documentsBase().standardizedFileURL.path
    }

    /// Where new repositories are written. The File Provider can only read the app group,
    /// so that is the live location whenever the entitlement is present.
    static func repositoriesRoot() -> URL {
        publish()
        return ensure(liveBase().appendingPathComponent("repositories", isDirectory: true))
    }

    /// The File Provider reads this same directory.
    static func sharedRepositoriesRoot() -> URL {
        repositoriesRoot()
    }

    static func storageBase() -> URL {
        publish()
        if usesDocumentsFolder {
            // Bookmarks are an implementation detail; keep them out of the folder that
            // the Files app shows under On My iPhone.
            return applicationSupportBase()
        }
        return groupContainer ?? applicationSupportBase()
    }

    /// Copies anything that exists on only one side, so the app list still has a backup
    /// in Application Support and the Files location still has the live copy.
    static func publish() {
        synchronize()
    }

    static func removeLink(fileName: String) {
        for base in bases() {
            let bookmark = base.appendingPathComponent("worktree-links", isDirectory: true)
                .appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: bookmark.path) {
                try? FileManager.default.removeItem(at: bookmark)
            }
        }
    }

    static func removeRepository(named name: String) throws {
        for base in bases() {
            let repo = base.appendingPathComponent("repositories", isDirectory: true)
                .appendingPathComponent(name, isDirectory: true)
            if FileManager.default.fileExists(atPath: repo.path) {
                try FileManager.default.removeItem(at: repo)
            }
            let bookmark = base.appendingPathComponent("worktree-links", isDirectory: true)
                .appendingPathComponent("\(name).bookmark")
            if FileManager.default.fileExists(atPath: bookmark.path) {
                try FileManager.default.removeItem(at: bookmark)
            }
        }
    }

    static func migrateLegacyRepositoriesIfNeeded() {
        _ = repositoriesRoot()
    }

    private static func applicationSupportBase() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    private static func documentsBase() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private static func liveBase() -> URL {
        #if targetEnvironment(simulator)
        // Simulator installs are ad-hoc signed and the Files extension cannot obtain the
        // App Group container, even though the app itself can. Store the visible copy in
        // Documents so the Files app still has a Gitling entry.
        return documentsBase()
        #else
        // Sideloaded/unsigned builds lose the App Groups entitlement. Fall back to the
        // app's Documents folder, which document sharing exposes in the Files app.
        return groupContainer ?? documentsBase()
        #endif
    }

    private static func bases() -> [URL] {
        var listed = [applicationSupportBase(), documentsBase()]
        if let group = groupContainer {
            listed.append(group)
        }
        var unique: [URL] = []
        for base in listed where !unique.contains(where: { $0.standardizedFileURL.path == base.standardizedFileURL.path }) {
            unique.append(base)
        }
        return unique
    }

    private static func ensure(_ url: URL) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Copies repositories and bookmarks into the live location when that side is missing,
    /// then keeps the Application Support copy as a backup. Nothing is moved, so a build
    /// that cannot see the app group still has a usable app copy.
    private static func synchronize() {
        let live = liveBase()
        let local = applicationSupportBase()
        let documents = documentsBase()
        var sources = [local]
        if let group = groupContainer {
            sources.append(group)
        }
        if documents.standardizedFileURL.path != live.standardizedFileURL.path {
            sources.append(documents)
        }
        for source in sources where source.standardizedFileURL.path != live.standardizedFileURL.path {
            copyMissing(
                from: source.appendingPathComponent("repositories", isDirectory: true),
                to: live.appendingPathComponent("repositories", isDirectory: true)
            )
            if !usesDocumentsFolder {
                copyMissing(
                    from: source.appendingPathComponent("worktree-links", isDirectory: true),
                    to: live.appendingPathComponent("worktree-links", isDirectory: true)
                )
            }
        }
        if live.standardizedFileURL.path != local.standardizedFileURL.path {
            copyMissing(
                from: live.appendingPathComponent("repositories", isDirectory: true),
                to: local.appendingPathComponent("repositories", isDirectory: true)
            )
            if !usesDocumentsFolder {
                copyMissing(
                    from: live.appendingPathComponent("worktree-links", isDirectory: true),
                    to: local.appendingPathComponent("worktree-links", isDirectory: true)
                )
            }
        }
        if usesDocumentsFolder {
            var linkSources = [documents]
            if let group = groupContainer {
                linkSources.append(group)
            }
            for source in linkSources {
                moveLinks(
                    from: source.appendingPathComponent("worktree-links", isDirectory: true),
                    to: local.appendingPathComponent("worktree-links", isDirectory: true)
                )
            }
        }
    }

    /// Moves bookmark files into the hidden Application Support location. Existing links
    /// must keep working after the Files folder stopped showing the worktree-links folder.
    private static func moveLinks(from source: URL, to destination: URL) {
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        let items = (try? FileManager.default.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: nil,
            options: []
        )) ?? []
        try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        for item in items {
            let target = destination.appendingPathComponent(item.lastPathComponent)
            if !FileManager.default.fileExists(atPath: target.path) {
                guard (try? FileManager.default.copyItem(at: item, to: target)) != nil else { continue }
            }
            try? FileManager.default.removeItem(at: item)
        }
        if let remaining = try? FileManager.default.contentsOfDirectory(atPath: source.path), remaining.isEmpty {
            try? FileManager.default.removeItem(at: source)
        }
    }

    private static func copyMissing(from source: URL, to destination: URL) {
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let items = (try? FileManager.default.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: nil,
            options: []
        )) ?? []
        for item in items {
            let target = destination.appendingPathComponent(item.lastPathComponent)
            if !FileManager.default.fileExists(atPath: target.path) {
                try? FileManager.default.copyItem(at: item, to: target)
                continue
            }
            let sourceGit = item.appendingPathComponent(".git")
            let targetGit = target.appendingPathComponent(".git")
            if FileManager.default.fileExists(atPath: sourceGit.path),
               !FileManager.default.fileExists(atPath: targetGit.path) {
                try? FileManager.default.removeItem(at: target)
                try? FileManager.default.copyItem(at: item, to: target)
            }
        }
    }
}
