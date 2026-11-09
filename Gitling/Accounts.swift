import Foundation

enum GitProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case github
    case gitlab

    var id: String { rawValue }

    var title: String {
        switch self {
        case .github: return "GitHub"
        case .gitlab: return "GitLab"
        }
    }
}

struct RemoteAccount: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var provider: GitProvider
    /// Canonical web base URL, for example https://github.com or https://gitlab.example.com/gitlab.
    var baseURL: String
    var username: String
    var displayName: String
    var createdAt: Date

    var instanceURL: URL? { URL(string: baseURL) }

    var accountLabel: String {
        guard let host = instanceURL?.host, !host.isEmpty else {
            return "\(provider.title) · \(username)"
        }
        if provider == .github { return "GitHub · \(username)" }
        if host == "gitlab.com" { return "GitLab.com · \(username)" }
        return "\(host) · \(username)"
    }

    var detail: String {
        if provider == .github { return "github.com" }
        return baseURL
    }

    func matches(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString),
              let base = instanceURL else { return false }
        if provider == .github {
            return url.host?.lowercased() == "github.com"
        }
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              scheme == base.scheme?.lowercased(),
              url.host?.lowercased() == base.host?.lowercased() else { return false }
        if effectivePort(url) != effectivePort(base) { return false }
        let basePath = base.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let urlPath = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if basePath.isEmpty { return true }
        return urlPath == basePath || urlPath.hasPrefix(basePath + "/")
    }

    private func effectivePort(_ url: URL) -> Int? {
        if let port = url.port { return port }
        switch url.scheme?.lowercased() {
        case "https": return 443
        case "http": return 80
        default: return nil
        }
    }
}

struct RemoteProject: Identifiable, Equatable, Sendable {
    let id: String
    let provider: GitProvider
    let name: String
    let fullName: String
    let description: String
    let cloneURL: String
    let stars: Int
    let language: String
}

enum InstanceURL {
    static func canonical(_ raw: String) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") {
            text = "https://" + text
        }
        guard var components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = components.host,
              !host.isEmpty,
              components.user == nil,
              components.password == nil else { return nil }
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        if path.hasSuffix("/api/v4") {
            path = String(path.dropLast("/api/v4".count))
        }
        while path.hasSuffix("/") { path.removeLast() }
        components.scheme = scheme
        components.host = host.lowercased()
        components.path = path
        components.query = nil
        components.fragment = nil
        components.user = nil
        components.password = nil
        if let port = components.port,
           (scheme == "https" && port == 443) || (scheme == "http" && port == 80) {
            components.port = nil
        }
        return components.url
    }

    static func apiBase(for baseURL: URL) -> URL? {
        baseURL.appendingPathComponent("api").appendingPathComponent("v4")
    }
}
