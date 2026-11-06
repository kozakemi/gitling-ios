import Foundation

enum WorkingTreeError: Error, Equatable, LocalizedError {
    case notFound
    case invalidName
    case busy
    case repoProtected
    case outside
    case collision

    var errorDescription: String? {
        switch self {
        case .notFound:
            String(localized: "Could not find that file.")
        case .invalidName:
            String(localized: "That name cannot be used.")
        case .busy:
            String(localized: "A Git operation is running on this repository. Try again shortly.")
        case .repoProtected:
            String(localized: "Repositories can only be deleted from within Gitling.")
        case .outside:
            String(localized: "Could not find that file.")
        case .collision:
            String(localized: "That name is already used.")
        }
    }
}

enum WorkingTree {
    struct Node: Equatable {
        var repoName: String
        var repoURL: URL
        var fileURL: URL
        var relative: String
        var isRepoRoot: Bool
        var isDirectory: Bool
        var fileSize: Int?
        var modified: Date?
    }

    static func identifier(repo name: String, relative: String = "") -> String {
        relative.isEmpty ? "repo:\(name)" : "repo:\(name)/\(relative)"
    }

    static func repositories(in root: URL) -> [Node] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return urls.compactMap { url in
            let directory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard directory else { return nil }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            return Node(
                repoName: url.lastPathComponent,
                repoURL: url,
                fileURL: url,
                relative: "",
                isRepoRoot: true,
                isDirectory: true,
                fileSize: nil,
                modified: values?.contentModificationDate
            )
        }
        .sorted { $0.repoName.localizedStandardCompare($1.repoName) == .orderedAscending }
    }

    static func node(root: URL, identifier: String, workRoot: URL? = nil) throws -> Node {
        guard identifier.hasPrefix("repo:") else { throw WorkingTreeError.notFound }
        let body = String(identifier.dropFirst("repo:".count))
        guard !body.isEmpty else { throw WorkingTreeError.notFound }
        let name: String
        let relative: String
        if let slash = body.firstIndex(of: "/") {
            name = String(body[..<slash])
            relative = String(body[body.index(after: slash)...])
        } else {
            name = body
            relative = ""
        }
        try requireSafeName(name)
        let parts = try pathParts(relative)
        let repoURL = root.appendingPathComponent(name, isDirectory: true)
        let base = workRoot ?? repoURL
        var fileURL = base
        for part in parts {
            fileURL.appendPathComponent(part)
        }
        try requireInside(fileURL, repo: base)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory) else {
            throw WorkingTreeError.notFound
        }
        let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return Node(
            repoName: name,
            repoURL: repoURL,
            fileURL: fileURL,
            relative: parts.joined(separator: "/"),
            isRepoRoot: parts.isEmpty,
            isDirectory: isDirectory.boolValue,
            fileSize: values?.fileSize,
            modified: values?.contentModificationDate
        )
    }

    static func children(root: URL, identifier: String, workRoot: URL? = nil) throws -> [Node] {
        let parent = try node(root: root, identifier: identifier, workRoot: workRoot)
        guard parent.isDirectory else { return [] }
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: parent.fileURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        )) ?? []
        var children: [Node] = []
        for url in urls {
            if url.lastPathComponent == ".git" { continue }
            let relative = parent.relative.isEmpty
                ? url.lastPathComponent
                : parent.relative + "/" + url.lastPathComponent
            if let child = try? node(root: root, identifier: Self.identifier(repo: parent.repoName, relative: relative), workRoot: workRoot) {
                children.append(child)
            }
        }
        return children.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory && !rhs.isDirectory }
            return lhs.fileURL.lastPathComponent.localizedStandardCompare(rhs.fileURL.lastPathComponent) == .orderedAscending
        }
    }

    static func parentIdentifier(of node: Node) -> String? {
        if node.isRepoRoot { return nil }
        guard let slash = node.relative.lastIndex(of: "/") else {
            return identifier(repo: node.repoName)
        }
        return identifier(repo: node.repoName, relative: String(node.relative[..<slash]))
    }

    static func create(
        root: URL,
        parentIdentifier: String,
        name: String,
        isDirectory: Bool,
        contents: Data?,
        workRoot: URL? = nil
    ) throws -> String {
        let parent = try node(root: root, identifier: parentIdentifier, workRoot: workRoot)
        guard parent.isDirectory else { throw WorkingTreeError.invalidName }
        try requireSafeName(name)
        return try RepoWriteLock.withSharedLock(at: parent.repoURL) {
            var targetName = name
            var attempt = 1
            var target = parent.fileURL.appendingPathComponent(targetName)
            while FileManager.default.fileExists(atPath: target.path) {
                targetName = "\(name) (\(attempt))"
                attempt += 1
                if attempt > 100 { throw WorkingTreeError.collision }
                target = parent.fileURL.appendingPathComponent(targetName)
            }
            if isDirectory {
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
            } else {
                try (contents ?? Data()).write(to: target, options: .atomic)
            }
            let relative = parent.relative.isEmpty ? targetName : parent.relative + "/" + targetName
            return identifier(repo: parent.repoName, relative: relative)
        }
    }

    static func update(
        root: URL,
        identifier: String,
        newName: String?,
        newParentIdentifier: String?,
        contents: URL?,
        workRoot: URL? = nil
    ) throws -> String {
        let current = try node(root: root, identifier: identifier, workRoot: workRoot)
        guard !current.isRepoRoot else { throw WorkingTreeError.repoProtected }
        let parentID = newParentIdentifier ?? parentIdentifier(of: current) ?? identifier
        let parent = try node(root: root, identifier: parentID, workRoot: workRoot)
        guard parent.isDirectory, parent.repoName == current.repoName else { throw WorkingTreeError.outside }
        let name = newName ?? current.fileURL.lastPathComponent
        try requireSafeName(name)
        return try RepoWriteLock.withSharedLock(at: current.repoURL) {
            let destination = parent.fileURL.appendingPathComponent(name)
            let sameFile = destination.standardizedFileURL.path == current.fileURL.standardizedFileURL.path
            if !sameFile {
                if FileManager.default.fileExists(atPath: destination.path) { throw WorkingTreeError.collision }
                try FileManager.default.moveItem(at: current.fileURL, to: destination)
            }
            if let contents, !current.isDirectory {
                let data = try Data(contentsOf: contents)
                try data.write(to: destination, options: .atomic)
            }
            let relative = parent.relative.isEmpty ? name : parent.relative + "/" + name
            return WorkingTree.identifier(repo: current.repoName, relative: relative)
        }
    }

    static func delete(root: URL, identifier: String, workRoot: URL? = nil) throws {
        let current = try node(root: root, identifier: identifier, workRoot: workRoot)
        guard !current.isRepoRoot else { throw WorkingTreeError.repoProtected }
        try RepoWriteLock.withSharedLock(at: current.repoURL) {
            try FileManager.default.removeItem(at: current.fileURL)
        }
    }

    static func requireSafeName(_ name: String) throws {
        if name.isEmpty || name == "." || name == ".." || name == ".git"
            || name.contains("/") || name.contains("\\") || name.contains("\0") {
            throw WorkingTreeError.invalidName
        }
    }

    private static func pathParts(_ relative: String) throws -> [String] {
        if relative.isEmpty { return [] }
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        for part in parts {
            try requireSafeName(part)
        }
        return parts
    }

    private static func requireInside(_ fileURL: URL, repo repoURL: URL) throws {
        let repoPath = repoURL.resolvingSymlinksInPath().standardizedFileURL.path
        let filePath = fileURL.resolvingSymlinksInPath().standardizedFileURL.path
        if filePath != repoPath && !filePath.hasPrefix(repoPath + "/") {
            throw WorkingTreeError.outside
        }
        let relative = filePath == repoPath ? "" : String(filePath.dropFirst(repoPath.count + 1))
        if relative.split(separator: "/").contains(where: { $0 == ".git" }) {
            throw WorkingTreeError.outside
        }
    }
}
