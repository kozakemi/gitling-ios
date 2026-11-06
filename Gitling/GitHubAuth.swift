import Foundation

enum GitHubAuthError: Error, Equatable, LocalizedError {
    case unreachable
    case denied
    case timedOut
    case profile
    case repos

    var errorDescription: String? {
        switch self {
        case .unreachable:
            String(localized: "Couldn't reach GitHub. Check your connection and try again.")
        case .denied:
            String(localized: "GitHub sign-in was cancelled or denied.")
        case .timedOut:
            String(localized: "GitHub sign-in timed out. Please try again.")
        case .profile:
            String(localized: "Connected, but couldn't load your GitHub profile.")
        case .repos:
            String(localized: "Couldn't load repositories from this GitHub account.")
        }
    }
}

struct GitHubRepo: Identifiable, Equatable, Sendable {
    var name: String
    var fullName: String
    var description: String
    var cloneURL: String
    var stars: Int
    var language: String

    var id: String { fullName }
}

enum RemoteCredentials {
    static func resolve(username: String, secret: String, saved: KeychainStore.Item?) -> (username: String, secret: String) {
        let username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        if !secret.isEmpty {
            return (username, secret)
        }
        if let saved {
            return (saved.username, saved.secret)
        }
        return (username, secret)
    }
}

enum GitHubAuth {
    static let host = "github.com"
    static let clientID = "Ov23limX5SJfOQfVzNXZ"

    struct DeviceCode: Equatable, Sendable {
        var deviceCode: String
        var userCode: String
        var verificationURI: String
        var verificationURIComplete: String
        var interval: Int
        var expiresIn: Int

        var pageURL: URL? {
            let complete = verificationURIComplete.trimmingCharacters(in: .whitespacesAndNewlines)
            let plain = verificationURI.trimmingCharacters(in: .whitespacesAndNewlines)
            return URL(string: complete.isEmpty ? plain : complete)
        }
    }

    enum Poll: Equatable {
        case pending
        case slowDown
        case token(String)
        case denied
    }

    static func requestDeviceCode() async throws -> DeviceCode {
        let (data, status) = try await post(
            url: URL(string: "https://github.com/login/device/code")!,
            fields: ["client_id": clientID, "scope": "repo user"]
        )
        guard status == 200, let code = decodeDeviceCode(data) else { throw GitHubAuthError.unreachable }
        return code
    }

    static func poll(deviceCode: String, interval: Int, expiresIn: Int) async throws -> String {
        var wait = max(interval, 5)
        let deadline = Date().addingTimeInterval(TimeInterval(expiresIn))
        while Date() < deadline {
            try await Task.sleep(nanoseconds: UInt64(wait) * 1_000_000_000)
            try Task.checkCancellation()
            switch await pollOnce(deviceCode: deviceCode) {
            case .pending:
                continue
            case .slowDown:
                wait += 5
            case .token(let token):
                return token
            case .denied:
                throw GitHubAuthError.denied
            }
        }
        throw GitHubAuthError.timedOut
    }

    static func fetchRepos(token: String) async throws -> [GitHubRepo] {
        var page = 1
        var all: [GitHubRepo] = []
        while page <= 3 {
            var request = URLRequest(url: URL(string: "https://api.github.com/user/repos?sort=updated&per_page=100&page=\(page)")!)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("Gitling", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else { throw GitHubAuthError.repos }
            let batch = decodeRepos(data)
            all.append(contentsOf: batch)
            if batch.count < 100 { break }
            page += 1
        }
        return all
    }

    static func decodeRepos(_ data: Data) -> [GitHubRepo] {
        guard let rows = try? JSONDecoder().decode([RepoBody].self, from: data) else { return [] }
        return rows.compactMap { row in
            guard !row.name.isEmpty, !row.fullName.isEmpty, !row.cloneURL.isEmpty else { return nil }
            return GitHubRepo(
                name: row.name,
                fullName: row.fullName,
                description: row.description ?? "",
                cloneURL: row.cloneURL,
                stars: row.stars ?? 0,
                language: row.language ?? ""
            )
        }
    }

    static func fetchLogin(token: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.github.com/user")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Gitling", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, let login = decodeLogin(data), !login.isEmpty else {
            throw GitHubAuthError.profile
        }
        return login
    }

    static func decodeDeviceCode(_ data: Data) -> DeviceCode? {
        guard let json = try? JSONDecoder().decode(DeviceCodeBody.self, from: data),
              !json.deviceCode.isEmpty,
              !json.userCode.isEmpty,
              !json.verificationURI.isEmpty else { return nil }
        return DeviceCode(
            deviceCode: json.deviceCode,
            userCode: json.userCode,
            verificationURI: json.verificationURI,
            verificationURIComplete: json.verificationURIComplete ?? "",
            interval: json.interval ?? 5,
            expiresIn: json.expiresIn ?? 900
        )
    }

    static func decodePoll(_ data: Data) -> Poll {
        guard let json = try? JSONDecoder().decode(PollBody.self, from: data) else { return .pending }
        if let token = json.accessToken, !token.isEmpty { return .token(token) }
        switch json.error {
        case "authorization_pending":
            return .pending
        case "slow_down":
            return .slowDown
        case nil:
            return .pending
        default:
            return .denied
        }
    }

    static func decodeLogin(_ data: Data) -> String? {
        (try? JSONDecoder().decode(UserBody.self, from: data))?.login
    }

    private static func pollOnce(deviceCode: String) async -> Poll {
        do {
            let (data, _) = try await post(
                url: URL(string: "https://github.com/login/oauth/access_token")!,
                fields: [
                    "client_id": clientID,
                    "device_code": deviceCode,
                    "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                ]
            )
            return decodePoll(data)
        } catch {
            return .pending
        }
    }

    private static func post(url: URL, fields: [String: String]) async throws -> (Data, Int) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = form(fields)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (data, status)
    }

    private static func form(_ fields: [String: String]) -> Data {
        let body = fields.map { key, value in
            "\(escape(key))=\(escape(value))"
        }.joined(separator: "&")
        return Data(body.utf8)
    }

    private static func escape(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private struct DeviceCodeBody: Decodable {
        var deviceCode: String
        var userCode: String
        var verificationURI: String
        var verificationURIComplete: String?
        var expiresIn: Int?
        var interval: Int?
        enum CodingKeys: String, CodingKey {
            case deviceCode = "device_code"
            case userCode = "user_code"
            case verificationURI = "verification_uri"
            case verificationURIComplete = "verification_uri_complete"
            case expiresIn = "expires_in"
            case interval
        }
    }

    private struct PollBody: Decodable {
        var accessToken: String?
        var error: String?
        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case error
        }
    }

    private struct UserBody: Decodable {
        var login: String
    }

    private struct RepoBody: Decodable {
        var name: String
        var fullName: String
        var description: String?
        var cloneURL: String
        var stars: Int?
        var language: String?
        enum CodingKeys: String, CodingKey {
            case name
            case fullName = "full_name"
            case description
            case cloneURL = "clone_url"
            case stars = "stargazers_count"
            case language
        }
    }
}
