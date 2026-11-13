import Clibgit2
import XCTest
@testable import Gitling

final class CommitComparisonTests: XCTestCase {
    private func resolve(_ fixture: CommitComparisonFixture, _ input: String, token: SearchCancellation = .init()) throws -> ComparisonEndpoint {
        try GitClient.resolveComparisonCommit(at: fixture.repo, input: input, cancellation: token)
    }
    private func endpointOID(_ endpoint: ComparisonEndpoint) -> String { endpoint.oid }
    func testCorruptObjectsSurfaceReadErrorsInsteadOfBeingReportedMissing() throws {
        let f = try CommitComparisonFixture(self), old = try f.blob("before\n"), new = try f.blob("after\n")
        let a = try f.commit(["a": (old, 0o100644)]), b = try f.commit(["a": (new, 0o100644)], parents: [a])
        let comparison = try pair(f, a, b), row = try XCTUnwrap(try GitClient.comparisonFiles(at: f.repo, comparison: comparison).files.first)
        func objectPath(_ oid: String) -> URL { f.repo.appendingPathComponent(".git/objects/" + oid.prefix(2) + "/" + oid.dropFirst(2)) }
        try Data("invalid compressed object".utf8).write(to: objectPath(new), options: .atomic)
        XCTAssertThrowsError(try GitClient.comparisonFiles(at: f.repo, comparison: comparison)) { XCTAssertTrue($0 is GitFailure) }
        XCTAssertThrowsError(try GitClient.comparisonFileDiff(at: f.repo, comparison: comparison, file: row)) { XCTAssertTrue($0 is GitFailure) }
        var missingDescription = ""
        do { _ = try resolve(f, String(repeating: "f", count: 40)); XCTFail("Missing OID must fail") }
        catch { missingDescription = error.localizedDescription }
        try Data("invalid compressed commit".utf8).write(to: objectPath(b), options: .atomic)
        do { _ = try resolve(f, b); XCTFail("Corrupt commit must fail") }
        catch { XCTAssertNotEqual(error.localizedDescription, missingDescription, "Existing corrupt data needs a read error, not a missing-object message") }
    }
    func testEmptyFilePatchQuotesControlCharactersInPaths() throws {
        let f = try CommitComparisonFixture(self), path = "目录/a\n+misleading.txt"
        let a = try f.commit([:]), b = try f.commit([path: (try f.blob(""), 0o100644)], parents: [a])
        let comparison = try pair(f, a, b), file = try XCTUnwrap(try GitClient.comparisonFiles(at: f.repo, comparison: comparison).files.first)
        XCTAssertEqual(file.path, path); XCTAssertEqual(file.change, .added)
        guard case .patch(let patch) = try GitClient.comparisonFileDiff(at: f.repo, comparison: comparison, file: file).content else { return XCTFail("Empty added files still have metadata changes") }
        XCTAssertTrue(patch.text.contains("new file mode 100644"))
        XCTAssertTrue(patch.text.contains("a\\n+misleading.txt"))
        XCTAssertFalse(patch.text.components(separatedBy: "\n").contains { $0.hasPrefix("+misleading.txt") })
        XCTAssertEqual(patch.insertions, 0); XCTAssertEqual(patch.deletions, 0)
    }
    func testSelectingSearchResultBeyondLoadedHistoryResolvesTheOriginalCommit() throws {
        let f = try CommitComparisonFixture(self), blob = try f.blob("unchanged\n")
        let oldest = try f.commit(["a": (blob, 0o100644)], message: "Comparison oldest unique marker")
        var tip = oldest
        for number in 0..<305 { tip = try f.commit(["a": (blob, 0o100644)], parents: [tip], message: "later \(number)") }
        try f.reference("refs/heads/master", tip)
        XCTAssertFalse(try GitClient.history(at: f.repo, limit: 300, allBranches: true).contains { $0.id == oldest })
        let before = try f.snapshot()
        let search = try GitClient.historySearch(at: f.repo, query: "Comparison oldest unique marker", field: .message, scope: .all)
        let page = try search.nextPage()
        XCTAssertEqual(page.items.map(\.id), [oldest]); XCTAssertFalse(page.hasMore)
        XCTAssertGreaterThan(page.scanned, 300)
        XCTAssertEqual(endpointOID(try resolve(f, XCTUnwrap(page.items.first).id)), oldest)
        XCTAssertEqual(try f.snapshot(), before)
    }
    private func pair(_ f: CommitComparisonFixture, _ a: String, _ b: String) throws -> CommitComparison {
        try CommitComparison(base: resolve(f, a), target: resolve(f, b))
    }

    func testDirectTreeComparisonCoversChangesAndReversesDirectionWithoutWrites() throws {
        let f = try CommitComparisonFixture(self)
        let old = try f.blob("before\n"), new = try f.blob("after\n"), rename = try f.blob("unique rename contents\n"), mode = try f.blob("executable\n")
        let a = try f.commit(["modified": (old, 0o100644), "deleted": (try f.blob("deleted only\n"), 0o100644), "old-name": (rename, 0o100644), "mode": (mode, 0o100644), "type": (old, 0o100644)])
        let b = try f.commit(["modified": (new, 0o100644), "added": (try f.blob("brand new content\n"), 0o100644), "new-name": (rename, 0o100644), "mode": (mode, 0o100755), "type": (try f.blob("../outside"), 0o120000)], parents: [a])
        try f.reference("refs/heads/master", a)
        try Data("unstaged\n".utf8).write(to: f.repo.appendingPathComponent("local.txt"))
        try GitClient.stageAll(at: f.repo)
        try Data("untracked\n".utf8).write(to: f.repo.appendingPathComponent("untracked.txt"))
        let before = try f.snapshot(), comparison = try pair(f, a, b)
        let forward = try GitClient.comparisonFiles(at: f.repo, comparison: comparison)
        XCTAssertFalse(forward.truncated)
        XCTAssertEqual(forward.files.count, 6)
        XCTAssertEqual(forward.files.first { $0.path == "modified" }?.change, .modified)
        XCTAssertEqual(forward.files.first { $0.path == "added" }?.change, .added)
        XCTAssertEqual(forward.files.first { $0.path == "deleted" }?.change, .deleted)
        XCTAssertEqual(forward.files.first { $0.path == "new-name" }?.change, .renamed)
        XCTAssertEqual(forward.files.first { $0.path == "mode" }?.change, .modeChanged)
        XCTAssertEqual(forward.files.first { $0.path == "type" }?.change, .typeChanged)
        let reverse = try GitClient.comparisonFiles(at: f.repo, comparison: comparison.swapped())
        XCTAssertEqual(reverse.files.first { $0.path == "added" }?.change, .deleted)
        XCTAssertEqual(reverse.files.first { $0.path == "deleted" }?.change, .added)
        XCTAssertEqual(reverse.files.first { $0.change == .renamed }?.newPath, "old-name")
        XCTAssertTrue(Set(forward.files.map(\.id)).isDisjoint(with: Set(reverse.files.map(\.id))))
        XCTAssertTrue(try GitClient.comparisonFiles(at: f.repo, comparison: pair(f, a, a)).files.isEmpty)
        let added = try XCTUnwrap(forward.files.first { $0.path == "added" })
        let deleted = try XCTUnwrap(reverse.files.first { $0.path == "added" })
        guard case .patch(let plus) = try GitClient.comparisonFileDiff(at: f.repo, comparison: comparison, file: added).content,
              case .patch(let minus) = try GitClient.comparisonFileDiff(at: f.repo, comparison: comparison.swapped(), file: deleted).content else { return XCTFail("Expected text patches") }
        XCTAssertEqual(plus.insertions, 1); XCTAssertEqual(plus.deletions, 0)
        XCTAssertEqual(minus.insertions, 0); XCTAssertEqual(minus.deletions, 1)
        XCTAssertTrue(plus.text.contains("+brand new content")); XCTAssertTrue(minus.text.contains("-brand new content"))
        let modeFile = try XCTUnwrap(forward.files.first { $0.path == "mode" })
        let modeDiff = try GitClient.comparisonFileDiff(at: f.repo, comparison: comparison, file: modeFile)
        if case .unchanged = modeDiff.content { XCTFail("Mode changes must not be hidden as unchanged") }
        XCTAssertEqual(try f.snapshot(), before)
    }

    func testNonAncestorAndMergeCompareChosenTreesRatherThanMergeBase() throws {
        let f = try CommitComparisonFixture(self), common = try f.blob("common\n")
        let a = try f.commit(["common": (common, 0o100644)])
        let b = try f.commit(["common": (common, 0o100644), "left": (try f.blob("left"), 0o100644)], parents: [a])
        let c = try f.commit(["common": (common, 0o100644), "right": (try f.blob("right"), 0o100644)], parents: [a])
        let merge = try f.commit(["common": (common, 0o100644), "left": (try f.blob("left"), 0o100644), "right": (try f.blob("right"), 0o100644)], parents: [b, c])
        let branches = try GitClient.comparisonFiles(at: f.repo, comparison: pair(f, b, c))
        XCTAssertEqual(Set(branches.files.map(\.path)), Set(["left", "right"]))
        XCTAssertEqual(branches.files.first { $0.path == "left" }?.change, .deleted)
        XCTAssertEqual(try GitClient.comparisonFiles(at: f.repo, comparison: pair(f, b, merge)).files.map(\.path), ["right"])
        XCTAssertEqual(try GitClient.comparisonFiles(at: f.repo, comparison: pair(f, c, merge)).files.map(\.path), ["left"])
    }

    func testHistoricalSymlinkTargetsAndGitlinksNeverReadOrUpdateWorktreeTargets() throws {
        let f = try CommitComparisonFixture(self)
        let outside = f.root.appendingPathComponent("outside")
        try Data("outside must remain unchanged".utf8).write(to: outside)
        let child1 = try f.commit([:]), child2 = try f.commit(["child": (try f.blob("child"), 0o100644)], parents: [child1])
        let a = try f.commit(["link": (try f.blob("../old-recorded-target"), 0o120000), "module": (child1, 0o160000)])
        let b = try f.commit(["link": (try f.blob("../new-recorded-target"), 0o120000), "module": (child2, 0o160000)], parents: [a])
        try FileManager.default.createSymbolicLink(at: f.repo.appendingPathComponent("link"), withDestinationURL: outside)
        let comparison = try pair(f, a, b), before = try f.snapshot()
        let rows = try GitClient.comparisonFiles(at: f.repo, comparison: comparison).files
        for row in rows {
            let result = try GitClient.comparisonFileDiff(at: f.repo, comparison: comparison, file: row)
            if row.path == "link" { XCTAssertEqual(result.content, .symlink(oldTarget: "../old-recorded-target", newTarget: "../new-recorded-target")) }
            else { XCTAssertEqual(result.content, .gitlink(oldOID: child1, newOID: child2)) }
        }
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(try f.snapshot(), before)
        XCTAssertEqual(try Data(contentsOf: outside), Data("outside must remain unchanged".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.repo.appendingPathComponent("module").path))
    }

    func testBinaryNonUTF8LargeAndOutputBudgetsAreExplicit() throws {
        let f = try CommitComparisonFixture(self), a = try f.commit([:])
        let b = try f.commit(["binary": (try f.blob(Data([0, 1, 2])), 0o100644), "encoding": (try f.blob(Data([0xc3, 0x28, 0x61])), 0o100644), "large": (try f.blob(Data(repeating: 0x61, count: 2 * 1024 * 1024)), 0o100644), "text": (try f.blob((0..<500).map { "\($0) 版本テキスト\n" }.joined()), 0o100644)], parents: [a])
        let comparison = try pair(f, a, b), rows = try GitClient.comparisonFiles(at: f.repo, comparison: comparison).files
        for row in rows {
            let result = try GitClient.comparisonFileDiff(at: f.repo, comparison: comparison, file: row)
            switch row.path {
            case "binary": XCTAssertEqual(result.content, .binary)
            case "encoding": XCTAssertEqual(result.content, .notUTF8)
            case "large": XCTAssertEqual(result.content, .tooLarge(oldBytes: nil, newBytes: 2 * 1024 * 1024))
            default: break
            }
        }
        let text = try XCTUnwrap(rows.first { $0.path == "text" })
        var limits = ComparisonLimits.standard; limits.maximumPatchBytes = 200
        guard case .patch(let patch) = try GitClient.comparisonFileDiff(at: f.repo, comparison: comparison, file: text, limits: limits).content else { return XCTFail("Expected bounded text patch") }
        XCTAssertTrue(patch.truncated); XCTAssertLessThanOrEqual(patch.text.utf8.count, 200)
        XCTAssertFalse(patch.text.contains("\u{fffd}")); XCTAssertTrue(patch.text.isEmpty || patch.text.hasSuffix("\n"))
        limits.maximumFiles = 2
        let bounded = try GitClient.comparisonFiles(at: f.repo, comparison: comparison, limits: limits)
        XCTAssertEqual(bounded.files.count, 2); XCTAssertTrue(bounded.truncated); XCTAssertTrue(bounded.limitsReached.contains(.fileCount))
    }

    func testRenameBudgetCancellationAndForgedRowsCannotSilentlyProduceAResult() throws {
        let f = try CommitComparisonFixture(self), blob = try f.blob("rename content\n")
        let a = try f.commit(["old": (blob, 0o100644)]), b = try f.commit(["new": (blob, 0o100644)], parents: [a])
        let comparison = try pair(f, a, b)
        var limits = ComparisonLimits.standard; limits.maximumRenameCandidates = 1
        let skipped = try GitClient.comparisonFiles(at: f.repo, comparison: comparison, limits: limits)
        XCTAssertTrue(skipped.limitsReached.contains(.renameCandidates))
        let moduleOld = try f.commit(["module-old": (a, 0o160000)])
        let moduleNew = try f.commit(["module-new": (a, 0o160000)], parents: [moduleOld])
        XCTAssertTrue(try GitClient.comparisonFiles(at: f.repo, comparison: pair(f, moduleOld, moduleNew), limits: limits).limitsReached.contains(.renameCandidates))
        let token = SearchCancellation(); token.cancel()
        XCTAssertThrowsError(try GitClient.comparisonFiles(at: f.repo, comparison: comparison, cancellation: token)) { XCTAssertTrue($0 is CancellationError) }
        let file = try XCTUnwrap(try GitClient.comparisonFiles(at: f.repo, comparison: comparison).files.first)
        XCTAssertThrowsError(try GitClient.comparisonFileDiff(at: f.repo, comparison: comparison, file: file, cancellation: token)) { XCTAssertTrue($0 is CancellationError) }
        var forged = file; forged.newOID = String(repeating: "f", count: 40)
        XCTAssertThrowsError(try GitClient.comparisonFileDiff(at: f.repo, comparison: comparison, file: forged))
        limits.maximumFiles = -1
        XCTAssertThrowsError(try GitClient.comparisonFiles(at: f.repo, comparison: comparison, limits: limits))
        let old = try f.commit(["old1": (blob, 0o100644), "old2": (blob, 0o100644)])
        let new = try f.commit(["new1": (blob, 0o100644), "new2": (blob, 0o100644)], parents: [old])
        limits = .standard; limits.maximumRenameBytes = "rename content\n".utf8.count * 3
        XCTAssertTrue(try GitClient.comparisonFiles(at: f.repo, comparison: pair(f, old, new), limits: limits).limitsReached.contains(.renameCandidates), "Count repeated candidate bytes too; unique-OID deduplication underestimates work")
        let contents = (0..<100).map { "stable line \($0)\n" }.joined()
        let similarOld = try f.commit(["before-name": (try f.blob(contents), 0o100644)])
        let similarNew = try f.commit(["after-name": (try f.blob(contents + "one new line\n"), 0o100644)], parents: [similarOld])
        let fixed = try pair(f, similarOld, similarNew)
        try Data("* -diff\n".utf8).write(to: f.repo.appendingPathComponent(".gitattributes"))
        try Data("not an index".utf8).write(to: f.repo.appendingPathComponent(".git/index"))
        let unchanged = try f.snapshot()
        let similarity = try GitClient.comparisonFiles(at: f.repo, comparison: fixed)
        XCTAssertEqual(similarity.files.count, 1)
        XCTAssertEqual(similarity.files.first?.change, .renamed)
        XCTAssertEqual(try f.snapshot(), unchanged)
    }

    func testTreeGenerationAndPatchCallbacksActuallyStopOnCancellation() throws {
        let f = try CommitComparisonFixture(self), blob = try f.blob((0..<100).map { "line \($0)\n" }.joined())
        let a = try f.commit([:]), b = try f.commit(Dictionary(uniqueKeysWithValues: (0..<1000).map { ("file-\($0)", (blob, UInt32(0o100644))) }), parents: [a])
        let comparison = try pair(f, a, b), token = SearchCancellation()
        var generated = 0
        XCTAssertThrowsError(try GitClient.comparisonFiles(at: f.repo, comparison: comparison, cancellation: token, onGeneratedDelta: {
            generated += 1
            if generated == 2 { token.cancel() }
        })) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(generated, 2, "libgit2 must stop generating deltas, not merely drop the completed list")
        let file = try XCTUnwrap(try GitClient.comparisonFiles(at: f.repo, comparison: comparison).files.first)
        let patchToken = SearchCancellation(); var checkpoints = 0
        XCTAssertThrowsError(try GitClient.comparisonFileDiff(at: f.repo, comparison: comparison, file: file, cancellation: patchToken, onCheckpoint: {
            checkpoints += 1
            // Five pre-load checkpoints, file + hunk callbacks, then the first line callback.
            if checkpoints == 8 { patchToken.cancel() }
        })) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(checkpoints, 8, "No further patch callbacks after cancellation")
    }

    func testMissingBlobAndForgedCommitDoNotLoadWrongObjectsOrHideFailures() throws {
        let f = try CommitComparisonFixture(self), oldBlob = try f.blob("before\n"), newBlob = try f.blob("after\n")
        let a = try f.commit(["a": (oldBlob, 0o100644)]), b = try f.commit(["a": (newBlob, 0o100644)], parents: [a])
        let comparison = try pair(f, a, b), file = try XCTUnwrap(try GitClient.comparisonFiles(at: f.repo, comparison: comparison).files.first)
        let forged = ComparisonEndpoint(oid: try f.blob(Data(repeating: 0x61, count: 2 * 1024 * 1024)), input: "forged", source: .oidPrefix, summary: "", author: "", date: .distantPast)
        XCTAssertThrowsError(try GitClient.comparisonFiles(at: f.repo, comparison: CommitComparison(base: forged, target: comparison.target)))
        var limits = ComparisonLimits.standard; limits.maximumMetadataBytes = 1
        XCTAssertThrowsError(try GitClient.comparisonFiles(at: f.repo, comparison: comparison, limits: limits))
        try FileManager.default.removeItem(at: f.repo.appendingPathComponent(".git/objects/" + newBlob.prefix(2) + "/" + newBlob.dropFirst(2)))
        let before = try f.snapshot()
        XCTAssertEqual(try GitClient.comparisonFileDiff(at: f.repo, comparison: comparison, file: file).content, .missingObject)
        XCTAssertEqual(try f.snapshot(), before)
    }

    func testComparisonWithoutIndexOrExternalBookmarkAccessDoesNotRecreateFolders() throws {
        let f = try CommitComparisonFixture(self)
        let a = try f.commit(["a": (try f.blob("before\n"), 0o100644)]), b = try f.commit(["a": (try f.blob("after\n"), 0o100644)], parents: [a])
        try f.reference("refs/heads/master", a)
        let comparison = try pair(f, a, b), external = f.root.appendingPathComponent("external")
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try GitClient.link(at: f.repo, bookmark: WorktreeLink.bookmark(for: external))
        try FileManager.default.removeItem(at: external)
        let index = f.repo.appendingPathComponent(".git/index")
        if FileManager.default.fileExists(atPath: index.path) { try FileManager.default.removeItem(at: index) }
        let before = try f.snapshot(), files = try GitClient.comparisonFiles(at: f.repo, comparison: comparison).files
        XCTAssertEqual(files.count, 1)
        guard case .patch(let patch) = try GitClient.comparisonFileDiff(at: f.repo, comparison: comparison, file: XCTUnwrap(files.first)).content else { return XCTFail("Expected historical diff") }
        XCTAssertTrue(patch.text.contains("+after")); XCTAssertTrue(patch.text.contains("-before"))
        XCTAssertEqual(try f.snapshot(), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: external.path)); XCTAssertFalse(FileManager.default.fileExists(atPath: index.path))
        // Current worktree attributes and even an unreadable index must not decide
        // a comparison of two already-selected object trees.
        try Data("* -diff\n".utf8).write(to: f.repo.appendingPathComponent(".gitattributes"))
        try Data("not a valid index".utf8).write(to: index)
        let withUnusableIndex = try f.snapshot()
        let again = try GitClient.comparisonFiles(at: f.repo, comparison: comparison).files
        guard case .patch(let independent) = try GitClient.comparisonFileDiff(at: f.repo, comparison: comparison, file: XCTUnwrap(again.first)).content else { return XCTFail("Worktree attributes must not replace historical text with a binary marker") }
        XCTAssertTrue(independent.text.contains("+after"))
        XCTAssertEqual(try f.snapshot(), withUnusableIndex)
    }

    func testReferenceChoicesAndShortNameAmbiguityUseRepositoryDatabaseOnly() throws {
        let f = try CommitComparisonFixture(self)
        let a = try f.commit(["a": (try f.blob("a"), 0o100644)])
        for ref in ["refs/heads/master", "refs/heads/shared", "refs/remotes/origin/shared", "refs/tags/shared"] { try f.reference(ref, a) }
        try f.annotated("annotated", a)
        let before = try f.snapshot()
        let refs = try GitClient.comparisonReferences(at: f.repo)
        XCTAssertEqual(Set(refs.map(\.reference)), Set(["HEAD", "refs/heads/master", "refs/heads/shared", "refs/remotes/origin/shared", "refs/tags/shared", "refs/tags/annotated"]))
        XCTAssertEqual(refs.first { $0.isCurrent }?.reference, "refs/heads/master")
        XCTAssertTrue(try XCTUnwrap(refs.first { $0.reference == "refs/tags/annotated" }).annotated)
        XCTAssertThrowsError(try resolve(f, "shared"))
        for ref in ["master", "origin/shared", "annotated"] { XCTAssertEqual(endpointOID(try resolve(f, ref)), a) }
        XCTAssertEqual(try f.snapshot(), before)
    }

    func testTagMetadataDepthAndMissingCommitAreRejectedBeforeUnboundedReads() throws {
        let f = try CommitComparisonFixture(self)
        let a = try f.commit(["a": (try f.blob("a"), 0o100644)])
        try f.reference("refs/heads/master", a)
        var target = a
        for depth in 0..<33 {
            let name = "depth-\(depth)"
            try f.annotated(name, target)
            var id = git_oid()
            try CommitComparisonFixture.check(git_reference_name_to_id(&id, f.raw, "refs/tags/" + name))
            target = f.text(id)
        }
        XCTAssertThrowsError(try resolve(f, "refs/tags/depth-32"))
        var object: OpaquePointer?, id = try f.oid(a), signature: UnsafeMutablePointer<git_signature>?, tag = git_oid()
        try CommitComparisonFixture.check(git_object_lookup(&object, f.raw, &id, GIT_OBJECT_COMMIT))
        defer { git_object_free(object) }
        try CommitComparisonFixture.check(git_signature_now(&signature, "Fixture", "fixture@example.invalid"))
        defer { git_signature_free(signature) }
        try CommitComparisonFixture.check(git_tag_create(&tag, f.raw, "oversized", object, signature, String(repeating: "x", count: 1_048_577), 0))
        XCTAssertThrowsError(try resolve(f, "refs/tags/oversized"))
        let path = ".git/objects/" + a.prefix(2) + "/" + a.dropFirst(2)
        try FileManager.default.removeItem(at: f.repo.appendingPathComponent(String(path)))
        let before = try f.snapshot()
        XCTAssertThrowsError(try resolve(f, a))
        XCTAssertEqual(try f.snapshot(), before)
    }

    func testEndpointResolutionPinsHEADBranchesRemoteTagsAndUniquePrefix() throws {
        let f = try CommitComparisonFixture(self)
        let blob = try f.blob("first\n"), a = try f.commit(["a.txt": (blob, 0o100644)])
        let b = try f.commit(["a.txt": (try f.blob("second\n"), 0o100644)], parents: [a])
        try f.reference("refs/heads/master", a)
        try f.reference("refs/remotes/origin/branch", a)
        try f.reference("refs/tags/light", a)
        try f.annotated("annotated", a)
        var tagOID = git_oid()
        try CommitComparisonFixture.check(git_reference_name_to_id(&tagOID, f.raw, "refs/tags/annotated"))
        try f.annotated("nested", f.text(tagOID))
        for input in ["HEAD", "refs/heads/master", "refs/remotes/origin/branch", "refs/tags/light", "refs/tags/annotated", "refs/tags/nested", String(a.prefix(7)), a.uppercased()] {
            XCTAssertEqual(endpointOID(try resolve(f, input)), a, input)
        }
        let selected = try resolve(f, "refs/heads/master")
        try f.reference("refs/heads/master", b)
        XCTAssertEqual(endpointOID(selected), a)
        XCTAssertEqual(endpointOID(try resolve(f, "HEAD")), b)
        var detached = try f.oid(a)
        try CommitComparisonFixture.check(git_repository_set_head_detached(f.raw, &detached))
        XCTAssertEqual(endpointOID(try resolve(f, "HEAD")), a)
    }

    func testResolverRejectsNonCommitMissingInvalidAndAmbiguousObjectsWithoutWriting() throws {
        let f = try CommitComparisonFixture(self)
        let blob = try f.blob(Data(repeating: 0x81, count: 2 * 1024 * 1024))
        let a = try f.commit(["large.bin": (blob, 0o100644)])
        try f.reference("refs/heads/master", a)
        try f.annotated("blob", blob)
        var commit: OpaquePointer?, id = try f.oid(a)
        try CommitComparisonFixture.check(git_commit_lookup(&commit, f.raw, &id))
        let tree = f.text(git_commit_tree_id(commit).pointee)
        git_commit_free(commit)
        try f.reference("refs/tags/tree", tree)
        // Precomputed SHA-1 blob collision at seven hex digits; only two object writes.
        let one = try f.blob("comparison-prefix-fixture-4594")
        let two = try f.blob("comparison-prefix-fixture-21743")
        XCTAssertEqual(one.prefix(7), two.prefix(7)); XCTAssertNotEqual(one, two)
        let before = try f.snapshot()
        for input in ["", "abcdef", "zzzzzzz", "HEAD~1", "refs/tags/blob", "refs/tags/tree", blob, tree, String(repeating: "f", count: 40), String(one.prefix(7)), "HEAD\0suffix"] {
            XCTAssertThrowsError(try resolve(f, input), input)
        }
        XCTAssertEqual(try f.snapshot(), before)
    }

    func testEndpointReadsDoNotRequireIndexOrExternalWorktreeAndHonorCancellation() throws {
        let f = try CommitComparisonFixture(self)
        let a = try f.commit(["a.txt": (try f.blob("version\n"), 0o100644)])
        try f.reference("refs/heads/master", a)
        let external = f.root.appendingPathComponent("external")
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try GitClient.link(at: f.repo, bookmark: WorktreeLink.bookmark(for: external))
        try FileManager.default.removeItem(at: external)
        let index = f.repo.appendingPathComponent(".git/index")
        if FileManager.default.fileExists(atPath: index.path) { try FileManager.default.removeItem(at: index) }
        let before = try f.snapshot()
        XCTAssertEqual(endpointOID(try resolve(f, "HEAD")), a)
        let token = SearchCancellation(); token.cancel()
        XCTAssertThrowsError(try resolve(f, a, token: token)) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(try f.snapshot(), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: external.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: index.path))
    }
}
