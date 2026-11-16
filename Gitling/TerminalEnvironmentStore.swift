import Foundation
import SwiftUI

/// Only manages private Linux rootfs generations, never a mounted worktree.
/// A running kernel keeps its old generation until the app exits.
struct TerminalEnvironmentStore {
    static let pendingKey = "terminal.resetRequiresRelaunch"
    let directory: URL
    private let manager = FileManager.default
    private struct State: Codable { var generation: UUID; var cleanupOnLaunch: Bool }
    private var stateURL: URL { directory.appendingPathComponent("environment.json") }

    static var live: Self {
        .init(directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TerminalRuntime", isDirectory: true))
    }
    private func validateVersion(_ version: String) throws {
        guard version.count == 64, version.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
    }
    private func ensureDirectory() throws {
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        guard try directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw CocoaError(.fileReadNoPermission)
        }
    }
    private func state() throws -> State? {
        do { return try JSONDecoder().decode(State.self, from: Data(contentsOf: stateURL)) }
        catch CocoaError.fileReadNoSuchFile { return nil }
    }
    private func root(version: String, generation: UUID?) -> URL {
        directory.appendingPathComponent(version + (generation.map { "-" + $0.uuidString } ?? ""), isDirectory: true)
    }
    /// Stage first, atomically select last. Never rename/delete the live rootfs.
    @discardableResult func prepareReset(version: String, pristine: URL) throws -> URL {
        try validateVersion(version); try ensureDirectory()
        let generation = UUID(), staging = directory.appendingPathComponent("staging-" + UUID().uuidString)
        let destination = root(version: version, generation: generation)
        var selected = false
        defer {
            try? manager.removeItem(at: staging)
            if !selected { try? manager.removeItem(at: destination) }
        }
        try manager.copyItem(at: pristine, to: staging)
        for (path, type) in [("data", FileAttributeType.typeDirectory), ("meta.db", .typeRegular)] {
            let attributes = try manager.attributesOfItem(atPath: staging.appendingPathComponent(path).path)
            guard attributes[.type] as? FileAttributeType == type else { throw CocoaError(.fileReadCorruptFile) }
        }
        try manager.moveItem(at: staging, to: destination)
        try JSONEncoder().encode(State(generation: generation, cleanupOnLaunch: true)).write(to: stateURL, options: .atomic)
        selected = true
        return destination
    }
    /// Called before boot in a new process, never after staging in the old one.
    func rootForLaunch(version: String) throws -> URL {
        try validateVersion(version); try ensureDirectory()
        var saved = try state()
        let selected = root(version: version, generation: saved?.generation)
        if saved?.cleanupOnLaunch == true {
            for candidate in try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                guard candidate != selected, Self.isManagedRoot(candidate.lastPathComponent) else { continue }
                // removeItem removes a symlink itself; it never follows it into
                // another directory. Only generated names under this parent qualify.
                try manager.removeItem(at: candidate)
            }
            saved?.cleanupOnLaunch = false
            if let saved { try JSONEncoder().encode(saved).write(to: stateURL, options: .atomic) }
        }
        return selected
    }
    private static func isManagedRoot(_ name: String) -> Bool {
        let prefix = String(name.prefix(64))
        guard prefix.count == 64, prefix.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return false }
        return name.count == 64 || (name.count == 101 && name.dropFirst(64).first == "-" && UUID(uuidString: String(name.dropFirst(65))) != nil)
    }
}

@MainActor final class TerminalResetController: ObservableObject {
    static let shared = TerminalResetController()
    @Published private(set) var resetting = false
    @Published private(set) var message: String?

    func reset() async {
        guard !resetting else { return }
        resetting = true; message = nil
        TerminalRuntime.beginEnvironmentReset()
        do {
            try await Task.detached(priority: .userInitiated) {
                guard let assets = Bundle.main.resourceURL?.appendingPathComponent("TerminalRuntime"),
                      let object = try JSONSerialization.jsonObject(with: Data(contentsOf: assets.appendingPathComponent("manifest.json"))) as? [String: Any],
                      let version = object["version"] as? String else { throw CocoaError(.fileReadCorruptFile) }
                try TerminalEnvironmentStore.live.prepareReset(version: version, pristine: assets.appendingPathComponent("fs"))
            }.value
            UserDefaults.standard.set(true, forKey: TerminalEnvironmentStore.pendingKey)
            message = String(localized: "Terminal reset is ready. Close Gitling and reopen it to use the clean offline environment.")
        } catch {
            TerminalRuntime.cancelEnvironmentReset()
            message = error.localizedDescription
        }
        resetting = false
    }
}

struct TerminalResetSection: View {
    @ObservedObject var controller = TerminalResetController.shared
    @State private var confirm = false
    @AppStorage(TerminalEnvironmentStore.pendingKey) private var pending = false
    var body: some View {
        Section("Terminal") {
            Text("Shell commands can remove Git, editors, startup files and private terminal files. Reset restores the bundled offline environment after reopening the app.")
                .font(.footnote).foregroundStyle(.secondary)
            Button("Reset Terminal Environment", role: .destructive) { confirm = true }
                .fixedSize(horizontal: false, vertical: true)
                .disabled(controller.resetting || pending).accessibilityIdentifier("terminal.reset")
            if controller.resetting { ProgressView("Preparing terminal reset…") }
            if let message = controller.message { Text(message).font(.footnote).textSelection(.enabled) }
            else if pending { Text("Close Gitling and reopen it to finish resetting the terminal.").font(.footnote) }
        }
        .confirmationDialog("Reset Terminal Environment?", isPresented: $confirm, titleVisibility: .visible) {
            Button("Reset Terminal Environment", role: .destructive) { Task { await controller.reset() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This ends terminal sessions and removes their private Linux files, settings and added packages after reopening Gitling. Gitling-managed repositories, linked working folders, their commits and saved app credentials are kept. Repositories cloned inside the private Linux environment are removed too. Shell commands can still modify repository files; reset does not undo those changes.")
        }
    }
}
