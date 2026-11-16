import Foundation
import Darwin
import Clibgit2
import GitlingIsh
import XCTest
@testable import Gitling

/// Uses the exact production runtime and bundled APKs, with temporary offline
/// repositories. No remote fetch, prototype build flag or injected kernel.
final class TerminalRuntimeTests: XCTestCase {
    private final class Probe {
        let token = UInt64.random(in: 1...UInt64.max)
        let changed = NSCondition()
        private var bytes = Data()
        private var result: Result<Int32, Error>?
        private var suspended = false
        var text: String { changed.lock(); defer { changed.unlock() }; return String(decoding: bytes, as: UTF8.self) }
        func append(_ data: Data) { changed.lock(); bytes.append(data); changed.broadcast(); changed.unlock() }
        func start(_ repo: URL, linked: Bool = false) {
            TerminalRuntime.worker.async {
                let outcome = Result { try TerminalRuntime.shell(repo: repo, token: self.token, rows: 24, cols: 80,
                    resolveLinkedFolder: linked, suspension: { paused in
                        self.changed.lock(); self.suspended = paused; self.changed.broadcast(); self.changed.unlock()
                    }, output: self.append) }
                self.changed.lock(); self.result = outcome; self.changed.broadcast(); self.changed.unlock()
            }
        }
        func wait(_ text: String, timeout: TimeInterval = 30) throws {
            let deadline = Date().addingTimeInterval(timeout)
            changed.lock(); defer { changed.unlock() }
            while !String(decoding: bytes, as: UTF8.self).contains(text) {
                if let result { throw TerminalRuntime.Failure(message: "Shell ended: \(result)\n\(String(decoding: bytes, as: UTF8.self))") }
                guard changed.wait(until: deadline) else {
                    throw TerminalRuntime.Failure(message: "Missing \(text): \(String(decoding: bytes, as: UTF8.self).suffix(3000))")
                }
            }
        }
        func pause(_ value: Bool) throws {
            gp_ish_set_suspended(token, value ? 1 : 0)
            let deadline = Date().addingTimeInterval(10)
            changed.lock(); defer { changed.unlock() }
            while suspended != value {
                guard result == nil, changed.wait(until: deadline) else {
                    throw TerminalRuntime.Failure(message: "Guest park transition did not complete")
                }
            }
        }
        func send(_ text: String) throws {
            let bytes = Array(text.utf8)
            let rc = bytes.withUnsafeBufferPointer { gp_ish_write(token, $0.baseAddress, $0.count) }
            XCTAssertEqual(rc, 0)
            if rc != 0 { throw TerminalRuntime.Failure(message: "PTY input failed: \(rc)") }
        }
        @discardableResult func finish() throws -> Int32 {
            gp_ish_cancel(token)
            let deadline = Date().addingTimeInterval(12)
            changed.lock(); defer { changed.unlock() }
            while result == nil {
                guard changed.wait(until: deadline) else { throw TerminalRuntime.Failure(message: "Shell tree did not finish") }
            }
            return try result!.get()
        }
    }

    func testSharedMountRejectsSymlinkedHostPath() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        let alias = root.appendingPathComponent("alias")
        let intermediate = root.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: repo)
        try FileManager.default.createSymbolicLink(at: intermediate, withDestinationURL: root)
        XCTAssertLessThan(alias.path.withCString { gp_ish_mount_shared($0) }, 0)
        let nested = intermediate.appendingPathComponent("repo").path
        XCTAssertLessThan(nested.withCString { gp_ish_mount_shared($0) }, 0)
        XCTAssertEqual(gp_ish_active_threads(), 0)
    }

    func testProductionPersistentPTYGitInterruptAndTreeCleanup() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try GitClient.initialize(name: "local", root: root)
        let repo = root.appendingPathComponent("local")
        try Data("base\n".utf8).write(to: repo.appendingPathComponent("note.txt"))
        try GitClient.stageAll(at: repo)
        try GitClient.commit(at: repo, message: "offline base", name: "Test", email: "test@example.invalid")
        let probe = Probe()
        probe.start(repo)
        defer { _ = try? probe.finish() }
        try probe.wait("/shared", timeout: 240)
        try probe.send("stty -echo; printf '__%s__\\n' READY\n")
        try probe.wait("__READY__")
        XCTAssertThrowsError(try GitClient.status(at: repo))
        XCTAssertThrowsError(try RepositoryAccessGate.holdNative())
        XCTAssertNotEqual(gp_ish_interrupt(probe.token ^ 1), 0)
        try probe.send("export SESSION_VALUE=PERSISTED; mkdir -p nested; cd nested; printf '__%s__\\n' FIRST\n")
        try probe.wait("__FIRST__")
        try probe.send("printf '__%s__\\n' \"$SESSION_VALUE\"; pwd; test -t 0 && test -t 1 && printf '__%s__\\n' TTY\n")
        try probe.wait("__PERSISTED__")
        try probe.wait("/shared/nested")
        try probe.wait("__TTY__")
        XCTAssertEqual(gp_ish_resize(probe.token, 31, 101), 0)
        try probe.send("stty size; printf '__%s__\\n' RESIZED\n")
        try probe.wait("__RESIZED__")
        XCTAssertTrue(probe.text.contains("31 101"), probe.text)
        try probe.send("printf '__%s__\\n' EARLY; sleep 6; printf '__%s__\\n' LATE\n")
        try probe.wait("__EARLY__")
        XCTAssertFalse(probe.text.contains("__LATE__"), "Output must arrive before command exit")
        XCTAssertEqual(gp_ish_interrupt(probe.token), 0)
        try probe.send("printf '__%s__\\n' STILL_ALIVE\n")
        try probe.wait("__STILL_ALIVE__")
        XCTAssertFalse(probe.text.contains("__LATE__"))
        try probe.send("printf '__%s__\\n' KEY_EARLY; sleep 6; printf '__%s__\\n' KEY_LATE\n")
        try probe.wait("__KEY_EARLY__")
        try probe.send("\u{03}")
        try probe.send("printf '__%s__\\n' KEY_ALIVE\n")
        try probe.wait("__KEY_ALIVE__")
        XCTAssertFalse(probe.text.contains("__KEY_LATE__"))
        try probe.send("cd /shared; git -c user.name=Test -c user.email=test@example.invalid commit --allow-empty -m shell-commit && git tag shell-tag && git log -1 --format=%s && git fsck --no-progress && printf '__%s__\\n' GIT_OK\n")
        try probe.wait("__GIT_OK__")
        XCTAssertTrue(probe.text.contains("shell-commit"))
        try probe.send("test -s /etc/terminfo/x/xterm-256color && vim --version && nano --version && printf '__%s__\\n' EDITORS_OK\n")
        try probe.wait("__EDITORS_OK__")
        XCTAssertTrue(probe.text.contains("VIM - Vi IMproved"), probe.text)
        XCTAssertTrue(probe.text.contains("GNU nano"), probe.text)
        try probe.send("(setsid sh -c 'sleep 3; touch /shared/leaked' </dev/null >/dev/null 2>&1 &); printf '__%s__\\n' BACKGROUND\n")
        try probe.wait("__BACKGROUND__")
        _ = try probe.finish()
        XCTAssertEqual(gp_ish_active_threads(), 0)
        XCTAssertNoThrow(try RepositoryAccessGate.holdNative())
        XCTAssertTrue(try GitClient.status(at: repo).isEmpty)
        XCTAssertEqual(try GitClient.history(at: repo).count, 2)
        // A new session remounts a different repo. Old token cancellation and
        // input must not affect this shell or retain access to the old share.
        try GitClient.initialize(name: "second", root: root)
        let second = Probe(); second.start(root.appendingPathComponent("second"))
        defer { _ = try? second.finish() }
        try second.wait("/shared")
        gp_ish_cancel(probe.token)
        XCTAssertNotEqual(gp_ish_resize(probe.token, 10, 10), 0)
        try second.send("stty -echo; test ! -e note.txt && sleep 4; printf '__%s__\\n' SECOND\n")
        try second.wait("__SECOND__")
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.appendingPathComponent("leaked").path))
        _ = try second.finish()
    }

    func testPausedSessionKeepsEnvironmentAndJobsWhileNativeReadsAndWritesAreProtected() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try GitClient.initialize(name: "park", root: root)
        let repo = root.appendingPathComponent("park")
        let probe = Probe(); probe.start(repo)
        defer { _ = try? probe.finish() }
        try probe.wait("/shared", timeout: 150)
        try probe.send("stty -echo; export KEEP_VALUE=preserved; (setsid sh -c 'while :; do echo tick >>/shared/ticks; sleep 0.02; done' </dev/null >/dev/null 2>&1 &) ; printf '__%s__\\n' PARK_READY\n")
        try probe.wait("__PARK_READY__")
        for _ in 0..<8 {
            try probe.pause(true)
            XCTAssertGreaterThan(gp_ish_active_threads(), 0, "The shell and its detached jobs remain alive")
            XCTAssertNoThrow(try GitClient.status(at: repo))
            let before = try? Data(contentsOf: repo.appendingPathComponent("ticks"))
            Thread.sleep(forTimeInterval: 0.08)
            XCTAssertEqual(try? Data(contentsOf: repo.appendingPathComponent("ticks")), before, "No guest write may escape a parked tree")
            try probe.pause(false)
            XCTAssertThrowsError(try GitClient.status(at: repo))
        }
        try probe.pause(true)
        XCTAssertThrowsError(try GitClient.unlink(at: repo), "A parked shell must not be silently rebound to another workspace")
        XCTAssertThrowsError(try RepoStorage.removeRepository(named: "park"))
        try Data("native".utf8).write(to: repo.appendingPathComponent("note.txt"))
        try GitClient.stage(at: repo, path: "note.txt")
        try GitClient.commit(at: repo, message: "native-during-park", name: "Test", email: "test@example.invalid")
        var native: RepoWriteLock.Hold? = try RepositoryAccessGate.holdNative()
        gp_ish_set_suspended(probe.token, 0)
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertNoThrow(try GitClient.status(at: repo), "Resume must wait for existing native readers")
        withExtendedLifetime(native) {}; native = nil
        try probe.pause(false)
        try probe.send("printf '__%s__\\n' \"$KEEP_VALUE\"; git --no-pager log -1 --format=%s; printf '__%s__\\n' PARK_DONE\n")
        try probe.wait("__PARK_DONE__")
        XCTAssertTrue(probe.text.contains("__preserved__"))
        XCTAssertTrue(probe.text.contains("native-during-park"))
        try probe.pause(true)
        try Data("target-A\n".utf8).write(to: repo.appendingPathComponent("a"))
        try Data("target-B\n".utf8).write(to: repo.appendingPathComponent("b"))
        try FileManager.default.createSymbolicLink(atPath: repo.appendingPathComponent("pick").path, withDestinationPath: "a")
        try probe.pause(false)
        try probe.send("cat pick; printf '__%s__\\n' LINK_A\n")
        try probe.wait("__LINK_A__")
        XCTAssertTrue(probe.text.contains("target-A"))
        try probe.pause(true)
        try FileManager.default.removeItem(at: repo.appendingPathComponent("pick"))
        try FileManager.default.createSymbolicLink(atPath: repo.appendingPathComponent("pick").path, withDestinationPath: "b")
        try probe.pause(false)
        try probe.send("cat pick; printf '__%s__\\n' LINK_B\n")
        try probe.wait("__LINK_B__")
        XCTAssertTrue(probe.text.contains("target-B"), "Native symlink edits must invalidate guest normalization caches on resume")
        try probe.pause(true)
        _ = try probe.finish()
        XCTAssertEqual(gp_ish_active_threads(), 0)
        XCTAssertNoThrow(try RepositoryAccessGate.holdNative())
    }

    func testTimeoutDrainsDetachedTreeBeforeReleasingGuestLease() throws {
        let completed = expectation(description: "Timed out tree reaped")
        TerminalRuntime.worker.async {
            do {
                let gate = try RepositoryAccessGate.holdGuest()
                try TerminalRuntime.prepare()
                let result = TerminalRuntime.run("setsid sh -c 'trap \"\" TERM; sleep 30' </dev/null >/dev/null 2>&1 & sleep 30", timeout: 150)
                XCTAssertEqual(result.code, -1000, result.output)
                XCTAssertEqual(gp_ish_active_threads(), 0)
                XCTAssertThrowsError(try RepositoryAccessGate.holdNative())
                withExtendedLifetime(gate) {}
            } catch { XCTFail(String(describing: error)) }
            completed.fulfill()
        }
        wait(for: [completed], timeout: 160)
        XCTAssertNoThrow(try RepositoryAccessGate.holdNative())
    }

    func testOfflineLargeRepositoryStatusHistoryCheckoutAndStreamingPerformance() throws {
        let fixture = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OfflineBenchmarks/fixture.git")
        guard FileManager.default.fileExists(atPath: fixture.appendingPathComponent("HEAD").path) else {
            throw XCTSkip("Install the existing offline fixture with scripts/install-offline-benchmark-fixture.py")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try GitClient.clone(url: fixture.absoluteString, name: "large", root: root, username: "", secret: "")
        // Quantify the fresh native index's timestamp ambiguity before Git
        // refreshes it. These are candidates for Git's mandatory racy checks.
        var nativeIndex: OpaquePointer?
        let indexPath = root.appendingPathComponent("large/.git/index").path
        XCTAssertEqual(git_index_open(&nativeIndex, indexPath), 0)
        var indexStat = stat(); XCTAssertEqual(indexPath.withCString { lstat($0, &indexStat) }, 0)
        if let nativeIndex {
            var secondsCandidates = 0, nanosecondsCandidates = 0
            for offset in 0..<git_index_entrycount(nativeIndex) {
                guard let entry = git_index_get_byindex(nativeIndex, offset), entry.pointee.mode != 0o160000 else { continue }
                let time = entry.pointee.mtime
                if Int(time.seconds) >= indexStat.st_mtimespec.tv_sec { secondsCandidates += 1 }
                if Int(time.seconds) > indexStat.st_mtimespec.tv_sec ||
                    (Int(time.seconds) == indexStat.st_mtimespec.tv_sec && Int(time.nanoseconds) >= indexStat.st_mtimespec.tv_nsec) { nanosecondsCandidates += 1 }
            }
            print("NATIVE_INDEX_RACY seconds=\(secondsCandidates) nanoseconds=\(nanosecondsCandidates)")
            git_index_free(nativeIndex)
        }
        let probe = Probe(); probe.start(root.appendingPathComponent("large"))
        defer { _ = try? probe.finish() }
        try probe.wait("/shared", timeout: 240)
        try probe.send("stty -echo; printf '__%s__\\n' PERF_READY\n")
        try probe.wait("__PERF_READY__")
        for (name, command) in [("status", "GIT_TRACE2_PERF=/shared/.git/status.trace git status --porcelain"),
                                ("statusWarm", "git status --porcelain"),
                                ("statusNoPreload", "git -c core.preloadIndex=false status --porcelain"),
                                ("history100", "git --no-pager log -100 --oneline"),
                                ("checkout471paths", "git checkout -b terminal-perf origin/why_md")] {
            let start = DispatchTime.now().uptimeNanoseconds
            try probe.send(command + " && printf '__%s__\\n' " + name + "\n")
            try probe.wait("__" + name + "__", timeout: 60)
            let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            print("TERMINAL_PERF " + name + " milliseconds=\(ms)")
        }
        try probe.pause(true)
        let repo = root.appendingPathComponent("large")
        XCTAssertTrue(try GitClient.status(at: repo).isEmpty)
        let tracked = repo.appendingPathComponent(".clang-format")
        let date = try tracked.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        var bytes = try Data(contentsOf: tracked)
        XCTAssertFalse(bytes.isEmpty)
        bytes[0] ^= 1
        try bytes.write(to: tracked)
        if let date { try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: tracked.path) }
        try Data("new".utf8).write(to: repo.appendingPathComponent("terminal-regression-marker.gitling"))
        try probe.pause(false)
        try probe.send("git status --porcelain --untracked-files=all -- .clang-format terminal-regression-marker.gitling; printf '__%s__\\n' DIRTY_SCANNED\n")
        try probe.wait("__DIRTY_SCANNED__")
        XCTAssertTrue(probe.text.contains(" M .clang-format"), "No metadata cache may hide a same-size file edit")
        XCTAssertTrue(probe.text.contains("?? terminal-regression-marker.gitling"))
        try probe.pause(true)
        try GitClient.stage(at: repo, path: ".clang-format")
        try probe.pause(false)
        try probe.send("git status --porcelain -- .clang-format; printf '__%s__\\n' STAGED_SCANNED\n")
        try probe.wait("__STAGED_SCANNED__")
        XCTAssertTrue(probe.text.contains("M  .clang-format"), "Guest must observe native index writes after resume")
        _ = try probe.finish()
        XCTAssertEqual(gp_ish_active_threads(), 0)
        let trace = try String(contentsOf: root.appendingPathComponent("large/.git/status.trace"), encoding: .utf8)
        print("TERMINAL_TRACE2\n" + trace)

    }

    func testLinkedFolderUsesSeparateGitMetadataAndDoesNotExposeSiblings() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let name = "linked-" + UUID().uuidString
        try GitClient.initialize(name: name, root: root)
        let repo = root.appendingPathComponent(name)
        try Data("base\n".utf8).write(to: repo.appendingPathComponent("note.txt"))
        try GitClient.stageAll(at: repo)
        try GitClient.commit(at: repo, message: "base", name: "Test", email: "test@example.invalid")
        let external = root.appendingPathComponent("external")
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try Data("private".utf8).write(to: external.appendingPathComponent("sibling.txt"))
        let bookmark = try WorktreeLink.bookmark(for: external)
        try GitClient.link(at: repo, bookmark: bookmark)
        defer { WorktreeLink.remove(repoName: name) }
        let probe = Probe(); probe.start(repo, linked: true)
        defer { _ = try? probe.finish() }
        try probe.wait("/shared", timeout: 240)
        try probe.send("stty -echo; test ! -e /shared/../sibling.txt && git log -1 --format=%s && printf changed >>note.txt && git diff --stat && printf '__%s__\\n' LINKED_OK\n")
        try probe.wait("__LINKED_OK__")
        XCTAssertTrue(probe.text.contains("note.txt"))
        _ = try probe.finish()
        XCTAssertTrue(try GitClient.status(at: repo).contains { $0.path == "note.txt" && $0.unstaged })
        XCTAssertEqual(try String(contentsOf: external.appendingPathComponent("sibling.txt"), encoding: .utf8), "private")
    }
}
