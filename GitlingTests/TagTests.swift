import XCTest
import Clibgit2
@testable import Gitling

final class TagTests: XCTestCase {
    private func repository() throws -> (URL, String, String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let name = "tags-" + UUID().uuidString
        try GitClient.initialize(name: name, root: root)
        let repo = root.appendingPathComponent(name)
        addTeardownBlock { try? FileManager.default.removeItem(at: root); WorktreeLink.remove(repoName: name) }
        try write("first\n", repo)
        try commit(repo)
        let first = try head(repo)
        _ = try tag(repo, name: "v1", target: first)
        try write("second\n", repo); try commit(repo)
        let second = try head(repo)
        _ = try tag(repo, name: "release/版本-v2", target: second, annotated: true)
        return (repo, first, second)
    }
    private func write(_ text: String, _ repo: URL, path: String = "a.txt") throws {
        try text.write(to: repo.appendingPathComponent(path), atomically: true, encoding: .utf8)
    }
    private func commit(_ repo: URL) throws {
        try GitClient.stageAll(at: repo)
        try GitClient.commit(at: repo, message: "offline tag fixture", name: "Tag Test", email: "tag@example.invalid")
    }
    private func head(_ repo: URL) throws -> String { try GitClient.history(at: repo, limit: 1)[0].id }
    private func bytes(_ repo: URL, _ path: String) throws -> Data { try Data(contentsOf: repo.appendingPathComponent(path)) }
    private func withRepo<T>(_ url: URL, _ body: (OpaquePointer) throws -> T) throws -> T {
        var repo: OpaquePointer?
        XCTAssertEqual(git_repository_open(&repo, url.path), 0)
        let opened = try XCTUnwrap(repo)
        defer { git_repository_free(opened) }
        return try body(opened)
    }
    @discardableResult private func reference(_ repo: URL, name: String, target: String) throws -> String {
        try withRepo(repo) { raw in
            var oid = git_oid(), ref: OpaquePointer?
            XCTAssertEqual(git_oid_fromstr(&oid, target), 0)
            XCTAssertEqual(git_reference_create(&ref, raw, name, &oid, 1, "offline test"), 0)
            defer { git_reference_free(ref) }
            return target
        }
    }
    private func oidText(_ oid: git_oid) -> String {
        var value = oid, buffer = [CChar](repeating: 0, count: 41)
        git_oid_tostr(&buffer, buffer.count, &value)
        return String(cString: buffer)
    }
    @discardableResult private func tag(_ repo: URL, name: String, target: String, annotated: Bool = false) throws -> String {
        if !annotated { return try reference(repo, name: "refs/tags/" + name, target: target) }
        return try withRepo(repo) { raw in
            var targetOID = git_oid(), result = git_oid(), object: OpaquePointer?, signature: UnsafeMutablePointer<git_signature>?
            XCTAssertEqual(git_oid_fromstr(&targetOID, target), 0)
            XCTAssertEqual(git_object_lookup(&object, raw, &targetOID, GIT_OBJECT_ANY), 0)
            defer { git_object_free(object) }
            XCTAssertEqual(git_signature_now(&signature, "Tagger", "tagger@example.invalid"), 0)
            defer { git_signature_free(signature) }
            XCTAssertEqual(git_tag_create(&result, raw, name, object, signature, "Release notes\n中文说明\n", 0), 0)
            return oidText(result)
        }
    }

    func testLightweightAnnotatedNestedAndUnicodeTagsHaveCorrectDetailsWithoutWrites() throws {
        let (repo, first, second) = try repository()
        let annotated = try GitClient.tagDetail(at: repo, name: "release/版本-v2")
        _ = try tag(repo, name: "nested", target: annotated.tag.referenceOID, annotated: true)
        let before = try bytes(repo, ".git/index")
        try write("uncommitted\n", repo)
        let tags = try GitClient.tags(at: repo)
        XCTAssertEqual(Set(tags.map(\.name)), ["v1", "release/版本-v2", "nested"])
        XCTAssertFalse(try XCTUnwrap(tags.first { $0.name == "v1" }).annotated)
        XCTAssertTrue(annotated.tag.annotated)
        XCTAssertEqual(annotated.targetOID, second)
        XCTAssertEqual(annotated.tagger, "Tagger <tagger@example.invalid>")
        XCTAssertNotNil(annotated.tagDate)
        XCTAssertEqual(annotated.message, "Release notes\n中文说明\n")
        XCTAssertEqual(annotated.commit?.author, "Tag Test")
        XCTAssertEqual(try GitClient.tagDetail(at: repo, name: "nested").targetOID, second)
        let light = try GitClient.tagDetail(at: repo, name: "v1")
        XCTAssertEqual(light.targetOID, first)
        XCTAssertNil(light.message); XCTAssertNil(light.tagger)
        XCTAssertEqual(try bytes(repo, ".git/index"), before)
        XCTAssertEqual(try String(contentsOf: repo.appendingPathComponent("a.txt"), encoding: .utf8), "uncommitted\n")
    }

    func testCheckoutDetachesHeadWithoutMovingBranchOrTagsAndCanReturnToBranch() throws {
        let (repo, first, second) = try repository()
        let detail = try GitClient.tagDetail(at: repo, name: "v1")
        try GitClient.checkoutTag(at: repo, tag: detail)
        XCTAssertEqual(try head(repo), first)
        XCTAssertEqual(try GitClient.header(at: repo).detachedOID, first)
        XCTAssertTrue(try GitClient.header(at: repo).branch.contains("HEAD"))
        XCTAssertTrue(try XCTUnwrap(GitClient.summary(at: repo)?.branch).contains("HEAD"))
        XCTAssertTrue(try GitClient.statusText(at: repo).contains("HEAD"))
        XCTAssertEqual(try GitClient.statusText(at: repo).components(separatedBy: "\n").first, try GitClient.header(at: repo).branch)
        XCTAssertEqual(try String(contentsOf: repo.appendingPathComponent(".git/HEAD"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), first)
        XCTAssertEqual(try GitClient.branches(at: repo).first { $0.name == "master" }?.target, second)
        XCTAssertTrue(try GitClient.branches(at: repo).allSatisfy { !$0.isCurrent })
        XCTAssertEqual(try GitClient.tagDetail(at: repo, name: "v1").targetOID, first)
        XCTAssertEqual(try String(contentsOf: repo.appendingPathComponent("a.txt"), encoding: .utf8), "first\n")
        XCTAssertTrue(try GitClient.status(at: repo).isEmpty)
        try GitClient.checkout(at: repo, branch: "master")
        XCTAssertNil(try GitClient.header(at: repo).detachedOID)
        XCTAssertEqual(try head(repo), second)
    }

    func testAnnotatedTagCheckoutAndCreatingBranchKeepDetachedCommitReachable() throws {
        let (repo, _, second) = try repository()
        try GitClient.checkoutTag(at: repo, tag: GitClient.tagDetail(at: repo, name: "release/版本-v2"))
        XCTAssertEqual(try GitClient.header(at: repo).detachedOID, second)
        try write("detached work\n", repo); try commit(repo)
        let detachedCommit = try head(repo)
        try GitClient.createBranch(at: repo, name: "keep/tag-work", checkout: true)
        XCTAssertEqual(try head(repo), detachedCommit)
        XCTAssertNil(try GitClient.header(at: repo).detachedOID)
        XCTAssertEqual(try GitClient.branches(at: repo).first { $0.isCurrent }?.name, "keep/tag-work")
    }

    func testDirtyStagedUnstagedUntrackedAndDeletedFilesBlockCheckoutWithoutChanges() throws {
        for kind in ["staged", "unstaged", "untracked", "deleted"] {
            let (repo, _, second) = try repository()
            let detail = try GitClient.tagDetail(at: repo, name: "v1")
            if kind == "deleted" { try FileManager.default.removeItem(at: repo.appendingPathComponent("a.txt")) }
            else { try write("keep \(kind)\n", repo, path: kind == "untracked" ? "new.txt" : "a.txt") }
            if kind == "staged" { try GitClient.stage(at: repo, path: "a.txt") }
            let before = try bytes(repo, ".git/index"), status = try GitClient.status(at: repo)
            XCTAssertThrowsError(try GitClient.checkoutTag(at: repo, tag: detail))
            XCTAssertEqual(try head(repo), second)
            XCTAssertNil(try GitClient.header(at: repo).detachedOID)
            XCTAssertEqual(try bytes(repo, ".git/index"), before)
            XCTAssertEqual(try GitClient.status(at: repo), status)
            if kind != "deleted" { XCTAssertEqual(try String(contentsOf: repo.appendingPathComponent(kind == "untracked" ? "new.txt" : "a.txt"), encoding: .utf8), "keep \(kind)\n") }
        }
    }

    func testTagRetargetedOrDeletedDuringConfirmationNeverChecksOutAnotherCommit() throws {
        let (repo, _, second) = try repository()
        let detail = try GitClient.tagDetail(at: repo, name: "v1"), before = try bytes(repo, ".git/index")
        try reference(repo, name: "refs/tags/v1", target: second)
        XCTAssertThrowsError(try GitClient.checkoutTag(at: repo, tag: detail))
        try withRepo(repo) { raw in XCTAssertEqual(git_reference_remove(raw, "refs/tags/v1"), 0) }
        XCTAssertThrowsError(try GitClient.checkoutTag(at: repo, tag: detail))
        XCTAssertEqual(try head(repo), second)
        XCTAssertEqual(try bytes(repo, ".git/index"), before)
    }

    func testSameNamedBranchAndTagResolveOnlyExactTagReference() throws {
        let (repo, first, _) = try repository()
        try GitClient.createBranch(at: repo, name: "v1", checkout: false)
        try GitClient.checkoutTag(at: repo, tag: GitClient.tagDetail(at: repo, name: "v1"))
        XCTAssertEqual(try head(repo), first)
        XCTAssertThrowsError(try GitClient.tagDetail(at: repo, name: "master"))
        for invalid in ["", "../heads/master", "v1\0tail", "bad name"] {
            XCTAssertThrowsError(try GitClient.tagDetail(at: repo, name: invalid))
        }
    }

    func testReferenceAndIndexLocksFailBeforeChangingFilesOrHead() throws {
        for lock in [".git/HEAD.lock", ".git/index.lock", ".git/refs/tags/v1.lock"] {
            let (repo, _, second) = try repository()
            let detail = try GitClient.tagDetail(at: repo, name: "v1"), before = try bytes(repo, ".git/index"), file = try bytes(repo, "a.txt")
            try Data("test lock".utf8).write(to: repo.appendingPathComponent(lock))
            XCTAssertThrowsError(try GitClient.checkoutTag(at: repo, tag: detail), lock)
            XCTAssertEqual(try head(repo), second, lock)
            XCTAssertEqual(try bytes(repo, ".git/index"), before, lock)
            XCTAssertEqual(try bytes(repo, "a.txt"), file, lock)
        }
    }

    func testIgnoredCollisionAndSymlinkTargetAreProtected() throws {
        for symbolic in [false, true] {
            let (repo, _, _) = try repository()
            try write("upstream\n", repo, path: "collision.txt"); try commit(repo)
            let target = try head(repo)
            try tag(repo, name: "with-new-file", target: target)
            try GitClient.checkoutTag(at: repo, tag: GitClient.tagDetail(at: repo, name: "v1"))
            let original = try head(repo), before = try bytes(repo, ".git/index")
            try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git/info"), withIntermediateDirectories: true)
            try write("collision.txt\n", repo, path: ".git/info/exclude")
            let destination = repo.appendingPathComponent("collision.txt")
            if symbolic {
                let outside = repo.deletingLastPathComponent().appendingPathComponent("outside")
                try "keep outside\n".write(to: outside, atomically: true, encoding: .utf8)
                try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: outside)
            } else { try write("keep ignored\n", repo, path: "collision.txt") }
            XCTAssertThrowsError(try GitClient.checkoutTag(at: repo, tag: GitClient.tagDetail(at: repo, name: "with-new-file")))
            XCTAssertEqual(try head(repo), original)
            XCTAssertEqual(try bytes(repo, ".git/index"), before)
            XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), symbolic ? "keep outside\n" : "keep ignored\n")
        }
    }

    func testBlobAndTreeTagsCanBeInspectedButNeverCheckedOut() throws {
        let (repo, _, second) = try repository()
        let blob = try withRepo(repo) { raw -> String in
            var oid = git_oid()
            let data = Data(repeating: 0x81, count: 8 * 1024 * 1024)
            XCTAssertEqual(data.withUnsafeBytes { git_blob_create_from_buffer(&oid, raw, $0.baseAddress, $0.count) }, 0)
            return oidText(oid)
        }
        let tree = try withRepo(repo) { raw -> String in
            var oid = git_oid(), commit: OpaquePointer?
            XCTAssertEqual(git_oid_fromstr(&oid, second), 0)
            XCTAssertEqual(git_commit_lookup(&commit, raw, &oid), 0)
            defer { git_commit_free(commit) }
            return oidText(git_commit_tree_id(commit).pointee)
        }
        for (name, oid, type) in [("blob-tag", blob, "blob"), ("tree-tag", tree, "tree")] {
            try tag(repo, name: name, target: oid, annotated: true)
            let detail = try GitClient.tagDetail(at: repo, name: name)
            XCTAssertEqual(detail.targetType, type)
            XCTAssertEqual(detail.targetOID, oid)
            XCTAssertFalse(detail.canCheckout)
            XCTAssertThrowsError(try GitClient.checkoutTag(at: repo, tag: detail))
        }
        XCTAssertEqual(try head(repo), second)
    }

    func testDetachedHistoryIncludesTagCommitOutsideAllBranchTips() throws {
        let (repo, first, second) = try repository()
        try GitClient.checkoutTag(at: repo, tag: GitClient.tagDetail(at: repo, name: "v1"))
        try reference(repo, name: "refs/heads/master", target: first)
        try GitClient.checkoutTag(at: repo, tag: GitClient.tagDetail(at: repo, name: "release/版本-v2"))
        XCTAssertEqual(try head(repo), second)
        XCTAssertTrue(try GitClient.history(at: repo, allBranches: true).contains { $0.id == second })
        XCTAssertThrowsError(try GitClient.push(at: repo, username: "", secret: ""))
        XCTAssertEqual(try GitClient.branches(at: repo).first { $0.name == "master" }?.target, first)
    }

    func testUnfinishedSubmoduleTaskBlocksTagCheckoutAndKeepsItsRecord() throws {
        let (repo, _, second) = try repository()
        let path = repo.appendingPathComponent(".git/gitling-submodules.json")
        try Data("pending".utf8).write(to: path)
        XCTAssertThrowsError(try GitClient.checkoutTag(at: repo, tag: GitClient.tagDetail(at: repo, name: "v1")))
        XCTAssertEqual(try head(repo), second)
        XCTAssertEqual(try Data(contentsOf: path), Data("pending".utf8))
    }

    func testConflictAppearingAfterTagDetailsBlocksCheckoutAndKeepsResolutionState() throws {
        let (repo, _, _) = try repository()
        let selected = try GitClient.tagDetail(at: repo, name: "v1")
        try GitClient.createBranch(at: repo, name: "feature", checkout: true)
        try write("feature\n", repo); try commit(repo)
        try GitClient.checkout(at: repo, branch: "master")
        try write("master\n", repo); try commit(repo)
        try GitClient.mergeBranch(at: repo, branch: "feature", name: "Test", email: "test@example.invalid")
        let before = try bytes(repo, ".git/index"), file = try bytes(repo, "a.txt")
        XCTAssertThrowsError(try GitClient.checkoutTag(at: repo, tag: selected))
        XCTAssertEqual(try bytes(repo, ".git/index"), before)
        XCTAssertEqual(try bytes(repo, "a.txt"), file)
        XCTAssertFalse(try GitClient.operation(at: repo).conflicts.isEmpty)
    }

    func testDirtyNestedSubmoduleIsPreservedWhenCheckingOutTag() throws {
        let (repo, _, _) = try repository()
        let sourceRoot = repo.deletingLastPathComponent().appendingPathComponent("sources")
        try GitClient.initialize(name: "child", root: sourceRoot)
        let source = sourceRoot.appendingPathComponent("child")
        try write("child\n", source); try commit(source)
        try write("[submodule \"child\"]\npath = child\nurl = \(source.path)\n", repo, path: ".gitmodules")
        try GitClient.stage(at: repo, path: ".gitmodules")
        let target = try head(source)
        try withRepo(repo) { raw in
            var index: OpaquePointer?
            XCTAssertEqual(git_repository_index(&index, raw), 0)
            defer { git_index_free(index) }
            "child".withCString { path in
                var entry = git_index_entry(); entry.path = path; entry.mode = 0o160000
                XCTAssertEqual(git_oid_fromstr(&entry.id, target), 0)
                XCTAssertEqual(git_index_add(index, &entry), 0)
            }
            XCTAssertEqual(git_index_write(index), 0)
        }
        try GitClient.commit(at: repo, message: "module", name: "Test", email: "test@example.invalid")
        try GitClient.updateSubmodules(at: repo)
        let child = repo.appendingPathComponent("child")
        try write("keep nested local edit\n", child)
        let before = try bytes(repo, ".git/index")
        XCTAssertThrowsError(try GitClient.checkoutTag(at: repo, tag: GitClient.tagDetail(at: repo, name: "v1")))
        XCTAssertEqual(try String(contentsOf: child.appendingPathComponent("a.txt"), encoding: .utf8), "keep nested local edit\n")
        XCTAssertEqual(try bytes(repo, ".git/index"), before)
    }

    func testExternalWorktreeCheckoutAndUnavailableBookmarkProtection() throws {
        let (repo, first, _) = try repository()
        let external = repo.deletingLastPathComponent().appendingPathComponent("external")
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try GitClient.link(at: repo, bookmark: WorktreeLink.bookmark(for: external))
        let work = external.appendingPathComponent(repo.lastPathComponent)
        try GitClient.checkoutTag(at: repo, tag: GitClient.tagDetail(at: repo, name: "v1"))
        XCTAssertEqual(try head(repo), first)
        XCTAssertEqual(try String(contentsOf: work.appendingPathComponent("a.txt"), encoding: .utf8), "first\n")
        try FileManager.default.removeItem(at: external)
        XCTAssertThrowsError(try GitClient.checkoutTag(at: repo, tag: GitClient.tagDetail(at: repo, name: "release/版本-v2")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: external.path))
    }

    func testFetchedTagCanBeCheckedOutBeforeLocalBranchHasItsFirstCommit() throws {
        let (source, first, _) = try repository()
        let root = source.deletingLastPathComponent()
        try GitClient.initialize(name: "unborn", root: root)
        let repo = root.appendingPathComponent("unborn")
        // Copy only the local object database to model an offline fetch.
        try FileManager.default.removeItem(at: repo.appendingPathComponent(".git/objects"))
        try FileManager.default.copyItem(at: source.appendingPathComponent(".git/objects"), to: repo.appendingPathComponent(".git/objects"))
        try tag(repo, name: "fetched", target: first)
        try GitClient.checkoutTag(at: repo, tag: GitClient.tagDetail(at: repo, name: "fetched"))
        XCTAssertEqual(try GitClient.header(at: repo).detachedOID, first)
        XCTAssertEqual(try String(contentsOf: repo.appendingPathComponent("a.txt"), encoding: .utf8), "first\n")
        XCTAssertTrue(try GitClient.branches(at: repo).isEmpty)
        XCTAssertTrue(try GitClient.status(at: repo).isEmpty)
    }

    func testEmptyAndBrokenTagsAreReportedWithoutHidingOtherTags() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try GitClient.initialize(name: "empty", root: root)
        XCTAssertTrue(try GitClient.tags(at: root.appendingPathComponent("empty")).isEmpty)
        let (repo, _, _) = try repository()
        try (String(repeating: "f", count: 40) + "\n").write(to: repo.appendingPathComponent(".git/refs/tags/broken"), atomically: true, encoding: .utf8)
        let list = try GitClient.tags(at: repo)
        XCTAssertEqual(list.count, 3)
        XCTAssertNotNil(list.first { $0.name == "broken" }?.problem)
        XCTAssertThrowsError(try GitClient.tagDetail(at: repo, name: "broken"))
    }

    func testListingManyTagsDoesNotRequireWorktreeIndexOrLoadHistory() throws {
        let (repo, _, second) = try repository()
        try withRepo(repo) { raw in
            var oid = git_oid(); XCTAssertEqual(git_oid_fromstr(&oid, second), 0)
            for index in 0..<500 {
                var reference: OpaquePointer?
                XCTAssertEqual(git_reference_create(&reference, raw, "refs/tags/bulk/\(index)", &oid, 0, "offline fixture"), 0)
                git_reference_free(reference)
            }
        }
        try FileManager.default.removeItem(at: repo.appendingPathComponent(".git/index"))
        var samples: [Double] = []
        for _ in 0..<5 {
            let start = DispatchTime.now().uptimeNanoseconds
            XCTAssertEqual(try GitClient.tags(at: repo).count, 502)
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        }
        print("TAG_PERF list_502_median_ms=\(samples.sorted()[2]) samples_ms=\(samples)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.appendingPathComponent(".git/index").path))
    }
}
