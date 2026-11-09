import Foundation

struct SSHKey: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var name: String
    var createdAt: Date
}

struct SSHKeyMaterial: Sendable {
    var privateKey: String
    var passphrase: String?
}

enum GitRemoteURL {
    static func isSupported(_ raw: String) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return text.hasPrefix("https://")
            || text.hasPrefix("http://")
            || SSHURL.isSSH(raw)
    }

    static func isHTTP(_ raw: String) -> Bool {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("http://")
    }

    /// HTTP Basic auth is more reliable when the user name is not embedded in
    /// the URL. libgit2's HTTP auth negotiation fails on some servers when the
    /// URL carries userinfo, so move it into the credential callback instead.
    static func splitUserInfo(_ raw: String) -> (url: String, username: String?, password: String?) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https" || scheme == "ssh",
              components.host != nil else {
            return (text, nil, nil)
        }
        let username = components.user?.removingPercentEncoding
        let password = components.password?.removingPercentEncoding
        components.user = nil
        components.password = nil
        return (components.url?.absoluteString ?? text, username, password)
    }
}

enum SSHURL {
    static func isSSH(_ raw: String) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasPrefix("ssh://") { return true }
        if text.lowercased().hasPrefix("http://") || text.lowercased().hasPrefix("https://") {
            return false
        }
        // scp-like: git@example.com:group/repo.git
        guard let at = text.firstIndex(of: "@"),
              let colon = text[at...].firstIndex(of: ":") else { return false }
        return colon > at && colon < text.endIndex
    }

    static func host(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: text), let host = url.host {
            return host.lowercased()
        }
        guard let at = text.firstIndex(of: "@") else { return nil }
        let rest = text[text.index(after: at)...]
        guard let colon = rest.firstIndex(of: ":") else { return nil }
        return String(rest[..<colon]).lowercased()
    }
}
