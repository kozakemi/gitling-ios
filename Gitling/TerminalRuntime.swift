import CryptoKit
import Foundation
import GitlingIsh

/// The iSH kernel is process-global. Only this worker may boot, install, mount
/// or run it. Controls use token-checked C calls on a separate input queue.
enum TerminalRuntime {
    static let worker = DispatchQueue(label: "gitling.terminal.runtime", qos: .userInitiated)
    static let input = DispatchQueue(label: "gitling.terminal.input", qos: .userInitiated)
    private static let admission = NSLock()
    private static var claimed: UInt64?
    private static var resetRequested = false
    static func beginEnvironmentReset() {
        admission.lock(); resetRequested = true; let token = claimed; admission.unlock()
        if let token { gp_ish_cancel(token) }
    }
    static func cancelEnvironmentReset() { admission.lock(); resetRequested = false; admission.unlock() }
    private static func checkReset() throws {
        admission.lock(); let reset = resetRequested; admission.unlock()
        if reset { throw Failure(message: String(localized: "Close Gitling and reopen it to finish resetting the terminal."), restartRequired: true) }
    }
    static func claim(_ token: UInt64) -> Bool {
        admission.lock(); defer { admission.unlock() }
        guard claimed == nil else { return false }
        claimed = token; return true
    }
    static func release(_ token: UInt64) {
        admission.lock(); defer { admission.unlock() }
        if claimed == token { claimed = nil }
    }
    private static var booted = false
    private static var kernelStarted = false
    private static var bootFailure: Error?
    private static var retainedAfterUnconfirmedExit: [Any] = []

    struct Failure: LocalizedError {
        let message: String
        var retainLease = false
        var restartRequired = false
        var errorDescription: String? { message }
    }

    static func prepare(token: UInt64? = nil) throws {
        try checkReset()
        if let bootFailure { throw bootFailure }
        guard !booted else { return }
        do {
            guard let assets = Bundle.main.resourceURL?.appendingPathComponent("TerminalRuntime"),
                  let data = try? Data(contentsOf: assets.appendingPathComponent("manifest.json")),
                  let manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let version = manifest["version"] as? String,
                  version.count == 64, version.allSatisfy({ $0.isHexDigit }),
                  let packages = manifest["packages"] as? [[String: String]] else {
                throw Failure(message: String(localized: "Offline terminal resources are missing. Rebuild the app."))
            }
            let root = try TerminalEnvironmentStore.live.rootForLaunch(version: version)
            let parent = root.deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: root.path) {
                let staging = parent.appendingPathComponent(UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: staging) }
                try FileManager.default.copyItem(at: assets.appendingPathComponent("fs"), to: staging)
                try FileManager.default.moveItem(at: staging, to: root)
            }
            if !kernelStarted {
                let boot = root.path.withCString { gp_ish_boot($0) }
                guard boot == 0 else { throw Failure(message: String(localized: "Could not start the offline shell.") + " (\(boot))") }
                kernelStarted = true
            }
            // Never mount repository data during bootstrap. APKs are copied by
            // trusted host code into private fakefs and verified by apk offline.
            for package in packages {
                guard let name = package["name"], let hash = package["sha256"],
                      !name.contains("/"), !name.contains("..") else { throw CocoaError(.fileReadCorruptFile) }
                let source = assets.appendingPathComponent("packages").appendingPathComponent(name)
                let checksum = SHA256.hash(data: try Data(contentsOf: source)).map { String(format: "%02x", $0) }.joined()
                guard checksum == hash else { throw CocoaError(.fileReadCorruptFile) }
                let status = source.path.withCString { host in name.withCString { gp_ish_install_package(host, $0) } }
                guard status == 0 else { throw Failure(message: String(localized: "Could not prepare offline Git.") + " (\(status))") }
            }
            let terminfo = assets.appendingPathComponent("xterm-256color")
            let terminfoChecksum = SHA256.hash(data: try Data(contentsOf: terminfo)).map { String(format: "%02x", $0) }.joined()
            guard terminfoChecksum == "375da81b08a91cbbe97b1316f567346e7f31b3ec1cd4fb5be048908e920d4a3e" else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let terminfoStatus = terminfo.path.withCString { host in "xterm-256color".withCString { gp_ish_install_package(host, $0) } }
            guard terminfoStatus == 0 else { throw Failure(message: String(localized: "Could not prepare offline Git.") + " (\(terminfoStatus))") }
            // ncurses-terminfo-base contains one hardlink the guest filesystem rejects.
            // apk still installs vim and nano; the xterm-256color description is copied afterwards.
            let install = run("apk add --no-network /tmp/git-packages/*.apk; mkdir -p /etc/terminfo/x && cp /tmp/git-packages/xterm-256color /etc/terminfo/x/xterm-256color && git --version && vim --version && nano --version", timeout: 180_000, token: token)
            guard install.code == 0,
                  install.output.contains("git version"),
                  install.output.contains("VIM - Vi IMproved"),
                  install.output.contains("GNU nano") else {
                throw Failure(message: String(localized: "Could not prepare offline Git.") + "\n" + install.output, retainLease: install.code == -1001)
            }
            booted = true
        } catch {
            // Retry a quiescent cancelled APK installation without booting a
            // second kernel. A failed boot or uncertain tree remains closed.
            if !kernelStarted || gp_ish_active_threads() != 0 || (error as? Failure)?.retainLease == true {
                bootFailure = error
            }
            throw error
        }
    }

    static func run(_ script: String, timeout: UInt32 = 20_000, token: UInt64? = nil) -> (code: Int32, output: String) {
        var output = [CChar](repeating: 0, count: 65_536)
        var truncated: Int32 = 0
        let token = token ?? UInt64.random(in: 1...UInt64.max)
        let code = script.withCString { gp_ish_run($0, timeout, &output, output.count, &truncated, token) }
        return (code, String(cString: output))
    }

    private final class Sink {
        let output: (Data) -> Void
        let transition: (Bool) -> Int32
        init(_ output: @escaping (Data) -> Void, transition: @escaping (Bool) -> Int32) {
            self.output = output; self.transition = transition
        }
    }

    /// Synchronous, on `worker`. Lease and security scope outlive every guest
    /// thread, including detached jobs. An unconfirmed exit fails closed.
    static func shell(repo: URL, token: UInt64, rows: Int, cols: Int,
                      resolveLinkedFolder: Bool = true, suspension: @escaping (Bool) -> Void = { _ in }, output: @escaping (Data) -> Void) throws -> Int32 {
        try checkReset()
        let binding = try RepositoryAccessGate.holdBinding(repoName: repo.lastPathComponent, guest: true)
        var gate: RepoWriteLock.Hold? = try RepositoryAccessGate.holdGuest()
        let access = resolveLinkedFolder ? try WorktreeLink.beginForFileRestore(repoName: repo.lastPathComponent) : nil
        defer { withExtendedLifetime((gate, access, binding)) {} }
        do { try prepare(token: token) }
        catch {
            if gp_ish_active_threads() != 0 || (error as? Failure)?.retainLease == true {
                retainedAfterUnconfirmedExit.append(binding)
                if let gate { retainedAfterUnconfirmedExit.append(gate) }
                if let access { retainedAfterUnconfirmedExit.append(access) }
            }
            throw error
        }
        let sink = Sink(output) { paused in
            if paused {
                gate = nil
                suspension(true)
                return 0
            }
            do {
                if gate == nil { gate = try RepositoryAccessGate.holdGuest() }
                suspension(false)
                return 0
            } catch { return -1003 }
        }
        let context = Unmanaged.passRetained(sink).toOpaque()
        defer { Unmanaged<Sink>.fromOpaque(context).release() }
        let workspace = (access?.url ?? repo).resolvingSymlinksInPath()
        let gitdata = access == nil ? "" : repo.resolvingSymlinksInPath().path
        let code = workspace.path.withCString { path in
            gitdata.withCString { metadata in
                gp_ish_shell_managed(path, metadata, UInt32(rows), UInt32(cols), token, { bytes, length, context in
                    guard let bytes, let context, length > 0 else { return }
                    Unmanaged<Sink>.fromOpaque(context).takeUnretainedValue().output(Data(bytes: bytes, count: length))
                }, { paused, context in
                    guard let context else { return -1002 }
                    return Unmanaged<Sink>.fromOpaque(context).takeUnretainedValue().transition(paused != 0)
                }, context)
            }
        }
        if code == -1001 {
            retainedAfterUnconfirmedExit.append(binding)
            if let gate { retainedAfterUnconfirmedExit.append(gate) }
            if let access { retainedAfterUnconfirmedExit.append(access) }
            throw Failure(message: String(localized: "Shell exit could not be confirmed. Repository access stays locked; restart the app before continuing."), retainLease: true)
        }
        return code
    }
}
