import CryptoKit
import Foundation

struct LFSPointer: Codable, Equatable, Sendable {
    var oid: String
    var size: Int
    var raw: String

    var isValid: Bool {
        oid.count == 64 && oid.allSatisfy { $0.isHexDigit } && size >= 0
    }

    static func parse(_ text: String) -> LFSPointer? {
        guard text.hasPrefix("version https://git-lfs.github.com/spec/v1") else { return nil }
        var oid: String?
        var size: Int?
        for line in text.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("oid sha256:") {
                oid = String(line.dropFirst("oid sha256:".count))
            } else if line.hasPrefix("size ") {
                size = Int(line.dropFirst("size ".count))
            }
        }
        guard let oid, let size else { return nil }
        let pointer = LFSPointer(oid: oid, size: size, raw: text)
        return pointer.isValid ? pointer : nil
    }

    static func make(oid: String, size: Int) -> LFSPointer {
        let raw = "version https://git-lfs.github.com/spec/v1\noid sha256:\(oid)\nsize \(size)\n"
        return LFSPointer(oid: oid, size: size, raw: raw)
    }
}

struct LFSBatchObject: Decodable {
    var oid: String
    var size: Int
    var error: LFSObjectError?
    var actions: [String: LFSAction]?
}

struct LFSObjectError: Decodable {
    var code: Int?
    var message: String?
}

struct LFSAction: Decodable {
    var href: String
    var header: [String: String]?
    var expiresIn: Int?

    enum CodingKeys: String, CodingKey {
        case href
        case header
        case expiresIn = "expires_in"
    }
}

struct LFSBatchResponse: Decodable {
    var objects: [LFSBatchObject]
}

enum LFSError: LocalizedError, Equatable {
    case endpoint
    case unauthorized
    case server
    case missingObject
    case invalidObject
    case file

    var errorDescription: String? {
        switch self {
        case .endpoint:
            String(localized: "Could not determine the Git LFS server for this remote.")
        case .unauthorized:
            String(localized: "Git LFS authentication failed.")
        case .server:
            String(localized: "The Git LFS server returned an error.")
        case .missingObject:
            String(localized: "A Git LFS object is missing from the server.")
        case .invalidObject:
            String(localized: "A Git LFS object failed its checksum.")
        case .file:
            String(localized: "Could not write a Git LFS file.")
        }
    }
}

struct LFSAuth: Sendable {
    var username: String
    var secret: String
    var instanceBaseURL: URL?
}

enum LFSClient {
    private struct BatchRequest: Encodable {
        var operation: String
        var transfers = ["basic"]
        var objects: [RequestObject]
    }

    private struct RequestObject: Encodable {
        var oid: String
        var size: Int
    }

    private struct ActionBody: Encodable {
        var oid: String
        var size: Int
    }

    private struct BatchObject: Encodable {
        var oid: String
        var size: Int
    }

    private static let manifestName = "lfs-pointers.json"
    private static let contentCache = LFSContentCache()

    static func isPointer(_ data: Data) -> LFSPointer? {
        guard data.count <= 1024,
              let text = String(data: data, encoding: .utf8) else { return nil }
        return LFSPointer.parse(text)
    }

    static func smudge(at repoURL: URL, gitDirectory: URL? = nil, remoteURL: String, auth: LFSAuth?, session: URLSession = .shared, progress: GitProgressReporter = .init(handler: nil)) throws {
        let pointers = try pointerFiles(at: repoURL)
        guard !pointers.isEmpty else { return }
        var unique: [String: LFSPointer] = [:]
        for pointer in pointers.values {
            unique[pointer.oid] = pointer
        }
        let objects = try downloadObjects(
            Array(unique.values),
            remoteURL: remoteURL,
            auth: auth,
            session: session,
            progress: progress
        )
        progress.report(.checkingOut, total: pointers.count)
        var written = 0
        for (path, pointer) in pointers.sorted(by: { $0.key < $1.key }) {
            guard let data = objects[pointer.oid] else { continue }
            if data.count != pointer.size {
                throw LFSError.invalidObject
            }
            let destination = repoURL.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: destination, options: .atomic)
            written += 1
            progress.report(.checkingOut, completed: written, total: pointers.count)
        }
        try saveManifest(pointers, at: repoURL, gitDirectory: gitDirectory)
    }

    static func clean(at repoURL: URL, gitDirectory: URL? = nil, remoteURL: String, auth: LFSAuth?, session: URLSession = .shared, paths: Set<String>? = nil) throws -> [String: LFSPointer] {
        let previous = loadManifest(at: repoURL, gitDirectory: gitDirectory)
        let patterns = lfsPatterns(at: repoURL, paths: paths)
        let selected = paths ?? (patterns.isEmpty ? Set(previous.keys) : Set(worktreeFiles(at: repoURL)))
        let candidates = Set(previous.keys).intersection(selected).union(
            patterns.isEmpty ? [] : selected.filter { path in
                patterns.contains { matches(pattern: $0, path: path) }
            }
        )
        var current: [String: LFSPointer] = [:]
        var uploads: [String: Data] = [:]

        for path in candidates {
            let url = repoURL.appendingPathComponent(path)
            guard let data = try? Data(contentsOf: url) else { continue }
            if let pointer = isPointer(data) {
                current[path] = pointer
                continue
            }
            let oid = sha256(data)
            if let old = previous[path], old.oid == oid, old.size == data.count {
                current[path] = old
                continue
            }
            let pointer = LFSPointer.make(oid: oid, size: data.count)
            current[path] = pointer
            uploads[oid] = data
        }

        if !uploads.isEmpty {
            try uploadObjects(uploads, remoteURL: remoteURL, auth: auth, session: session)
        }
        var manifest = paths == nil ? [:] : previous
        if let paths { for path in paths { manifest.removeValue(forKey: path) } }
        manifest.merge(current) { _, new in new }
        if manifest.isEmpty {
            try? FileManager.default.removeItem(at: manifestURL(repoURL, gitDirectory: gitDirectory))
        } else {
            try saveManifest(manifest, at: repoURL, gitDirectory: gitDirectory)
        }
        return current
    }

    /// Return the paths whose worktree contents still match their LFS pointer.
    /// libgit2 compares the smudged bytes with the pointer blob in the index,
    /// so those paths must be treated as clean in the status UI.
    static func cleanPaths(at repoURL: URL, gitDirectory: URL? = nil, candidates: Set<String>? = nil, indexPointers: [String: LFSPointer]? = nil) -> Set<String> {
        if let candidates, candidates.isEmpty { return [] }
        let pointers = indexPointers ?? loadManifest(at: repoURL, gitDirectory: gitDirectory)
        guard !pointers.isEmpty else { return [] }
        var clean: Set<String> = []
        for (path, pointer) in pointers {
            if let candidates, !candidates.contains(path) { continue }
            if contentCache.matches(repoURL.appendingPathComponent(path), pointer: pointer) {
                clean.insert(path)
            }
        }
        return clean
    }

    static func removeManifest(at repoURL: URL, gitDirectory: URL? = nil) {
        try? FileManager.default.removeItem(at: manifestURL(repoURL, gitDirectory: gitDirectory))
    }

    private static func pointerFiles(at repoURL: URL) throws -> [String: LFSPointer] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: repoURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [:] }
        var result: [String: LFSPointer] = [:]
        for case let url as URL in enumerator {
            if url.lastPathComponent == ".git" { enumerator.skipDescendants(); continue }
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true,
                  (values?.fileSize ?? 0) <= 1024 else { continue }
            guard let data = try? Data(contentsOf: url),
                  let pointer = isPointer(data) else { continue }
            let path = String(url.path.dropFirst(repoURL.path.count + 1))
            result[path] = pointer
        }
        return result
    }

    static func endpoint(remoteURL: String, instanceBaseURL: URL?) throws -> URL {
        let remote = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        var host: String?
        var path = ""
        var scheme = "https"
        var port: Int?

        if let url = URL(string: remote), let parsedHost = url.host {
            host = parsedHost
            path = url.path
            scheme = url.scheme?.lowercased() ?? "https"
            if let parsedPort = url.port { port = parsedPort }
        } else if let at = remote.firstIndex(of: "@") {
            let rest = remote[remote.index(after: at)...]
            guard let colon = rest.firstIndex(of: ":") else { throw LFSError.endpoint }
            host = String(rest[..<colon])
            path = String(rest[rest.index(after: colon)...])
        }

        guard var host, !host.isEmpty else { throw LFSError.endpoint }
        if !path.hasPrefix("/") { path = "/" + path }
        if scheme == "ssh" { scheme = "https" }
        if path.hasSuffix("/") { path.removeLast() }
        if !path.hasSuffix(".git") { path += ".git" }

        if let base = instanceBaseURL, base.host?.lowercased() == host.lowercased() {
            host = base.host ?? host
            if remote.lowercased().hasPrefix("ssh://") || (!remote.lowercased().hasPrefix("http://") && !remote.lowercased().hasPrefix("https://")) {
                // SSH URLs need the account's HTTPS/HTTP endpoint and port.
                scheme = base.scheme ?? "https"
                port = base.port
            } else if port == nil {
                port = base.port
            }
        } else if remote.lowercased().hasPrefix("ssh://") {
            // A custom SSH port is not an HTTP port. Prefer the default HTTPS
            // port unless an account supplied the instance URL.
            port = nil
        }

        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.port = port
        components.path = path + "/info/lfs"
        guard let endpoint = components.url else { throw LFSError.endpoint }
        return endpoint
    }

    private static func downloadObjects(
        _ pointers: [LFSPointer], remoteURL: String, auth: LFSAuth?, session: URLSession,
        progress: GitProgressReporter
    ) throws -> [String: Data] {
        let expected = Dictionary(uniqueKeysWithValues: pointers.map { ($0.oid, $0.size) })
        var totalBytes = 0
        for pointer in pointers {
            let sum = totalBytes.addingReportingOverflow(pointer.size)
            guard !sum.overflow else { throw LFSError.invalidObject }
            totalBytes = sum.partialValue
        }
        progress.report(.largeFiles, total: pointers.count, byteTotal: totalBytes)
        let endpoint = try endpoint(remoteURL: remoteURL, instanceBaseURL: auth?.instanceBaseURL)
        let response = try batch(operation: "download", pointers: pointers, endpoint: endpoint, auth: auth, session: session)
        guard response.objects.count == pointers.count,
              Set(response.objects.map(\.oid)) == Set(expected.keys) else { throw LFSError.missingObject }
        var result: [String: Data] = [:]
        var completedBytes = 0
        for object in response.objects {
            if object.error != nil { throw LFSError.server }
            guard let size = expected[object.oid], size == object.size else { throw LFSError.invalidObject }
            guard let action = object.actions?["download"], let url = URL(string: action.href) else { throw LFSError.missingObject }
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue("Gitling", forHTTPHeaderField: "User-Agent")
            for (key, value) in action.header ?? [:] { request.setValue(value, forHTTPHeaderField: key) }
            let base = completedBytes, completed = result.count, total = pointers.count, byteTotal = totalBytes
            let data = try streamingData(for: request, session: session, maximumBytes: size) { received in
                progress.report(.largeFiles, completed: completed, total: total, bytes: base + received, byteTotal: byteTotal)
            }
            guard data.count == size, sha256(data) == object.oid else { throw LFSError.invalidObject }
            result[object.oid] = data
            completedBytes += data.count
            progress.report(.largeFiles, completed: result.count, total: total, bytes: completedBytes, byteTotal: totalBytes)
        }
        return result
    }

    /// Per-task delegates preserve the caller's session configuration (including
    /// test protocols) and report bytes as they arrive, rather than after completion.
    private static func streamingData(for request: URLRequest, session: URLSession, maximumBytes: Int,
                                      received: @escaping @Sendable (Int) -> Void) throws -> Data {
        let delegate = DownloadDelegate(maximumBytes: maximumBytes, received: received)
        let task = session.dataTask(with: request)
        task.delegate = delegate
        task.resume()
        delegate.done.wait()
        do { return try delegate.value().get() }
        catch let error as LFSError { throw error }
        catch { throw LFSError.server }
    }

    private final class DownloadDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        let done = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private let maximumBytes: Int
        private let received: @Sendable (Int) -> Void
        private var bytes = Data()
        private var failure: Error?
        private var result: Result<Data, Error>?
        init(maximumBytes: Int, received: @escaping @Sendable (Int) -> Void) {
            self.maximumBytes = maximumBytes; self.received = received
        }
        func value() -> Result<Data, Error> { lock.withLock { result ?? .failure(LFSError.server) } }
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            let error: LFSError?
            if let http = response as? HTTPURLResponse {
                if http.statusCode == 401 || http.statusCode == 403 { error = .unauthorized }
                else if !(200..<300).contains(http.statusCode) { error = .server }
                else if response.expectedContentLength > Int64(maximumBytes) { error = .invalidObject }
                else { error = nil }
            } else { error = .server }
            lock.withLock { failure = error }
            completionHandler(error == nil ? .allow : .cancel)
        }
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            let count: Int? = lock.withLock {
                guard failure == nil, result == nil else { return nil }
                guard data.count <= maximumBytes - bytes.count else { failure = LFSError.invalidObject; return nil }
                bytes.append(data); return bytes.count
            }
            if let count { received(count) } else { dataTask.cancel() }
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            lock.withLock {
                if let failure = failure ?? error { result = .failure(failure) }
                else { result = .success(bytes) }
            }
            done.signal()
        }
    }

    private static func uploadObjects(
        _ objects: [String: Data],
        remoteURL: String,
        auth: LFSAuth?,
        session: URLSession
    ) throws {
        let endpoint = try endpoint(remoteURL: remoteURL, instanceBaseURL: auth?.instanceBaseURL)
        let pointers = objects.map { LFSPointer.make(oid: $0.key, size: $0.value.count) }
        let response = try batch(operation: "upload", pointers: pointers, endpoint: endpoint, auth: auth, session: session)
        for object in response.objects {
            if object.error != nil { throw LFSError.server }
            guard let action = object.actions?["upload"],
                  let url = URL(string: action.href),
                  let fileData = objects[object.oid] else {
                throw LFSError.missingObject
            }
            var request = URLRequest(url: url)
            request.httpMethod = "PUT"
            request.httpBody = fileData
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            request.setValue("Gitling", forHTTPHeaderField: "User-Agent")
            for (key, value) in action.header ?? [:] {
                request.setValue(value, forHTTPHeaderField: key)
            }
            _ = try data(for: request, session: session)
            if let verify = object.actions?["verify"], let verifyURL = URL(string: verify.href) {
                var verifyRequest = URLRequest(url: verifyURL)
                verifyRequest.httpMethod = "POST"
                verifyRequest.httpBody = try JSONEncoder().encode(
                    ActionBody(oid: object.oid, size: fileData.count)
                )
                verifyRequest.setValue("application/vnd.git-lfs+json", forHTTPHeaderField: "Content-Type")
                verifyRequest.setValue("application/vnd.git-lfs+json", forHTTPHeaderField: "Accept")
                for (key, value) in verify.header ?? [:] {
                    verifyRequest.setValue(value, forHTTPHeaderField: key)
                }
                _ = try data(for: verifyRequest, session: session)
            }
        }
    }

    private static func batch(
        operation: String,
        pointers: [LFSPointer],
        endpoint: URL,
        auth: LFSAuth?,
        session: URLSession
    ) throws -> LFSBatchResponse {
        let url = endpoint.appendingPathComponent("objects/batch")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/vnd.git-lfs+json", forHTTPHeaderField: "Accept")
        request.setValue("application/vnd.git-lfs+json", forHTTPHeaderField: "Content-Type")
        request.setValue("Gitling", forHTTPHeaderField: "User-Agent")
        if let auth {
            let basic = Data("\(auth.username):\(auth.secret)".utf8).base64EncodedString()
            request.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")
        }
        let body = BatchRequest(
            operation: operation,
            objects: pointers.map { RequestObject(oid: $0.oid, size: $0.size) }
        )
        request.httpBody = try JSONEncoder().encode(body)
        let data = try data(for: request, session: session)
        return try JSONDecoder().decode(LFSBatchResponse.self, from: data)
    }

    private static func data(for request: URLRequest, session: URLSession) throws -> Data {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<(Data, HTTPURLResponse), Error>?
        session.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error {
                result = .failure(error)
            } else if let http = response as? HTTPURLResponse,
                      let data,
                      (200..<300).contains(http.statusCode) {
                result = .success((data, http))
            } else {
                result = .failure(LFSError.server)
            }
        }.resume()
        semaphore.wait()
        switch result {
        case .success(let (data, _)):
            return data
        case .failure(let error):
            if let lfs = error as? LFSError { throw lfs }
            throw LFSError.server
        case .none:
            throw LFSError.server
        }
    }

    private static func worktreeFiles(at repoURL: URL) -> [String] {
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: repoURL,
            includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants]
        ) else { return [] }
        var result: [String] = []
        for case let url as URL in enumerator {
            if url.lastPathComponent == ".git" { enumerator.skipDescendants(); continue }
            guard (try? url.resourceValues(forKeys: Set(keys)).isRegularFile) == true else { continue }
            result.append(String(url.path.dropFirst(repoURL.path.count + 1)))
        }
        return result
    }

    private static func lfsPatterns(at repoURL: URL, paths: Set<String>? = nil) -> [String] {
        var attributeFiles: Set<URL> = []
        if let paths {
            for path in paths {
                var directory = repoURL.appendingPathComponent(path).deletingLastPathComponent()
                while directory.path == repoURL.path || directory.path.hasPrefix(repoURL.path + "/") {
                    attributeFiles.insert(directory.appendingPathComponent(".gitattributes"))
                    if directory.path == repoURL.path { break }
                    directory.deleteLastPathComponent()
                }
            }
        } else if let enumerator = FileManager.default.enumerator(at: repoURL, includingPropertiesForKeys: nil, options: [.skipsPackageDescendants]) {
            for case let url as URL in enumerator {
                if url.lastPathComponent == ".git" { enumerator.skipDescendants(); continue }
                if url.lastPathComponent == ".gitattributes" { attributeFiles.insert(url) }
            }
        }
        var patterns: [String] = []
        for url in attributeFiles {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let base = String(
                url.deletingLastPathComponent().path.dropFirst(repoURL.path.count + 1)
            )
            for line in text.split(whereSeparator: \.isNewline) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
                let fields = trimmed.split(whereSeparator: \.isWhitespace)
                guard fields.count >= 2,
                      fields.dropFirst().contains(where: { $0 == "filter=lfs" }) else { continue }
                var pattern = String(fields[0])
                if !base.isEmpty, !pattern.hasPrefix("/") {
                    pattern = base + "/" + pattern
                }
                patterns.append(pattern)
            }
        }
        return patterns
    }

    private static func matches(pattern: String, path: String) -> Bool {
        var pattern = pattern
        if pattern.hasPrefix("/") { pattern.removeFirst() }
        if !pattern.contains("/") {
            pattern = "**/" + pattern
        }
        var regex = "^"
        var index = pattern.startIndex
        while index < pattern.endIndex {
            let character = pattern[index]
            if character == "*" {
                let next = pattern.index(after: index)
                if next < pattern.endIndex, pattern[next] == "*" {
                    let afterStars = pattern.index(after: next)
                    if afterStars < pattern.endIndex, pattern[afterStars] == "/" {
                        // **/ matches zero directories as well as nested directories.
                        regex += "(?:.*/)?"
                        index = pattern.index(after: afterStars)
                    } else {
                        regex += ".*"
                        index = afterStars
                    }
                    continue
                }
                regex += "[^/]*"
            } else if character == "?" {
                regex += "[^/]"
            } else if "\\.^$|()[]{}+".contains(character) {
                regex += "\\\(character)"
            } else {
                regex += String(character)
            }
            index = pattern.index(after: index)
        }
        regex += "$"
        return path.range(of: regex, options: .regularExpression) != nil
    }

    private static func manifestURL(_ repoURL: URL, gitDirectory: URL?) -> URL {
        (gitDirectory ?? repoURL.appendingPathComponent(".git")).appendingPathComponent(manifestName)
    }

    private static func loadManifest(at repoURL: URL, gitDirectory: URL?) -> [String: LFSPointer] {
        guard let data = try? Data(contentsOf: manifestURL(repoURL, gitDirectory: gitDirectory)),
              let decoded = try? JSONDecoder().decode([String: LFSPointer].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private static func saveManifest(_ pointers: [String: LFSPointer], at repoURL: URL, gitDirectory: URL?) throws {
        let data = try JSONEncoder().encode(pointers)
        try data.write(to: manifestURL(repoURL, gitDirectory: gitDirectory), options: .atomic)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
