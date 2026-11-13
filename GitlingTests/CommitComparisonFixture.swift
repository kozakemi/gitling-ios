import Clibgit2
import XCTest
@testable import Gitling

/// Offline object-only commits: creating test versions never requires checkout or network.
final class CommitComparisonFixture {
    let root: URL
    let repo: URL
    let raw: OpaquePointer

    init(_ test: XCTestCase) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let name = "comparison-" + UUID().uuidString
        try GitClient.initialize(name: name, root: root)
        repo = root.appendingPathComponent(name)
        var pointer: OpaquePointer?
        try Self.check(git_repository_open(&pointer, repo.path))
        raw = try XCTUnwrap(pointer)
        let directory = root
        test.addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
            WorktreeLink.remove(repoName: name)
        }
    }
    deinit { git_repository_free(raw) }

    static func check(_ code: Int32) throws {
        guard code >= 0 else {
            throw NSError(domain: "ComparisonFixture", code: Int(code), userInfo: [NSLocalizedDescriptionKey: git_error_last().map { String(cString: $0.pointee.message) } ?? "Git fixture error"])
        }
    }
    func oid(_ text: String) throws -> git_oid {
        var result = git_oid()
        try Self.check(git_oid_fromstr(&result, text))
        return result
    }
    func text(_ value: git_oid) -> String {
        var value = value, buffer = [CChar](repeating: 0, count: 41)
        git_oid_tostr(&buffer, buffer.count, &value)
        return String(cString: buffer)
    }
    func blob(_ data: Data) throws -> String {
        var result = git_oid()
        try Self.check(data.withUnsafeBytes { git_blob_create_from_buffer(&result, raw, $0.baseAddress, $0.count) })
        return text(result)
    }
    func blob(_ value: String) throws -> String { try blob(Data(value.utf8)) }

    /// mode supports regular, executable, symlink and gitlink without accessing their targets.
    func commit(_ files: [String: (String, UInt32)], parents: [String] = [], message: String = "offline comparison") throws -> String {
        var index: OpaquePointer?
        try Self.check(git_index_new(&index))
        defer { git_index_free(index) }
        for (path, file) in files.sorted(by: { $0.key < $1.key }) {
            var entry = git_index_entry()
            entry.mode = file.1
            entry.id = try oid(file.0)
            try path.withCString {
                entry.path = $0
                try Self.check(git_index_add(index, &entry))
            }
        }
        var treeOID = git_oid(), tree: OpaquePointer?
        try Self.check(git_index_write_tree_to(&treeOID, index, raw))
        try Self.check(git_tree_lookup(&tree, raw, &treeOID))
        defer { git_tree_free(tree) }
        var pointers: [OpaquePointer?] = []
        defer { for pointer in pointers { git_commit_free(pointer) } }
        for parent in parents {
            var id = try oid(parent), pointer: OpaquePointer?
            try Self.check(git_commit_lookup(&pointer, raw, &id))
            pointers.append(pointer)
        }
        var signature: UnsafeMutablePointer<git_signature>?, result = git_oid()
        try Self.check(git_signature_now(&signature, "Comparison Author", "comparison@example.invalid"))
        defer { git_signature_free(signature) }
        try pointers.withUnsafeMutableBufferPointer {
            try Self.check(git_commit_create(&result, raw, nil, signature, signature, nil, message, tree, $0.count, $0.baseAddress))
        }
        return text(result)
    }
    func reference(_ name: String, _ target: String) throws {
        var id = try oid(target), ref: OpaquePointer?
        try Self.check(git_reference_create(&ref, raw, name, &id, 1, "offline fixture"))
        git_reference_free(ref)
    }
    func annotated(_ name: String, _ target: String) throws {
        var id = try oid(target), result = git_oid(), object: OpaquePointer?, signature: UnsafeMutablePointer<git_signature>?
        try Self.check(git_object_lookup(&object, raw, &id, GIT_OBJECT_ANY))
        defer { git_object_free(object) }
        try Self.check(git_signature_now(&signature, "Tagger", "tag@example.invalid"))
        defer { git_signature_free(signature) }
        try Self.check(git_tag_create(&result, raw, name, object, signature, "offline annotation", 0))
    }
    func snapshot() throws -> [String: Data] {
        var result: [String: Data] = [:]
        let walker = try XCTUnwrap(FileManager.default.enumerator(at: repo, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]))
        for case let url as URL in walker {
            let path = String(url.path.dropFirst(repo.path.count + 1))
            if path == ".git/objects" { walker.skipDescendants(); continue }
            let flags = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if flags.isSymbolicLink == true {
                result[path] = Data(try FileManager.default.destinationOfSymbolicLink(atPath: url.path).utf8)
            } else if flags.isDirectory != true { result[path] = try Data(contentsOf: url) }
        }
        return result
    }
}
