import Combine
import Darwin
import Foundation

enum CommitSearchField: String, CaseIterable, Identifiable, Sendable {
    case all, message, author, oid
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: String(localized: "All fields")
        case .message: String(localized: "Commit message")
        case .author: String(localized: "Author")
        case .oid: String(localized: "OID prefix")
        }
    }
}

enum HistorySearchScope: Hashable, Sendable {
    case current, all, reference(String)
    var title: String {
        switch self {
        case .current: String(localized: "Current HEAD")
        case .all: String(localized: "All branches and tags")
        case .reference(let ref): ref
        }
    }
}

final class SearchCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func check() throws {
        lock.lock(); let value = cancelled; lock.unlock()
        if value || Task.isCancelled { throw CancellationError() }
    }
}

struct RepositorySearchPage<Item: Sendable>: Sendable {
    var items: [Item]
    var hasMore: Bool
    var scanned: Int
}

/// One reader per query. Page requests serialize on this lock, while cancellation
/// has its own lock and never waits for a long walk on the main thread.
final class RepositorySearchCursor<Item: Sendable>: @unchecked Sendable {
    let cancellation: SearchCancellation
    private let lock = NSLock()
    private let read: (Int, SearchCancellation) throws -> RepositorySearchPage<Item>
    init(cancellation: SearchCancellation, read: @escaping (Int, SearchCancellation) throws -> RepositorySearchPage<Item>) {
        self.cancellation = cancellation; self.read = read
    }
    func nextPage(limit: Int = 100) throws -> RepositorySearchPage<Item> {
        lock.lock(); defer { lock.unlock() }
        try cancellation.check()
        return try read(max(1, min(500, limit)), cancellation)
    }
    func cancel() { cancellation.cancel() }
}

/// Shared publication logic for both search screens. Detached workers cooperate
/// with cancellation; generation checks also protect against late completion.
@MainActor
final class RepositorySearchModel<Item: Sendable>: ObservableObject {
    @Published private(set) var items: [Item] = []
    @Published private(set) var isLoading = false
    @Published private(set) var hasMore = false
    @Published private(set) var scanned = 0
    @Published private(set) var error: String?
    private var generation = 0
    private var cancellation: SearchCancellation?
    private var cursor: RepositorySearchCursor<Item>?

    func cancel() {
        generation += 1; cancellation?.cancel(); cursor?.cancel()
        cancellation = nil; cursor = nil; isLoading = false
    }

    func search(debounce: Bool = true, factory: @escaping @Sendable (SearchCancellation) throws -> RepositorySearchCursor<Item>) async {
        cancel()
        let current = generation, token = SearchCancellation()
        cancellation = token
        items = []; hasMore = false; scanned = 0; error = nil; isLoading = true
        do {
            if debounce { try await Task.sleep(for: .milliseconds(250)) }
            try token.check()
            let worker = Task.detached(priority: .userInitiated) {
                let reader = try factory(token)
                return (reader, try reader.nextPage())
            }
            let (reader, page) = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: { token.cancel(); worker.cancel() }
            guard current == generation, !Task.isCancelled else { reader.cancel(); return }
            cursor = reader; items = page.items; hasMore = page.hasMore; scanned = page.scanned
        } catch is CancellationError {
            if current == generation { hasMore = false }
        } catch {
            if current == generation { self.error = error.localizedDescription; hasMore = false }
        }
        if current == generation { isLoading = false }
    }

    func loadMore() async {
        guard !isLoading, hasMore, let cursor else { return }
        let current = generation
        isLoading = true
        do {
            let worker = Task.detached(priority: .userInitiated) { try cursor.nextPage() }
            let page = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: { cursor.cancel(); worker.cancel() }
            guard current == generation, !Task.isCancelled else { return }
            items.append(contentsOf: page.items); hasMore = page.hasMore; scanned = page.scanned
        } catch is CancellationError {
            if current == generation { hasMore = false }
        } catch {
            if current == generation { self.error = error.localizedDescription; hasMore = false }
        }
        if current == generation { isLoading = false }
    }
}

/// Descriptor-relative traversal and preview. Never follows a symlink or opens
/// a special file, including when a result is replaced before it is selected.
enum SearchWorktreeAccess {
    static func root(_ raw: URL) throws -> URL {
        var info = stat()
        guard raw.path.withCString({ lstat($0, &info) }) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw WorkingTreeError.outside }
        return raw.resolvingSymlinksInPath().standardizedFileURL
    }
    static func components(_ path: String) throws -> [String] {
        if path.isEmpty { return [] }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !path.contains("\0"), parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.lowercased() != ".git" }) else { throw WorkingTreeError.outside }
        return parts
    }
    static func directory(root: URL, path: String = "") throws -> Int32 {
        let parts = try components(path)
        var fd = root.path.withCString { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        guard fd >= 0 else { throw WorkingTreeError.notFound }
        do {
            for part in parts {
                let next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw WorkingTreeError.outside }
                close(fd); fd = next
            }
            return fd
        } catch { close(fd); throw error }
    }
    static func preview(root: URL, path: String) throws -> String {
        let parts = try components(path)
        guard let leaf = parts.last else { throw WorkingTreeError.notFound }
        let parent = try directory(root: root, path: parts.dropLast().joined(separator: "/"))
        defer { close(parent) }
        let fd = openat(parent, leaf, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw WorkingTreeError.outside }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? file.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw WorkingTreeError.outside }
        let maximum = 256 * 1024
        guard info.st_size <= maximum else { throw GitFailure.message(String(localized: "This file is too large to preview.")) }
        var data = Data()
        while let chunk = try file.read(upToCount: min(65_536, maximum + 1 - data.count)), !chunk.isEmpty {
            data.append(chunk)
            guard data.count <= maximum else { throw GitFailure.message(String(localized: "This file is too large to preview.")) }
        }
        guard let text = String(data: data, encoding: .utf8) else { throw GitFailure.message(String(localized: "This file is not UTF-8 text.")) }
        return text
    }
}

final class FileNameSearchReader {
    private struct Directory { let pointer: UnsafeMutablePointer<DIR>; let relative: String }
    private let root: URL
    private let access: WorktreeLink.Access?
    private let identity: RestoreFileAccess.Identity
    private let query: String
    private var stack: [Directory] = []
    private var buffered: WorkEntry?
    private var scanned = 0
    init(root: URL, access: WorktreeLink.Access?, query: String) throws {
        self.root = root; self.access = access; self.query = query
        let fd = try SearchWorktreeAccess.directory(root: root)
        var info = stat()
        guard fstat(fd, &info) == 0 else { close(fd); throw WorkingTreeError.notFound }
        identity = .init(info)
        guard let directory = fdopendir(fd) else { close(fd); throw WorkingTreeError.notFound }
        stack = [.init(pointer: directory, relative: "")]
    }
    deinit { for entry in stack { closedir(entry.pointer) }; access?.stop() }
    func page(limit: Int, cancellation: SearchCancellation) throws -> RepositorySearchPage<WorkEntry> {
        var current = stat()
        guard root.path.withCString({ lstat($0, &current) }) == 0, current.st_mode & S_IFMT == S_IFDIR,
              RestoreFileAccess.Identity(current) == identity else { throw WorkingTreeError.notFound }
        if query.isEmpty { return .init(items: [], hasMore: false, scanned: 0) }
        var result: [WorkEntry] = []
        if let buffered { result.append(buffered); self.buffered = nil }
        while result.count < limit, let item = try next(cancellation) { result.append(item) }
        buffered = try next(cancellation)
        return .init(items: result, hasMore: buffered != nil, scanned: scanned)
    }
    private func next(_ cancellation: SearchCancellation) throws -> WorkEntry? {
        while let directory = stack.last {
            try cancellation.check()
            errno = 0
            guard let entry = readdir(directory.pointer) else {
                guard errno == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                closedir(directory.pointer); stack.removeLast(); continue
            }
            let capacity = Int(entry.pointee.d_namlen) + 1
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: capacity) { String(cString: $0) }
            }
            if name == "." || name == ".." || name.lowercased() == ".git" { continue }
            scanned += 1
            var info = stat()
            if fstatat(dirfd(directory.pointer), name, &info, AT_SYMLINK_NOFOLLOW) != 0 {
                if errno == ENOENT { continue }
                throw WorkingTreeError.notFound
            }
            let path = directory.relative.isEmpty ? name : directory.relative + "/" + name
            if info.st_mode & S_IFMT == S_IFDIR {
                guard stack.count < 128 else { throw GitFailure.message(String(localized: "This file tree is too deep to search safely.")) }
                let child = openat(dirfd(directory.pointer), name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard child >= 0 else {
                    if errno == ENOENT || errno == ELOOP { continue }
                    throw WorkingTreeError.outside
                }
                guard let pointer = fdopendir(child) else { close(child); throw WorkingTreeError.notFound }
                stack.append(.init(pointer: pointer, relative: path))
            } else if info.st_mode & S_IFMT == S_IFREG, path.localizedCaseInsensitiveContains(query) {
                return .init(path: path, name: name, isDirectory: false)
            }
        }
        return nil
    }
}
