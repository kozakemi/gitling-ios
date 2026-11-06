import FileProvider
import Foundation
import UniformTypeIdentifiers

final class GitlingFileProvider: NSObject, NSFileProviderReplicatedExtension {
    required init(domain: NSFileProviderDomain) {
        super.init()
    }

    func invalidate() {}

    func item(
        for identifier: NSFileProviderItemIdentifier,
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        do {
            completionHandler(try ProviderItem.item(for: identifier), nil)
        } catch {
            completionHandler(nil, ProviderError.wrap(error))
        }
        return Progress()
    }

    func fetchContents(
        for itemIdentifier: NSFileProviderItemIdentifier,
        version requestedVersion: NSFileProviderItemVersion?,
        request: NSFileProviderRequest,
        completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        do {
            let copy = try ProviderContext.withWorkRoot(itemIdentifier.rawValue) { workRoot in
                let node = try WorkingTree.node(
                    root: RepoStorage.sharedRepositoriesRoot(),
                    identifier: itemIdentifier.rawValue,
                    workRoot: workRoot
                )
                guard !node.isDirectory else { throw WorkingTreeError.notFound }
                let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try FileManager.default.copyItem(at: node.fileURL, to: copy)
                return copy
            }
            completionHandler(copy, try ProviderItem.item(for: itemIdentifier), nil)
        } catch {
            completionHandler(nil, nil, ProviderError.wrap(error))
        }
        return Progress()
    }

    func createItem(
        basedOn itemTemplate: NSFileProviderItem,
        fields: NSFileProviderItemFields,
        contents url: URL?,
        options: NSFileProviderCreateItemOptions,
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        do {
            guard itemTemplate.parentItemIdentifier != .rootContainer else { throw WorkingTreeError.repoProtected }
            let type = itemTemplate.contentType ?? .data
            let data = url.flatMap { try? Data(contentsOf: $0) }
            let created = try ProviderContext.withWorkRoot(itemTemplate.parentItemIdentifier.rawValue) { workRoot in
                try WorkingTree.create(
                    root: RepoStorage.sharedRepositoriesRoot(),
                    parentIdentifier: itemTemplate.parentItemIdentifier.rawValue,
                    name: itemTemplate.filename,
                    isDirectory: type.conforms(to: .folder),
                    contents: data,
                    workRoot: workRoot
                )
            }
            let item = try ProviderItem.item(for: NSFileProviderItemIdentifier(created))
            completionHandler(item, [], false, nil)
        } catch {
            completionHandler(nil, [], false, ProviderError.wrap(error))
        }
        return Progress()
    }

    func modifyItem(
        _ item: NSFileProviderItem,
        baseVersion: NSFileProviderItemVersion,
        changedFields: NSFileProviderItemFields,
        contents newContents: URL?,
        options: NSFileProviderModifyItemOptions,
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        do {
            let newName = changedFields.contains(.filename) ? item.filename : nil
            let newParent = changedFields.contains(.parentItemIdentifier) ? item.parentItemIdentifier.rawValue : nil
            let contents = changedFields.contains(.contents) ? newContents : nil
            let updated = try ProviderContext.withWorkRoot(item.itemIdentifier.rawValue) { workRoot in
                try WorkingTree.update(
                    root: RepoStorage.sharedRepositoriesRoot(),
                    identifier: item.itemIdentifier.rawValue,
                    newName: newName,
                    newParentIdentifier: newParent,
                    contents: contents,
                    workRoot: workRoot
                )
            }
            completionHandler(try ProviderItem.item(for: NSFileProviderItemIdentifier(updated)), [], false, nil)
        } catch {
            completionHandler(nil, [], false, ProviderError.wrap(error))
        }
        return Progress()
    }

    func deleteItem(
        identifier: NSFileProviderItemIdentifier,
        baseVersion: NSFileProviderItemVersion,
        options: NSFileProviderDeleteItemOptions,
        request: NSFileProviderRequest,
        completionHandler: @escaping (Error?) -> Void
    ) -> Progress {
        do {
            try ProviderContext.withWorkRoot(identifier.rawValue) { workRoot in
                try WorkingTree.delete(
                    root: RepoStorage.sharedRepositoriesRoot(),
                    identifier: identifier.rawValue,
                    workRoot: workRoot
                )
            }
            completionHandler(nil)
        } catch {
            completionHandler(ProviderError.wrap(error))
        }
        return Progress()
    }

    func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest) throws -> NSFileProviderEnumerator {
        ProviderEnumerator(container: containerItemIdentifier)
    }
}

private enum ProviderContext {
    static func node(_ identifier: String) throws -> WorkingTree.Node {
        try withWorkRoot(identifier) { workRoot in
            try WorkingTree.node(root: RepoStorage.sharedRepositoriesRoot(), identifier: identifier, workRoot: workRoot)
        }
    }

    static func withWorkRoot<T>(_ identifier: String, _ body: (URL?) throws -> T) throws -> T {
        let access = WorktreeLink.repoName(in: identifier).flatMap { WorktreeLink.begin(repoName: $0) }
        defer { access?.stop() }
        return try body(access?.url)
    }
}

private enum ProviderError {
    static func wrap(_ error: Error) -> Error {
        guard let tree = error as? WorkingTreeError else { return error }
        switch tree {
        case .notFound, .outside:
            return NSError(domain: NSFileProviderErrorDomain, code: NSFileProviderError.Code.noSuchItem.rawValue)
        case .collision:
            return NSError(domain: NSFileProviderErrorDomain, code: NSFileProviderError.Code.filenameCollision.rawValue)
        default:
            return tree
        }
    }
}

private final class ProviderItem: NSObject, NSFileProviderItem {
    let itemIdentifier: NSFileProviderItemIdentifier
    let parentItemIdentifier: NSFileProviderItemIdentifier
    let filename: String
    let contentType: UTType
    let documentSize: NSNumber?
    let childItemCount: NSNumber?
    let contentModificationDate: Date?
    let capabilities: NSFileProviderItemCapabilities
    let itemVersion: NSFileProviderItemVersion

    var isDownloaded: Bool { true }
    var isUploaded: Bool { true }

    init(
        identifier: NSFileProviderItemIdentifier,
        parent: NSFileProviderItemIdentifier,
        filename: String,
        contentType: UTType,
        documentSize: NSNumber?,
        childItemCount: NSNumber?,
        modified: Date?,
        capabilities: NSFileProviderItemCapabilities
    ) {
        self.itemIdentifier = identifier
        self.parentItemIdentifier = parent
        self.filename = filename
        self.contentType = contentType
        self.documentSize = documentSize
        self.childItemCount = childItemCount
        self.contentModificationDate = modified
        self.capabilities = capabilities
        let stamp = Data("\(filename)-\(modified?.timeIntervalSince1970 ?? 0)-\(documentSize?.intValue ?? 0)".utf8)
        self.itemVersion = NSFileProviderItemVersion(contentVersion: stamp, metadataVersion: stamp)
        super.init()
    }

    static func item(for identifier: NSFileProviderItemIdentifier) throws -> ProviderItem {
        if identifier == .rootContainer {
            return ProviderItem(
                identifier: .rootContainer,
                parent: .rootContainer,
                filename: "Gitling",
                contentType: .folder,
                documentSize: nil,
                childItemCount: nil,
                modified: nil,
                capabilities: [.allowsContentEnumerating, .allowsReading]
            )
        }
        if identifier == .workingSet {
            return ProviderItem(
                identifier: identifier,
                parent: .rootContainer,
                filename: String(localized: "Working Set"),
                contentType: .folder,
                documentSize: nil,
                childItemCount: 0,
                modified: nil,
                capabilities: [.allowsContentEnumerating, .allowsReading]
            )
        }
        if identifier == .trashContainer {
            return ProviderItem(
                identifier: identifier,
                parent: .rootContainer,
                filename: String(localized: "Trash"),
                contentType: .folder,
                documentSize: nil,
                childItemCount: 0,
                modified: nil,
                capabilities: [.allowsContentEnumerating, .allowsReading]
            )
        }
        let node = try ProviderContext.node(identifier.rawValue)
        return ProviderItem(node: node)
    }

    convenience init(node: WorkingTree.Node) {
        let parent: NSFileProviderItemIdentifier
        if let parentID = WorkingTree.parentIdentifier(of: node) {
            parent = NSFileProviderItemIdentifier(parentID)
        } else {
            parent = .rootContainer
        }
        let capabilities: NSFileProviderItemCapabilities
        if node.isRepoRoot {
            capabilities = [.allowsContentEnumerating, .allowsReading, .allowsAddingSubItems]
        } else if node.isDirectory {
            capabilities = [.allowsContentEnumerating, .allowsReading, .allowsAddingSubItems, .allowsRenaming, .allowsDeleting]
        } else {
            capabilities = [.allowsReading, .allowsWriting, .allowsRenaming, .allowsDeleting]
        }
        let type: UTType = node.isDirectory
            ? .folder
            : (UTType(filenameExtension: node.fileURL.pathExtension) ?? .data)
        self.init(
            identifier: NSFileProviderItemIdentifier(WorkingTree.identifier(repo: node.repoName, relative: node.relative)),
            parent: parent,
            filename: node.isRepoRoot ? node.repoName : node.fileURL.lastPathComponent,
            contentType: type,
            documentSize: node.fileSize.map { NSNumber(value: $0) },
            childItemCount: nil,
            modified: node.modified,
            capabilities: capabilities
        )
    }
}

private final class ProviderEnumerator: NSObject, NSFileProviderEnumerator {
    let container: NSFileProviderItemIdentifier

    init(container: NSFileProviderItemIdentifier) {
        self.container = container
    }

    func invalidate() {}

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        let nodes = items()
        let identifiers = Set(nodes.map { WorkingTree.identifier(repo: $0.repoName, relative: $0.relative) })
        Self.knownLock.lock()
        Self.known[container.rawValue] = identifiers
        Self.knownLock.unlock()
        observer.didEnumerate(nodes.map { ProviderItem(node: $0) })
        observer.finishEnumerating(upTo: nil)
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(syncAnchor(for: items()))
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        let nodes = items()
        let identifiers = Set(nodes.map { WorkingTree.identifier(repo: $0.repoName, relative: $0.relative) })
        Self.knownLock.lock()
        let removed = Self.known[container.rawValue, default: []].subtracting(identifiers)
        Self.known[container.rawValue] = identifiers
        Self.knownLock.unlock()
        let newAnchor = syncAnchor(for: nodes)
        if removed.isEmpty && newAnchor == anchor {
            observer.finishEnumeratingChanges(upTo: newAnchor, moreComing: false)
            return
        }
        if !removed.isEmpty {
            observer.didDeleteItems(withIdentifiers: removed.map { NSFileProviderItemIdentifier($0) })
        }
        if !nodes.isEmpty {
            observer.didUpdate(nodes.map { ProviderItem(node: $0) })
        }
        observer.finishEnumeratingChanges(upTo: newAnchor, moreComing: false)
    }

    private static let knownLock = NSLock()
    private static var known: [String: Set<String>] = [:]

    private func syncAnchor(for nodes: [WorkingTree.Node]) -> NSFileProviderSyncAnchor {
        // A stable per-container signature. When it changes, the system asks for the
        // changed items instead of falling back to a full re-enumeration.
        var value: UInt64 = 1469598103934665603
        func mix(_ text: String) {
            for byte in text.utf8 {
                value ^= UInt64(byte)
                value = value &* 1099511628211
            }
        }
        mix(container.rawValue)
        for node in nodes {
            mix(WorkingTree.identifier(repo: node.repoName, relative: node.relative))
            mix("\(node.modified?.timeIntervalSince1970 ?? 0):\(node.fileSize ?? 0)")
        }
        var bigEndian = value.bigEndian
        return NSFileProviderSyncAnchor(Data(bytes: &bigEndian, count: MemoryLayout<UInt64>.size))
    }

    private func items() -> [WorkingTree.Node] {
        let root = RepoStorage.sharedRepositoriesRoot()
        if container == .rootContainer {
            return WorkingTree.repositories(in: root)
        }
        if container == .workingSet || container == .trashContainer {
            return []
        }
        return (try? ProviderContext.withWorkRoot(container.rawValue) { workRoot in
            try WorkingTree.children(root: root, identifier: container.rawValue, workRoot: workRoot)
        }) ?? []
    }
}
