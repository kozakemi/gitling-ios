import XCTest
import Clibgit2
@testable import Gitling

final class SubmoduleTests: XCTestCase {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func repository(_ name: String, root: URL) throws -> URL {
        try GitClient.initialize(name: name, root: root)
        let repo = root.appendingPathComponent(name)
        try write("base\n", at: repo.appendingPathComponent("a.txt"))
        try commit(repo)
        return repo
    }
    private func write(_ text: String, at url: URL) throws { try text.write(to: url, atomically: true, encoding: .utf8) }
    private func commit(_ repo: URL) throws {
        try GitClient.stageAll(at: repo)
        try GitClient.commit(at: repo, message: "offline fixture", name: "Test", email: "test@example.invalid")
    }
    private func head(_ repo: URL) throws -> String { try GitClient.history(at: repo, limit: 1)[0].id }
    private func addModule(_ parent: URL, path: String, source: URL, url: String? = nil, target: String? = nil, moduleName: String? = nil) throws {
        let modules = parent.appendingPathComponent(".gitmodules")
        let existing = (try? String(contentsOf: modules, encoding: .utf8)) ?? ""
        try write(existing + "[submodule \"\(moduleName ?? path)\"]\n\tpath = \(path)\n\turl = \(url ?? source.path)\n", at: modules)
        try GitClient.stage(at: parent, path: ".gitmodules")
        try setTarget(parent, path: path, oid: target ?? head(source))
        try GitClient.commit(at: parent, message: "add module", name: "Test", email: "test@example.invalid")
    }
    private func setTarget(_ parent: URL, path: String, oid: String) throws {
        var repo: OpaquePointer?, index: OpaquePointer?
        XCTAssertEqual(git_repository_open(&repo, parent.path), 0)
        defer { git_repository_free(repo) }
        XCTAssertEqual(git_repository_index(&index, repo), 0)
        defer { git_index_free(index) }
        try path.withCString { ptr in
            var entry = git_index_entry(); entry.path = ptr; entry.mode = 0o160000
            XCTAssertEqual(git_oid_fromstr(&entry.id, oid), 0)
            let result = git_index_add(index, &entry)
            guard result == 0 else { throw GitFailure.message("fixture gitlink failed: \(result)") }
        }
        XCTAssertEqual(git_index_write(index), 0)
    }
    private func fixture() throws -> (URL, URL, URL) {
        let root = try root(), source = try repository("source", root: root), parent = try repository("parent", root: root)
        try addModule(parent, path: "deps/中文-module", source: source)
        return (root, source, parent)
    }
    private func index(_ repo: URL) throws -> Data { try Data(contentsOf: repo.appendingPathComponent(".git/index")) }

    func testStatusAndInitializationAreOfflineAndDoNotCheckoutOrModifyIndex() throws {
        let (_, _, parent) = try fixture()
        let before = try index(parent), original = try head(parent)
        let snapshot = try GitClient.submodules(at: parent)
        XCTAssertEqual(snapshot.items.count, 1)
        XCTAssertFalse(snapshot.items[0].initialized)
        XCTAssertNotNil(snapshot.items[0].target)
        try GitClient.updateSubmodules(at: parent, action: .initialize, recursive: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: parent.appendingPathComponent("deps/中文-module/a.txt").path))
        XCTAssertTrue(GitClient.configText(at: parent).contains("submodule"))
        XCTAssertTrue(try GitClient.submodules(at: parent).items[0].configured)
        XCTAssertEqual(try index(parent), before)
        XCTAssertEqual(try head(parent), original)
        XCTAssertNil(try GitClient.submodules(at: parent).checkpoint)
    }

    func testInitializeAndUpdateChecksOutExactGitlinkAndKeepsParentIndexAndUnrelatedFiles() throws {
        let (_, source, parent) = try fixture()
        let target = try head(source), before = try index(parent)
        try write("new remote commit\n", at: source.appendingPathComponent("a.txt")); try commit(source)
        try write("parent dirty\n", at: parent.appendingPathComponent("a.txt"))
        try write("untracked\n", at: parent.appendingPathComponent("keep.txt"))
        try GitClient.updateSubmodules(at: parent)
        let snapshot = try GitClient.submodules(at: parent)
        XCTAssertEqual(snapshot.items[0].head, target)
        XCTAssertFalse(snapshot.items[0].needsUpdate)
        XCTAssertFalse(snapshot.items[0].dirty)
        XCTAssertEqual(try index(parent), before)
        XCTAssertEqual(try String(contentsOf: parent.appendingPathComponent("a.txt"), encoding: .utf8), "parent dirty\n")
        XCTAssertEqual(try String(contentsOf: parent.appendingPathComponent("keep.txt"), encoding: .utf8), "untracked\n")
    }

    func testUpdateWithoutInitializationSkipsMissingAndDoesNotDownload() throws {
        let (_, source, parent) = try fixture()
        try FileManager.default.removeItem(at: source)
        try GitClient.updateSubmodules(at: parent, initializeMissing: false)
        XCTAssertFalse(try GitClient.submodules(at: parent).items[0].initialized)
        XCTAssertNil(try GitClient.submodules(at: parent).checkpoint)
    }

    func testNestedModulesAreDiscoveredAfterCheckoutAndUpdatedRecursively() throws {
        let root = try root()
        let leaf = try repository("leaf", root: root), middle = try repository("middle", root: root), parent = try repository("parent", root: root)
        try addModule(middle, path: "nested", source: leaf)
        try addModule(parent, path: "top", source: middle)
        try GitClient.updateSubmodules(at: parent, recursive: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: parent.appendingPathComponent("top/nested/a.txt").path))
        try GitClient.updateSubmodules(at: parent, recursive: true)
        let items = try GitClient.submodules(at: parent, recursive: true).items
        XCTAssertEqual(items.map(\.path), ["top", "top/nested"])
        XCTAssertTrue(items.allSatisfy { $0.initialized && !$0.needsUpdate && !$0.dirty })
        XCTAssertEqual(items.last?.head, try head(leaf))
    }

    func testDirtyTrackedStagedAndUntrackedSubmoduleFilesBlockUpdate() throws {
        let (_, source, parent) = try fixture()
        try GitClient.updateSubmodules(at: parent)
        let child = parent.appendingPathComponent("deps/中文-module")
        try write("new target\n", at: source.appendingPathComponent("a.txt")); try commit(source)
        try setTarget(parent, path: "deps/中文-module", oid: head(source))
        for kind in ["unstaged", "staged", "untracked"] {
            let file = child.appendingPathComponent(kind == "untracked" ? "new.txt" : "a.txt")
            try write("keep \(kind)\n", at: file)
            if kind == "staged" { try GitClient.stage(at: child, path: "a.txt") }
            let originalHead = try head(child), before = try index(parent)
            XCTAssertThrowsError(try GitClient.updateSubmodules(at: parent))
            XCTAssertTrue(try GitClient.submodules(at: parent).items[0].dirty)
            XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "keep \(kind)\n")
            XCTAssertEqual(try head(child), originalHead)
            XCTAssertEqual(try index(parent), before)
            if kind == "untracked" { try FileManager.default.removeItem(at: file) }
            else { try GitClient.resetHard(at: child) }
        }
    }

    func testDirtyNestedChildBlocksEvenNonRecursiveParentUpdate() throws {
        let root = try root(), leaf = try repository("leaf", root: root), middle = try repository("middle", root: root), parent = try repository("parent", root: root)
        try addModule(middle, path: "nested", source: leaf); try addModule(parent, path: "top", source: middle)
        try GitClient.updateSubmodules(at: parent, recursive: true)
        let file = parent.appendingPathComponent("top/nested/a.txt")
        try write("keep nested\n", at: file)
        XCTAssertThrowsError(try GitClient.updateSubmodules(at: parent, recursive: false))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "keep nested\n")
        XCTAssertNil(try GitClient.submodules(at: parent).checkpoint)
    }

    func testFailedCloneRetainsCheckpointAndCanRetryAfterOfflineRemoteReturns() throws {
        let (root, source, parent) = try fixture()
        let parked = root.appendingPathComponent("parked")
        try FileManager.default.moveItem(at: source, to: parked)
        let before = try index(parent)
        XCTAssertThrowsError(try GitClient.updateSubmodules(at: parent))
        XCTAssertNotNil(try GitClient.submodules(at: parent).checkpoint)
        XCTAssertThrowsError(try GitClient.checkout(at: parent, branch: "master"))
        try FileManager.default.moveItem(at: parked, to: source)
        try GitClient.updateSubmodules(at: parent, resume: true)
        XCTAssertTrue(try GitClient.submodules(at: parent).items[0].initialized)
        XCTAssertNil(try GitClient.submodules(at: parent).checkpoint)
        XCTAssertEqual(try index(parent), before)
    }

    func testPartialSuccessIsKeptAndRetryUsesSavedRecursiveOptions() throws {
        let root = try root(), first = try repository("first", root: root), second = try repository("second", root: root), parent = try repository("parent", root: root)
        try addModule(parent, path: "a-first", source: first)
        try addModule(parent, path: "z-second", source: second)
        let parked = root.appendingPathComponent("parked")
        try FileManager.default.moveItem(at: second, to: parked)
        XCTAssertThrowsError(try GitClient.updateSubmodules(at: parent, recursive: true))
        let checkpoint = try XCTUnwrap(GitClient.submodules(at: parent).checkpoint)
        XCTAssertEqual(checkpoint.completed, ["a-first"])
        XCTAssertTrue(checkpoint.recursive)
        XCTAssertTrue(FileManager.default.fileExists(atPath: parent.appendingPathComponent("a-first/a.txt").path))
        try FileManager.default.moveItem(at: parked, to: second)
        try GitClient.updateSubmodules(at: parent, recursive: false, resume: true)
        XCTAssertTrue(try GitClient.submodules(at: parent).items.allSatisfy { $0.initialized })
    }

    func testRetryRejectsACompletedChildWhoseHeadWasChangedAfterFailure() throws {
        let root = try root(), first = try repository("first", root: root), second = try repository("second", root: root), parent = try repository("parent", root: root)
        try addModule(parent, path: "a-first", source: first); try addModule(parent, path: "z-second", source: second)
        let parked = root.appendingPathComponent("parked")
        try FileManager.default.moveItem(at: second, to: parked)
        XCTAssertThrowsError(try GitClient.updateSubmodules(at: parent))
        let child = parent.appendingPathComponent("a-first")
        try write("local completed child commit\n", at: child.appendingPathComponent("a.txt")); try commit(child)
        let local = try head(child)
        try FileManager.default.moveItem(at: parked, to: second)
        XCTAssertThrowsError(try GitClient.updateSubmodules(at: parent, resume: true))
        XCTAssertEqual(try head(child), local)
        XCTAssertNotNil(try GitClient.submodules(at: parent).checkpoint)
    }

    func testEndingFailedUpdateDoesNotDeleteCompletedFilesOrDownloadedObjects() throws {
        let root = try root(), first = try repository("first", root: root), parent = try repository("parent", root: root)
        try addModule(parent, path: "a-first", source: first)
        try addModule(parent, path: "z-missing", source: first, url: root.appendingPathComponent("missing").path)
        XCTAssertThrowsError(try GitClient.updateSubmodules(at: parent))
        let file = parent.appendingPathComponent("a-first/a.txt")
        let bytes = try Data(contentsOf: file)
        try GitClient.endSubmoduleUpdate(at: parent)
        XCTAssertNil(try GitClient.submodules(at: parent).checkpoint)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        XCTAssertNotNil(try GitClient.history(at: parent.appendingPathComponent("a-first")).first)
    }

    func testResumeRejectsChangedParentIndexAndConfiguration() throws {
        let (root, source, parent) = try fixture()
        let parked = root.appendingPathComponent("parked")
        try FileManager.default.moveItem(at: source, to: parked)
        XCTAssertThrowsError(try GitClient.updateSubmodules(at: parent))
        try write("new parent\n", at: parent.appendingPathComponent("a.txt")); try GitClient.stage(at: parent, path: "a.txt")
        XCTAssertThrowsError(try GitClient.updateSubmodules(at: parent, resume: true))
        try GitClient.endSubmoduleUpdate(at: parent)
        try FileManager.default.moveItem(at: parked, to: source)
        try GitClient.updateSubmodules(at: parent)
        XCTAssertNil(try GitClient.submodules(at: parent).checkpoint)
    }

    func testExistingNonRepositoryFolderAndSymlinkAreNeverOverwritten() throws {
        let (root, _, parent) = try fixture()
        let path = parent.appendingPathComponent("deps/中文-module")
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        let file = path.appendingPathComponent("keep.txt")
        try write("keep\n", at: file)
        XCTAssertThrowsError(try GitClient.updateSubmodules(at: parent))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "keep\n")
        try FileManager.default.moveItem(at: path, to: root.appendingPathComponent("outside"))
        try FileManager.default.createSymbolicLink(at: path, withDestinationURL: root.appendingPathComponent("outside"))
        XCTAssertThrowsError(try GitClient.updateSubmodules(at: parent))
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("outside/keep.txt"), encoding: .utf8), "keep\n")
    }

    func testRelativeSubmoduleURLUsesParentOrigin() throws {
        let root = try root(), source = try repository("library", root: root), parent = try repository("parent", root: root)
        try GitClient.addRemote(at: parent, url: root.appendingPathComponent("parent.git").path)
        try addModule(parent, path: "module", source: source, url: "../library")
        XCTAssertEqual(try GitClient.submodules(at: parent).items[0].url, source.path)
        try GitClient.updateSubmodules(at: parent)
        XCTAssertEqual(try GitClient.submodules(at: parent).items[0].head, try head(source))
    }

    func testUpdatingExistingChildPreservesPreviousCommitInBackupReference() throws {
        let (_, source, parent) = try fixture()
        try GitClient.updateSubmodules(at: parent)
        let child = parent.appendingPathComponent("deps/中文-module"), old = try head(child)
        try write("new\n", at: source.appendingPathComponent("a.txt")); try commit(source)
        try setTarget(parent, path: "deps/中文-module", oid: head(source))
        try GitClient.updateSubmodules(at: parent)
        XCTAssertEqual(try head(child), try head(source))
        var repo: OpaquePointer?, references: OpaquePointer?
        XCTAssertEqual(git_repository_open(&repo, child.path), 0)
        defer { git_repository_free(repo) }
        XCTAssertEqual(git_reference_iterator_glob_new(&references, repo, "refs/gitling/submodule-backups/*"), 0)
        defer { git_reference_iterator_free(references) }
        var reference: OpaquePointer?
        XCTAssertEqual(git_reference_next(&reference, references), 0)
        defer { git_reference_free(reference) }
        var oid = git_reference_target(reference)!.pointee
        let text = withUnsafePointer(to: &oid) { pointer -> String in
            var buffer = [CChar](repeating: 0, count: 41)
            git_oid_tostr(&buffer, buffer.count, pointer)
            return String(cString: buffer)
        }
        XCTAssertEqual(text, old)
    }

    func testExternalWorkingFolderUsesActualSubmoduleLocation() throws {
        let (root, source, parent) = try fixture()
        let external = root.appendingPathComponent("external")
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try GitClient.link(at: parent, bookmark: WorktreeLink.bookmark(for: external))
        addTeardownBlock { WorktreeLink.remove(repoName: parent.lastPathComponent) }
        try GitClient.updateSubmodules(at: parent, recursive: true)
        let target = external.appendingPathComponent("parent/deps/中文-module")
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.appendingPathComponent("a.txt").path))
        XCTAssertEqual(try head(target), try head(source))
        XCTAssertFalse(FileManager.default.fileExists(atPath: parent.appendingPathComponent("deps/中文-module/a.txt").path))
    }

    func testFailedFetchCanResumeWithoutReplacingTheOriginalBackupReference() throws {
        let (root, source, parent) = try fixture()
        try GitClient.updateSubmodules(at: parent)
        let child = parent.appendingPathComponent("deps/中文-module"), old = try head(child)
        try write("new target\n", at: source.appendingPathComponent("a.txt")); try commit(source)
        try setTarget(parent, path: "deps/中文-module", oid: head(source))
        let parked = root.appendingPathComponent("parked")
        try FileManager.default.moveItem(at: source, to: parked)
        XCTAssertThrowsError(try GitClient.updateSubmodules(at: parent))
        XCTAssertEqual(try head(child), old)
        XCTAssertNotNil(try GitClient.submodules(at: parent).checkpoint)
        try FileManager.default.moveItem(at: parked, to: source)
        try GitClient.updateSubmodules(at: parent, resume: true)
        XCTAssertEqual(try head(child), try head(source))
    }

    func testNestedCloneFailureResumesAfterParentWasCompleted() throws {
        let root = try root(), leaf = try repository("leaf", root: root), middle = try repository("middle", root: root), parent = try repository("parent", root: root)
        try addModule(middle, path: "nested", source: leaf); try addModule(parent, path: "top", source: middle)
        let parked = root.appendingPathComponent("parked")
        try FileManager.default.moveItem(at: leaf, to: parked)
        XCTAssertThrowsError(try GitClient.updateSubmodules(at: parent, recursive: true))
        XCTAssertEqual(try GitClient.submodules(at: parent).checkpoint?.completed, ["top"])
        try FileManager.default.moveItem(at: parked, to: leaf)
        try GitClient.updateSubmodules(at: parent, resume: true)
        XCTAssertEqual(try GitClient.submodules(at: parent, recursive: true).items.count, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: parent.appendingPathComponent("top/nested/a.txt").path))
    }

    func testIgnoredFileCollisionIsKeptAndCheckoutFailsSafely() throws {
        let (_, source, parent) = try fixture()
        try GitClient.updateSubmodules(at: parent)
        let child = parent.appendingPathComponent("deps/中文-module")
        try write("upstream\n", at: source.appendingPathComponent("ignored.txt")); try commit(source)
        try setTarget(parent, path: "deps/中文-module", oid: head(source))
        var repo: OpaquePointer?
        XCTAssertEqual(git_repository_open(&repo, child.path), 0)
        let metadata = URL(fileURLWithPath: String(cString: git_repository_path(repo)))
        git_repository_free(repo)
        try FileManager.default.createDirectory(at: metadata.appendingPathComponent("info"), withIntermediateDirectories: true)
        try write("ignored.txt\n", at: metadata.appendingPathComponent("info/exclude"))
        try write("local ignored data\n", at: child.appendingPathComponent("ignored.txt"))
        let old = try head(child), before = try index(parent)
        XCTAssertThrowsError(try GitClient.updateSubmodules(at: parent))
        XCTAssertEqual(try String(contentsOf: child.appendingPathComponent("ignored.txt"), encoding: .utf8), "local ignored data\n")
        XCTAssertEqual(try head(child), old)
        XCTAssertEqual(try index(parent), before)
    }

    func testCorruptCheckpointCanBeEndedWithoutDeletingFiles() throws {
        let (_, _, parent) = try fixture()
        let file = parent.appendingPathComponent(".git/gitling-submodules.json")
        try Data("invalid checkpoint".utf8).write(to: file)
        XCTAssertThrowsError(try GitClient.submodules(at: parent))
        XCTAssertTrue(try GitClient.header(at: parent).pendingSubmodules)
        XCTAssertThrowsError(try GitClient.checkout(at: parent, branch: "master"))
        try GitClient.endSubmoduleUpdate(at: parent)
        XCTAssertFalse(try GitClient.header(at: parent).pendingSubmodules)
        XCTAssertEqual(try String(contentsOf: parent.appendingPathComponent("a.txt"), encoding: .utf8), "base\n")
    }

    func testIgnoreAllDoesNotHideDirtyFilesFromUpdateProtection() throws {
        let (_, _, parent) = try fixture()
        try GitClient.updateSubmodules(at: parent)
        let child = parent.appendingPathComponent("deps/中文-module")
        let config = parent.appendingPathComponent(".git/config")
        let text = try String(contentsOf: config, encoding: .utf8)
        try write(text + "\n[submodule \"deps/中文-module\"]\nignore = all\n", at: config)
        try write("keep local\n", at: child.appendingPathComponent("a.txt"))
        XCTAssertThrowsError(try GitClient.updateSubmodules(at: parent))
        XCTAssertTrue(try GitClient.submodules(at: parent).items[0].dirty)
    }

    func testStatusIsOfflineAndDoesNotWalkUnrelatedParentFiles() throws {
        let (_, source, parent) = try fixture()
        try Data(repeating: 0x91, count: 8 * 1024 * 1024).write(to: parent.appendingPathComponent("large.bin"))
        let unrelated = parent.appendingPathComponent("unrelated")
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
        for index in 0..<500 { try Data().write(to: unrelated.appendingPathComponent("file-\(index)")) }
        try FileManager.default.removeItem(at: source)
        var samples: [Double] = []
        for _ in 0..<20 {
            let start = DispatchTime.now().uptimeNanoseconds
            let snapshot = try GitClient.submodules(at: parent)
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            XCTAssertEqual(snapshot.items.count, 1)
            XCTAssertFalse(snapshot.items[0].initialized)
        }
        print("SUBMODULE_PERF status_median_ms=\(samples.sorted()[samples.count / 2]) samples_ms=\(samples)")
    }

    func testConfiguredNameCanDifferFromUnicodeNestedWorktreePath() throws {
        let root = try root(), source = try repository("source", root: root), parent = try repository("parent", root: root)
        let path = "依赖/很长的子模块名称-for-iPhone-Duo"
        try addModule(parent, path: path, source: source, moduleName: "a-top")
        try GitClient.updateSubmodules(at: parent, recursive: true)
        let item = try XCTUnwrap(GitClient.submodules(at: parent, recursive: true).items.first)
        XCTAssertEqual(item.path, path)
        XCTAssertNil(item.problem)
        XCTAssertEqual(item.head, try head(source))
        XCTAssertTrue(item.initialized)
        try GitClient.updateSubmodules(at: parent, recursive: true)
    }

    func testModuleConfigurationSymlinkAndPasswordURLAreRejected() throws {
        let (root, _, parent) = try fixture()
        let modules = parent.appendingPathComponent(".gitmodules")
        try FileManager.default.moveItem(at: modules, to: root.appendingPathComponent("modules"))
        try FileManager.default.createSymbolicLink(at: modules, withDestinationURL: root.appendingPathComponent("modules"))
        XCTAssertThrowsError(try GitClient.updateSubmodules(at: parent))
        try FileManager.default.removeItem(at: modules)
        try write("[submodule \"deps/中文-module\"]\npath = deps/中文-module\nurl = https://user:secret@example.invalid/library.git\n", at: modules)
        let protected = try GitClient.submodules(at: parent).items
        XCTAssertNotNil(protected.first?.problem)
        XCTAssertFalse(protected.contains { $0.url.contains("secret") })
    }
}
