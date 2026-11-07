import Foundation

struct GitLabUser: Equatable, Sendable {
    var id: Int
    var username: String
    var name: String

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? username : trimmed
    }
}

enum GitLabClientError: LocalizedError, Equatable {
    case invalidInstance
    case unauthorized
    case forbidden
    case unreachable
    case invalidResponse
    case repositories

    var errorDescription: String? {
        switch self {
        case .invalidInstance:
            String(localized: "Enter a valid HTTPS GitLab address.")
        case .unauthorized:
            String(localized: "GitLab rejected this token. Check that it is valid and has read_api.")
        case .forbidden:
            String(localized: "This token does not have permission to read this GitLab account.")
        case .unreachable:
            String(localized: "Couldn't reach GitLab. Check the address and your connection.")
        case .invalidResponse:
            String(localized: "This address did not answer like a GitLab instance.")
        case .repositories:
            String(localized: "Couldn't load repositories from this GitLab account.")
        }
    }
}

enum GitLabClient {
    static func fetchUser(baseURL: URL, token: String) async throws -> GitLabUser {
        let request = try makeRequest(baseURL: baseURL, path: "user", token: token)
        let (data, response) = try await load(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200:
            guard let body = try? JSONDecoder().decode(UserBody.self, from: data),
                  !body.username.isEmpty else { throw GitLabClientError.invalidResponse }
            return GitLabUser(id: body.id, username: body.username, name: body.name ?? "")
        case 401:
            throw GitLabClientError.unauthorized
        case 403:
            throw GitLabClientError.forbidden
        default:
            throw GitLabClientError.invalidResponse
        }
    }

    static func fetchProjects(baseURL: URL, token: String) async throws -> [RemoteProject] {
        var projects: [RemoteProject] = []
        var page = 1
        while page <= 3 {
            guard var components = URLComponents(
                url: try apiURL(baseURL: baseURL, path: "projects"),
                resolvingAgainstBaseURL: false
            ) else { throw GitLabClientError.invalidInstance }
            components.queryItems = [
                URLQueryItem(name: "membership", value: "true"),
                URLQueryItem(name: "simple", value: "true"),
                URLQueryItem(name: "order_by", value: "last_activity_at"),
                URLQueryItem(name: "sort", value: "desc"),
                URLQueryItem(name: "per_page", value: "100"),
                URLQueryItem(name: "page", value: "\(page)"),
            ]
            guard let url = components.url else { throw GitLabClientError.invalidInstance }
            var request = URLRequest(url: url)
            request.setValue(token, forHTTPHeaderField: "PRIVATE-TOKEN")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("Gitling", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await load(request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch status {
            case 200:
                let rows = (try? JSONDecoder().decode([ProjectBody].self, from: data)) ?? []
                for row in rows {
                    let clone = row.httpURL.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !clone.isEmpty,
                          !row.pathWithNamespace.isEmpty,
                          !row.path.isEmpty else { continue }
                    projects.append(RemoteProject(
                        id: "gitlab:\(row.id)",
                        provider: .gitlab,
                        name: row.path,
                        fullName: row.pathWithNamespace,
                        description: row.description ?? "",
                        cloneURL: clone,
                        stars: row.starCount ?? 0,
                        language: ""
                    ))
                }
                if rows.count < 100 { return projects }
                page += 1
            case 401:
                throw GitLabClientError.unauthorized
            case 403:
                throw GitLabClientError.forbidden
            default:
                throw GitLabClientError.repositories
            }
        }
        return projects
    }

    private static func apiURL(baseURL: URL, path: String) throws -> URL {
        guard let api = InstanceURL.apiBase(for: baseURL) else {
            throw GitLabClientError.invalidInstance
        }
        return api.appendingPathComponent(path)
    }

    private static func makeRequest(baseURL: URL, path: String, token: String) throws -> URLRequest {
        var request = URLRequest(url: try apiURL(baseURL: baseURL, path: path))
        request.setValue(token, forHTTPHeaderField: "PRIVATE-TOKEN")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Gitling", forHTTPHeaderField: "User-Agent")
        return request
    }

    private static func load(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await URLSession.shared.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw GitLabClientError.unreachable
        }
    }

    private struct UserBody: Decodable {
        var id: Int
        var username: String
        var name: String?
    }

    private struct ProjectBody: Decodable {
        var id: Int
        var path: String
        var pathWithNamespace: String
        var description: String?
        var httpURL: String
        var starCount: Int?

        enum CodingKeys: String, CodingKey {
            case id
            case path
            case pathWithNamespace = "path_with_namespace"
            case description
            case httpURL = "http_url_to_repo"
            case starCount = "star_count"
        }
    }
}
