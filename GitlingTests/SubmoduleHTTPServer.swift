import Foundation
import Network
import Clibgit2
import CryptoKit
@testable import Gitling

/// A loopback-only smart HTTP fixture. It serves real libgit2-generated packs;
/// no shell, external server, credential store, or remote repository is needed.
final class SubmoduleHTTPServer {
    struct Repository {
        let head: String
        let pack: Data
        let authorization: String

        init(at url: URL, username: String, password: String) throws {
            var repo: OpaquePointer?, builder: OpaquePointer?, walk: OpaquePointer?
            guard git_repository_open(&repo, url.path) == 0 else { throw FixtureError.repository }
            defer { git_repository_free(repo) }
            guard git_packbuilder_new(&builder, repo) == 0 else { throw FixtureError.repository }
            defer { git_packbuilder_free(builder) }
            guard git_revwalk_new(&walk, repo) == 0 else { throw FixtureError.repository }
            defer { git_revwalk_free(walk) }
            guard git_revwalk_push_head(walk) == 0,
                  git_packbuilder_insert_walk(builder, walk) == 0 else { throw FixtureError.repository }
            var buffer = git_buf()
            defer { git_buf_dispose(&buffer) }
            guard git_packbuilder_write_buf(&buffer, builder) == 0, let pointer = buffer.ptr else {
                throw FixtureError.repository
            }
            pack = Data(bytes: pointer, count: buffer.size)
            head = try GitClient.history(at: url, limit: 1)[0].id
            authorization = "Basic " + Data("\(username):\(password)".utf8).base64EncodedString()
        }
    }

    enum FixtureError: Error { case repository, listener }
    private let queue = DispatchQueue(label: "GitlingTests.submodule-http")
    private let listener: NWListener
    private var repositories: [String: Repository] = [:]
    private var connections: [NWConnection] = []
    private struct LFSObject { var data: Data; var oid: String; var chunkSize: Int; var delay: Int }
    private var lfsObjects: [String: LFSObject] = [:]
    private var accepted = 0
    private var rejected = 0
    private(set) var port: UInt16 = 0
    var authority: String { "http://127.0.0.1:\(port)" }
    var counts: (accepted: Int, rejected: Int) { queue.sync { (accepted, rejected) } }

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
            if case .failed = state { ready.signal() }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.connections.append(connection)
            connection.start(queue: self.queue)
            self.receive(connection, bytes: Data())
            self.queue.asyncAfter(deadline: .now() + 10) { connection.cancel() }
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success, let bound = listener.port else {
            listener.cancel(); throw FixtureError.listener
        }
        port = bound.rawValue
    }

    func serve(_ repository: Repository, path: String = "/fixed_unit_queue.git") {
        queue.sync { repositories[path] = repository }
    }

    func serveLFS(_ data: Data, path: String = "/fixed_unit_queue.git", chunkSize: Int = 32_768, delayMilliseconds: Int = 10) {
        queue.sync {
            lfsObjects[path] = LFSObject(data: data, oid: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                                        chunkSize: chunkSize, delay: delayMilliseconds)
        }
    }

    func stop() {
        queue.sync {
            listener.cancel()
            connections.forEach { $0.cancel() }
            connections.removeAll()
        }
    }

    private func receive(_ connection: NWConnection, bytes: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            var bytes = bytes
            if let data { bytes.append(data) }
            guard bytes.count <= 4 * 1024 * 1024, error == nil else { connection.cancel(); return }
            if let end = bytes.range(of: Data("\r\n\r\n".utf8)),
               let header = String(data: bytes[..<end.lowerBound], encoding: .utf8) {
                let lines = header.components(separatedBy: "\r\n")
                let length = lines.dropFirst().first { $0.lowercased().hasPrefix("content-length:") }
                    .flatMap { Int($0.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces)) } ?? 0
                if bytes.count >= end.upperBound + length {
                    self.respond(connection, lines: lines); return
                }
            }
            if complete { connection.cancel() }
            else { self.receive(connection, bytes: bytes) }
        }
    }

    private func respond(_ connection: NWConnection, lines: [String]) {
        let request = lines[0].split(separator: " ")
        guard request.count >= 2 else { connection.cancel(); return }
        let method = String(request[0]), path = String(request[1]).components(separatedBy: "?")[0]
        let lfsSuffix = "/info/lfs/objects/batch"
        if method == "POST", path.hasSuffix(lfsSuffix),
           let object = lfsObjects[String(path.dropLast(lfsSuffix.count))],
           let repository = repositories[String(path.dropLast(lfsSuffix.count))] {
            let authorization = lines.first { $0.lowercased().hasPrefix("authorization:") }
                .map { String($0.dropFirst("authorization:".count)).trimmingCharacters(in: .whitespaces) }
            guard authorization == repository.authorization else {
                send(connection, status: "401 Unauthorized", type: "text/plain", body: Data()); return
            }
            let body = try! JSONSerialization.data(withJSONObject: ["objects": [["oid": object.oid, "size": object.data.count,
                "actions": ["download": ["href": authority + "/lfs-fixture/" + object.oid,
                                         "header": ["Authorization": repository.authorization]]]]]])
            send(connection, status: "200 OK", type: "application/vnd.git-lfs+json", body: body); return
        }
        if method == "GET", path.hasPrefix("/lfs-fixture/"),
           let entry = lfsObjects.first(where: { path.hasSuffix($0.value.oid) }), let repository = repositories[entry.key] {
            let authorization = lines.first { $0.lowercased().hasPrefix("authorization:") }
                .map { String($0.dropFirst("authorization:".count)).trimmingCharacters(in: .whitespaces) }
            guard authorization == repository.authorization else { send(connection, status: "401 Unauthorized", type: "text/plain", body: Data()); return }
            let object = entry.value
            let header = "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: \(object.data.count)\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(header.utf8), completion: .contentProcessed { [weak self] _ in self?.sendLFS(connection, object: object, offset: 0) })
            return
        }
        let suffix = method == "GET" ? "/info/refs" : "/git-upload-pack"
        guard path.hasSuffix(suffix), let repo = repositories[String(path.dropLast(suffix.count))] else {
            send(connection, status: "404 Not Found", type: "text/plain", body: Data()); return
        }
        let authorization = lines.first { $0.lowercased().hasPrefix("authorization:") }
            .map { String($0.dropFirst("authorization:".count)).trimmingCharacters(in: .whitespaces) }
        guard authorization == repo.authorization else {
            rejected += 1
            send(connection, status: "401 Unauthorized", type: "text/plain", body: Data("Sign-in required\n".utf8),
                 extra: "WWW-Authenticate: Basic realm=\"offline-fixture\"\r\n"); return
        }
        accepted += 1
        if method == "GET" {
            // No side-band or thin-pack capability: the POST reply is a raw pack.
            let body = packet("# service=git-upload-pack\n") + Data("0000".utf8)
                + packet(repo.head + " HEAD\0ofs-delta symref=HEAD:refs/heads/main\n")
                + packet(repo.head + " refs/heads/main\n") + Data("0000".utf8)
            send(connection, status: "200 OK", type: "application/x-git-upload-pack-advertisement", body: body)
        } else {
            send(connection, status: "200 OK", type: "application/x-git-upload-pack-result",
                 body: packet("NAK\n") + repo.pack)
        }
    }

    private func sendLFS(_ connection: NWConnection, object: LFSObject, offset: Int) {
        let end = min(object.data.count, offset + object.chunkSize)
        let final = end == object.data.count
        connection.send(content: object.data.subdata(in: offset..<end), contentContext: final ? .finalMessage : .defaultMessage,
                        isComplete: true, completion: .contentProcessed { [weak self] error in
            guard let self, error == nil, !final else { return }
            self.queue.asyncAfter(deadline: .now() + .milliseconds(object.delay)) {
                self.sendLFS(connection, object: object, offset: end)
            }
        })
    }

    private func packet(_ string: String) -> Data {
        let body = Data(string.utf8)
        return Data(String(format: "%04x", body.count + 4).utf8) + body
    }

    private func send(_ connection: NWConnection, status: String, type: String, body: Data, extra: String = "") {
        let header = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\(extra)\r\n"
        connection.send(content: Data(header.utf8) + body, contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { _ in })
    }
}
