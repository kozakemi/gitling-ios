#if DEBUG
import Foundation
import SwiftUI

/// Explicit opt-in, two-launch recovery check for an empty QA simulator.
/// Uses an isolated offline repository; never selects the user's repositories.
struct TerminalResetQAView: View {
    @State private var result = "Checking terminal recovery…"
    var body: some View {
        Text(verbatim: result).font(.caption.monospaced()).padding().task {
            let args = ProcessInfo.processInfo.arguments
            let verify = args.contains("verify-reset")
            do {
                var row = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[String: String], Error>) in
                    TerminalRuntime.worker.async {
                        do { continuation.resume(returning: try TerminalResetQA.check(verify: verify)) }
                        catch { continuation.resume(throwing: error) }
                    }
                }
                if !verify {
                    await TerminalResetController.shared.reset()
                    guard UserDefaults.standard.bool(forKey: TerminalEnvironmentStore.pendingKey) else {
                        throw TerminalRuntime.Failure(message: TerminalResetController.shared.message ?? "Reset was not prepared")
                    }
                    do { try TerminalRuntime.prepare(); throw TerminalRuntime.Failure(message: "A reset must require a new process") }
                    catch let error as TerminalRuntime.Failure where error.restartRequired { row["restartRequired"] = "true" }
                }
                row["success"] = "true"
                try TerminalResetQA.save(row, phase: verify ? "verify" : "damage")
                result = String(describing: row)
            } catch {
                try? TerminalResetQA.save(["success": "false", "error": String(describing: error)], phase: verify ? "verify" : "damage")
                result = String(describing: error)
            }
        }
    }
}
private enum TerminalResetQA {
    static var directory: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("TerminalResetQA") }
    static func save(_ row: [String: String], phase: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: row, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent(phase + ".json"), options: .atomic)
    }
    static func check(verify: Bool) throws -> [String: String] {
        let repo = directory.appendingPathComponent("repository")
        if !verify {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try GitClient.initialize(name: "repository", root: directory)
            try Data("repository stays intact\n".utf8).write(to: repo.appendingPathComponent("note.txt"))
            try GitClient.stageAll(at: repo)
            try GitClient.commit(at: repo, message: "offline recovery fixture", name: "QA", email: "qa@example.invalid")
            UserDefaults.standard.set("keep", forKey: "terminalResetQA.appPreference")
        }
        let assets = Bundle.main.resourceURL!.appendingPathComponent("TerminalRuntime")
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: assets.appendingPathComponent("manifest.json"))) as! [String: Any]
        let version = object["version"] as! String
        let selected = try TerminalEnvironmentStore.live.rootForLaunch(version: version)
        let output: String
        do {
            let lease = try RepositoryAccessGate.holdGuest()
            defer { withExtendedLifetime(lease) {} }
            try TerminalRuntime.prepare()
            let command = verify
                ? "test ! -e /root/reset-private-note && git --version && vim --version && nano --version && test -x /bin/sh && test -x /sbin/ishsv"
                : "echo private >/root/reset-private-note; rm -f /usr/bin/git /usr/bin/vim /usr/bin/nano /bin/sh /sbin/ishsv"
            let result = TerminalRuntime.run(command, timeout: 30_000)
            guard result.code == 0 else { throw TerminalRuntime.Failure(message: "Guest recovery check failed: \(result)") }
            output = result.output
        }
        guard try GitClient.status(at: repo).isEmpty,
              try GitClient.history(at: repo).count == 1,
              try String(contentsOf: repo.appendingPathComponent("note.txt"), encoding: .utf8) == "repository stays intact\n",
              UserDefaults.standard.string(forKey: "terminalResetQA.appPreference") == "keep" else {
            throw TerminalRuntime.Failure(message: "Native repository or application preference changed")
        }
        if verify {
            let before = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("damage.json"))) as! [String: String]
            guard before["root"] != selected.path,
                  !FileManager.default.fileExists(atPath: before["root"]!) else { throw TerminalRuntime.Failure(message: "Old private environment was not replaced on relaunch") }
        } else {
            guard !FileManager.default.fileExists(atPath: selected.appendingPathComponent("data/bin/sh").path) else {
                throw TerminalRuntime.Failure(message: "Damage command did not remove the shell")
            }
        }
        return ["root": selected.path, "versions": output, "repositoryPreserved": "true", "appPreferencePreserved": "true"]
    }
}
#endif
