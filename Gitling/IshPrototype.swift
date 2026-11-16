#if ISH_PROTOTYPE
import Foundation
import SwiftUI

/// Optional isolated fixture evaluation entry point. Production terminal
/// integration lives in TerminalRuntime and RepositoryTerminalView.
@MainActor final class IshPrototypeModel: ObservableObject {
    @Published var transcript = "Starting isolated iSH evaluation…"
    @Published var running = false
    @Published var command = "git status --short"
    @Published var interactiveAvailable = false
    private let lane = DispatchQueue(label: "gitling.ish.prototype")
    private var started = false
    func start() {
        guard !started else { return }; started = true; running = true
        lane.async {
            let evaluation = IshEvaluation()
            do { try evaluation.run() }
            catch { evaluation.record("host.failure", code: -1, output: String(describing: error), milliseconds: 0) }
            evaluation.save()
            DispatchQueue.main.async {
                self.transcript = evaluation.text
                // Functional success alone does not authorize arbitrary scripts
                // in the host app's sandbox. Keep input disabled in this spike.
                self.interactiveAvailable = false
                self.running = false
            }
        }
    }
    func execute() {
        guard !running, interactiveAvailable else { return }; running = true
        let script = command
        lane.async {
            let evaluation = IshEvaluation()
            do {
                let repo = evaluation.shared.appendingPathComponent("small")
                // An arbitrary shell may write at any time. Hold the same host
                // repository lease used by Gitling and its File Provider.
                let hold = try RepoWriteLock.holdExclusive(at: repo)
                defer { withExtendedLifetime(hold) {} }
                let result = evaluation.shell("cd /shared/small && " + script)
                if result.code == -1001 { fatalError("Guest exit unconfirmed; do not release repository lease") }
                DispatchQueue.main.async {
                    self.transcript += "\n$ \(script)\n\(result.output)\nexit=\(result.code)"
                    self.running = false
                }
            } catch {
                DispatchQueue.main.async { self.transcript += "\n\(error)"; self.running = false }
            }
        }
    }
}

struct IshPrototypeView: View {
    @StateObject private var model = IshPrototypeModel()
    var body: some View {
        IshPrototypePanel(transcript: model.transcript, running: model.running,
            command: $model.command, execute: model.execute)
            .task { model.start() }
    }
}

struct IshPrototypePanel: View {
    let transcript: String
    let running: Bool
    @Binding var command: String
    let execute: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("iSH · Offline feasibility prototype").font(.headline)
            Text("Isolated fixture copies only · /shared/small").font(.caption)
            ScrollView([.vertical, .horizontal]) {
                Text(transcript).font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack {
                TextField("Shell command", text: $command)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .onSubmit(execute)
                Button("Run", action: execute)
            }
            .disabled(true)
            Text("Automated fixture evaluation only; the interactive terminal remains disabled in this prototype.")
                .font(.caption).fixedSize(horizontal: false, vertical: true)
            if running { ProgressView() }
        }.padding()
    }
}

private final class IshEvaluation {
    struct Result { var code: Int32; var output: String; var milliseconds: Double; var truncated: Bool }
    let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("IshPrototype", isDirectory: true)
    var shared: URL { directory.appendingPathComponent("shared", isDirectory: true) }
    var rows: [[String: Any]] = []
    var text = ""
    func record(_ name: String, code: Int32, output: String, milliseconds: Double, truncated: Bool = false) {
        rows.append(["name": name, "code": code, "output": output, "milliseconds": milliseconds, "truncated": truncated])
        text += "\(name): exit=\(code), \(Int(milliseconds)) ms\n\(output.prefix(3000))\n\n"
        save()
    }
    func save() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: directory.appendingPathComponent("results.json"), options: .atomic)
        }
        try? text.write(to: directory.appendingPathComponent("transcript.txt"), atomically: true, encoding: .utf8)
    }
    func shell(_ script: String, timeout: UInt32 = 30_000, cancelAfter: TimeInterval? = nil, nativeChecks: Bool = false) -> Result {
        let gate: RepoWriteLock.Hold
        do { gate = try RepositoryAccessGate.holdGuest() }
        catch { return Result(code: -1003, output: "Repository is busy", milliseconds: 0, truncated: false) }
        defer { withExtendedLifetime(gate) {} }
        if nativeChecks {
            let repo = shared.appendingPathComponent("small")
            let checks: [(String, () throws -> Void)] = [
                ("read", { _ = try GitClient.status(at: repo) }),
                ("history", { _ = try GitClient.history(at: repo) }),
                ("write", { try GitClient.stage(at: repo, path: "README.md") }),
                ("provider", { try ProviderWorkspace.withCurrentRoots { _, _ in () } })
            ]
            for (name, operation) in checks {
                do { try operation(); return Result(code: -1010, output: "Native access unexpectedly admitted", milliseconds: 0, truncated: false) }
                catch WorkingTreeError.busy { record("gate.native-\(name).blocked", code: 0, output: "busy", milliseconds: 0) }
                catch { return Result(code: -1010, output: "Unexpected native error: \(error)", milliseconds: 0, truncated: false) }
            }
        }
        let start = DispatchTime.now().uptimeNanoseconds
        var output = [CChar](repeating: 0, count: 65_537); var truncated: Int32 = 0
        let token = UInt64.random(in: 1...UInt64.max)
        if let cancelAfter {
            DispatchQueue.global().asyncAfter(deadline: .now() + cancelAfter) { gp_ish_cancel(token) }
        }
        let code = script.withCString { gp_ish_run($0, timeout, &output, output.count, &truncated, token) }
        if code == -1001 {
            record("lifecycle.unconfirmed", code: code, output: "Process-tree exit unconfirmed. Repository gate remains held until host termination.", milliseconds: 0)
            fatalError("Fail closed: never unwind the guest lease while threads may remain")
        }
        return Result(code: code, output: String(cString: output), milliseconds: Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000, truncated: truncated != 0)
    }
    @discardableResult func check(_ name: String, _ script: String, timeout: UInt32 = 30_000) throws -> Result {
        let r = shell(script, timeout: timeout)
        if r.code == -1001 { fatalError("Guest exit unconfirmed; repository leases remain owned until process termination") }
        record(name, code: r.code, output: r.output, milliseconds: r.milliseconds, truncated: r.truncated)
        guard r.code == 0 else { throw NSError(domain: name, code: Int(r.code)) }
        return r
    }
    private func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    private func lockedWorkflows(_ repo: URL) throws {
        var hold: RepoWriteLock.Hold? = try RepoWriteLock.holdExclusive(at: repo)
        defer { hold = nil }
        do { try RepoWriteLock.withSharedLock(at: repo) {}; throw WorkingTreeError.outside }
        catch WorkingTreeError.busy { record("lock.file-provider.blocked", code: 0, output: "busy", milliseconds: 0) }
        do { _ = try RepoWriteLock.holdExclusive(at: repo); throw WorkingTreeError.outside }
        catch WorkingTreeError.busy { record("lock.second-session.blocked", code: 0, output: "busy", milliseconds: 0) }
        let result = shell("sh /shared/workflows.sh", timeout: 120_000, nativeChecks: true)
        record("git.workflows", code: result.code, output: result.output, milliseconds: result.milliseconds)
        guard result.code == 0 else { throw WorkingTreeError.outside }
        withExtendedLifetime(hold) {}
        hold = nil
        try GitClient.stage(at: repo, path: "README.md")
        record("lock.native-writer.resumed", code: 0, output: "Native stage succeeds after Guest quiescence", milliseconds: 0)
        // A second holder succeeds only after the guest command and queued
        // native write have both finished.
        let next = try RepoWriteLock.holdExclusive(at: repo)
        withExtendedLifetime(next) {}
    }
    private func nativeTime(_ name: String, _ body: () throws -> Void) throws {
        let start = DispatchTime.now().uptimeNanoseconds
        try body()
        record(name, code: 0, output: "native libgit2", milliseconds: Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
    }
    func run() throws {
        let rootfs = directory.appendingPathComponent("fs").path
        let bootStart = DispatchTime.now().uptimeNanoseconds
        let code = rootfs.withCString { gp_ish_boot($0) }
        record("boot", code: code, output: "ARM64 interpreter; same host process", milliseconds: Double(DispatchTime.now().uptimeNanoseconds - bootStart) / 1_000_000)
        guard code == 0 else { throw NSError(domain: "boot", code: Int(code)) }
        try check("shell", "printf 'shell=%s\\n' \"$0\"; uname -m; printf 'a\\nb\\n' | grep b; test $(expr 6 \\* 7) = 42")
        let mounted = shared.resolvingSymlinksInPath().path.withCString { gp_ish_mount_shared($0) }
        record("mount.authorized-host", code: mounted, output: "/shared pinned by host", milliseconds: 0)
        guard mounted == 0 else { throw WorkingTreeError.outside }
        try check("install.offline.git", "apk add --no-network /shared/packages/*.apk; mkdir -p /etc/terminfo/x && cp /shared/packages/xterm-256color /etc/terminfo/x/xterm-256color", timeout: 180_000)
        try check("git.version", "git --version; git config --global user.name 'Gitling Prototype'; git config --global user.email prototype@example.invalid; git config --global --add safe.directory '*' ")
        // Trusted evaluation code only. Package installation uses --no-network;
        // all repository transport tests use local paths. This is not a network
        // sandbox for arbitrary user-supplied scripts.
        try check("directory.same-files", "printf guest > /shared/guest-visible; test \"$(cat /shared/host-visible)\" = host")
        guard try String(contentsOf: shared.appendingPathComponent("guest-visible"), encoding: .utf8) == "guest" else { throw WorkingTreeError.notFound }
        let repo = shared.appendingPathComponent("small")
        try lockedWorkflows(repo)
        try check("git.fsck.small", "git -C /shared/small fsck --full")
        let header = try GitClient.header(at: repo)
        record("native.read.guest-head", code: 0, output: header.branch, milliseconds: 0)
        let guestOID = try check("guest.head.oid", "git -C /shared/small rev-parse HEAD").output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard try GitClient.history(at: repo, limit: 1).first?.id == guestOID else { throw WorkingTreeError.outside }
        record("native.head.matches.guest", code: 0, output: guestOID, milliseconds: 0)
        let status = try GitClient.status(at: repo)
        record("native.read.guest-index", code: status.isEmpty ? 0 : 1, output: "entries=\(status.count)", milliseconds: 0)
        let large = shared.appendingPathComponent("large")
        try nativeTime("native.large.status.cold") { _ = try GitClient.status(at: large) }
        try nativeTime("native.large.log.cold") { _ = try GitClient.history(at: large, limit: 100) }
        var largeLease: RepoWriteLock.Hold? = try RepoWriteLock.holdExclusive(at: large)
        defer { withExtendedLifetime(largeLease) {} }
        for i in 0..<3 {
            try check("large.status.\(i)", "git -C /shared/large status --porcelain=v1")
            try check("large.log.\(i)", "git -C /shared/large log -n 100 --format='%h %s'", timeout: 60_000)
            try check("large.checkout.develop.\(i)", "git -C /shared/large checkout develop", timeout: 120_000)
            try check("large.checkout.master.\(i)", "git -C /shared/large checkout master", timeout: 120_000)
        }
        try check("git.fsck.large", "git -C /shared/large fsck --full", timeout: 120_000)
        largeLease = nil
        for i in 0..<3 {
            try nativeTime("native.large.status.\(i)") { _ = try GitClient.status(at: large) }
            try nativeTime("native.large.log.\(i)") { _ = try GitClient.history(at: large, limit: 100) }
            try nativeTime("native.large.checkout.develop.\(i)") { try GitClient.checkout(at: large, branch: "develop") }
            try nativeTime("native.large.checkout.master.\(i)") { try GitClient.checkout(at: large, branch: "master") }
        }
        let over = shell("yes 0123456789 | head -c 200000")
        record("output.bounded", code: over.truncated && over.output.utf8.count <= 65_536 ? 0 : 1, output: "captured=\(over.output.utf8.count)", milliseconds: over.milliseconds, truncated: over.truncated)
        let timed = shell("sleep 10", timeout: 200)
        record("timeout", code: timed.code == -1000 && gp_ish_active_threads() == 0 ? 0 : 1, output: "raw=\(timed.code), active=\(gp_ish_active_threads())", milliseconds: timed.milliseconds)
        if timed.code == -1001 {
            record("finding.timeout-quiescence", code: 0, output: "Production blocker: no timely confirmed exit. Arbitrary execution remains disabled.", milliseconds: 0)
        }
        // Deliberately non-sensitive sentinel, outside the intended share but
        // still inside this disposable prototype lane. Test real confinement.
        let sentinel = directory.appendingPathComponent("sentinel")
        try FileManager.default.createDirectory(at: sentinel, withIntermediateDirectories: true)
        try "fixture-only".write(to: sentinel.appendingPathComponent("value"), atomically: true, encoding: .utf8)
        try check("mount.denied", "mkdir -p /outside; if mount -t real " + quote(sentinel.path) + " /outside; then exit 1; fi; if umount /shared; then exit 2; fi; test ! -f /outside/value")
        try check("path.symlink-denied", "ln -s " + quote(sentinel.path) + " /shared/escape; if cat /shared/escape/value; then exit 1; fi; if printf changed > /shared/escape/value; then exit 2; fi; rm /shared/escape")
        guard try String(contentsOf: sentinel.appendingPathComponent("value"), encoding: .utf8) == "fixture-only" else { throw WorkingTreeError.outside }
        try check("path.internal-symlink-control", "ln -s small /shared/inside; cat /shared/inside/README.md | grep initial; rm /shared/inside")
        let hard = shared.appendingPathComponent("hard-outside")
        guard link(sentinel.appendingPathComponent("value").path, hard.path) == 0 else { throw WorkingTreeError.outside }
        try check("path.hardlink-denied", "if cat /shared/hard-outside; then exit 1; fi; if printf changed > /shared/hard-outside; then exit 2; fi; true")
        try FileManager.default.removeItem(at: hard)
        guard try String(contentsOf: sentinel.appendingPathComponent("value"), encoding: .utf8) == "fixture-only" else { throw WorkingTreeError.outside }
        try lifecycleChecks()
        let native = try RepositoryAccessGate.holdNative()
        do { _ = try RepositoryAccessGate.holdGuest(); throw WorkingTreeError.outside }
        catch WorkingTreeError.busy { record("gate.native-reader-blocks-guest", code: 0, output: "busy", milliseconds: 0) }
        withExtendedLifetime(native) {}
        record("complete", code: 0, output: "Controlled mounting and serialized process-tree lifecycle evaluated; interactive terminal and external workspaces remain out of scope.", milliseconds: 0)
    }

    private func lifecycleChecks() throws {
        for mode in ["normal-exit", "nonzero-exit", "timeout", "cancel"] {
            let late = shared.appendingPathComponent("late-" + mode)
            let detached = "setsid sh -c 'exec >/dev/null 2>&1; sleep 1; echo unsafe > /shared/late-\(mode)' & "
            let script = detached + (mode == "normal-exit" ? "exit 0" : mode == "nonzero-exit" ? "exit 7" : "sleep 10")
            // A late cancellation for a completed command must not kill the
            // next invocation (the following 1.2-second delay is the control).
            let r = shell(script, timeout: mode == "timeout" ? 200 : 10_000,
                          cancelAfter: mode == "cancel" ? 0.2 : mode == "normal-exit" ? 0.5 : nil)
            let expected: Int32 = mode == "timeout" ? -1000 : mode == "cancel" ? -1004 : mode == "nonzero-exit" ? 7 : 0
            guard r.code == expected, gp_ish_active_threads() == 0 else { throw WorkingTreeError.busy }
            var host: RepoWriteLock.Hold? = try RepositoryAccessGate.holdNative()
            withExtendedLifetime(host) {}
            host = nil
            try check("lifecycle.no-late-write.\(mode)", "sleep 1.2; test ! -e /shared/late-\(mode)")
            guard !FileManager.default.fileExists(atPath: late.path) else { throw WorkingTreeError.outside }
            record("lifecycle.\(mode)", code: 0, output: "All Guest pthreads exited before host lease reacquisition", milliseconds: r.milliseconds)
        }
        let cpu = shell("trap '' TERM; while :; do :; done", timeout: 200)
        guard cpu.code == -1000, gp_ish_active_threads() == 0 else { throw WorkingTreeError.busy }
        record("lifecycle.cpu-loop", code: 0, output: "Uncatchable kill and quiescence confirmed", milliseconds: cpu.milliseconds)
    }
}

private final class NativeWriteProbe: @unchecked Sendable {
    // The semaphore establishes the read/write happens-before relationship.
    var success = false
    var message = "Native stage completed after guest lease release"
}
#endif
