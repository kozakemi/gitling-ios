import Foundation

struct SubmoduleInfo: Identifiable, Sendable {
    var id: String { path }
    let path: String
    let url: String
    let target: String?
    let head: String?
    let initialized: Bool
    let configured: Bool
    let dirty: Bool
    var problem: String? = nil
    var needsUpdate: Bool { target != nil && target != head }
}

enum SubmoduleAction: String, Codable, Sendable { case initialize, update }

struct SubmoduleCheckpoint: Codable, Sendable {
    var version = 1
    var id = UUID().uuidString
    var action: SubmoduleAction
    var recursive: Bool
    var initializeMissing: Bool
    var root: String
    var index: String
    var modules: String
    var targets: [String: String] = [:]
    var urls: [String: String] = [:]
    var completed: [String] = []
    var current: String?
}

struct SubmoduleSnapshot: Sendable {
    var items: [SubmoduleInfo]
    var checkpoint: SubmoduleCheckpoint?
}

struct SubmoduleCredentials: Sendable {
    var username = ""
    var secret = ""
    var sshKey: SSHKeyMaterial?
}

/// Snapshot account/key material before background work. The callback resolves
/// each actual URL separately, and rejects a redirect to a different authority.
struct SubmoduleAuth: Sendable {
    var resolve: @Sendable (String) -> SubmoduleCredentials = { _ in .init() }

    static func authority(_ raw: String) -> String? {
        if SSHURL.isSSH(raw) {
            if let url = URL(string: raw), url.scheme == "ssh", let host = url.host {
                return "ssh://\(host.lowercased()):\(url.port ?? 22)"
            }
            return SSHURL.host(raw).map { "ssh://\($0):22" }
        }
        guard let url = URL(string: raw), let host = url.host, let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        return "\(scheme)://\(host.lowercased()):\(url.port ?? (scheme == "https" ? 443 : 80))"
    }

    func credentials(for actual: String, expected: String) -> SubmoduleCredentials? {
        guard let authority = Self.authority(expected), authority == Self.authority(actual) else { return nil }
        let intended = resolve(expected), requested = resolve(actual)
        guard intended.username == requested.username, intended.secret == requested.secret,
              intended.sshKey?.privateKey == requested.sshKey?.privateKey,
              intended.sshKey?.passphrase == requested.sshKey?.passphrase else { return nil }
        return requested
    }
}

struct SubmoduleAccountSecret: Sendable {
    let account: RemoteAccount
    let secret: String
}

struct SubmoduleCredentialRouter: Sendable {
    var accounts: [SubmoduleAccountSecret] = []
    var selectedAccounts: [String: UUID] = [:]
    var sshKeys: [String: SSHKeyMaterial] = [:]
    var overrides: [String: SubmoduleCredentials] = [:]

    func credentials(for url: String) -> SubmoduleCredentials {
        guard let authority = SubmoduleAuth.authority(url) else { return .init() }
        if SSHURL.isSSH(url) { return .init(sshKey: sshKeys[authority]) }
        if let manual = overrides[authority], !manual.secret.isEmpty { return manual }
        let matches = accounts.filter {
            $0.account.matches(url) && SubmoduleAuth.authority($0.account.baseURL) == authority
        }
        let chosen: SubmoduleAccountSecret?
        if let selected = selectedAccounts[authority] { chosen = matches.first { $0.account.id == selected } }
        else { chosen = matches.first }
        guard let chosen else { return .init() }
        return .init(username: chosen.account.provider == .gitlab ? "oauth2" : chosen.account.username, secret: chosen.secret)
    }
}
