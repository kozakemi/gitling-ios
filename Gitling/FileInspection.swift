import Foundation

/// Read-only limits shared by file history, historical blobs, blame, and highlighting.
enum FileInspection {
    /// Same ceiling as worktree preview. Larger files are reported and not loaded as text.
    static let maximumBytes = 256 * 1024
}

/// Budget for the pre-walk that picks the `oldest_commit` libgit2 blame stops at.
/// Both values bound an estimate of what blame visits; neither is a hard cap on peak
/// memory, CPU, or time, and spans at the cut are marked `historyLimited`.
struct BlameLimits: Sendable {
    /// First-parent commits visited, including HEAD.
    var commits: Int
    /// Logical (uncompressed) blob bytes from object headers: every followed path's version at
    /// each visited commit, plus every added and deleted blob of a changed step, which rename
    /// detection may compare. Pack delta bases, trees, commits, and diff state are not counted,
    /// and the pre-walk's own rename detection reads the same candidates again.
    var bytes: Int

    static let standard = BlameLimits(commits: 5_000, bytes: 64 * 1024 * 1024)
}

enum FileChangeKind: String, Hashable, Sendable {
    case added, modified, deleted, renamed
}

struct FileHistoryEntry: Identifiable, Hashable, Sendable {
    var commit: CommitInfo
    /// Path of the file in `commit`, which can differ after a rename is followed.
    var path: String
    var kind: FileChangeKind
    var previousPath: String?
    var id: String { commit.id }
}

enum FileBlobState: Equatable, Sendable {
    case text(String)
    case missing
    case binary
    case tooLarge
    case notUTF8
    case symlink(String)
    case gitlink(String)
    case directory
    case missingObject
}

struct BlameSpan: Identifiable, Hashable, Sendable {
    var commitID: String?
    var summary: String
    var author: String
    var date: Date?
    var startLine: Int
    var lineCount: Int
    var lines: [String]
    /// Path this hunk came from, when blame followed a rename.
    var originPath: String
    /// The walk stopped at this commit for a resource limit, so these lines may be older.
    var historyLimited = false
    var id: String { "\(commitID ?? "worktree")#\(startLine)" }

    var commit: CommitInfo? {
        guard let commitID else { return nil }
        return CommitInfo(id: commitID, summary: summary, author: author, date: date ?? .distantPast)
    }
}

/// Serial, de-duplicated runner for blame jobs.
///
/// `git_blame_file` is one synchronous libgit2 call with no cancellation or progress
/// callback, so a cancelled request never interrupts it. The waiting caller returns at
/// once, the job token is cancelled when its last waiter leaves, and the job stops at
/// its next check outside libgit2. A job already inside libgit2 runs to completion and
/// its result is dropped. Only one job runs at a time; requests for the same key share
/// a live job, and a job without waiters is skipped without work when its turn comes.
///
/// `jobs` and every `Job` are read and written only while holding `lock`, so `Job` never
/// leaves it. The worker receives only the job's token, which is itself thread-safe, and
/// finds its job again by token identity.
final class BlameQueue: @unchecked Sendable {
    static let shared = BlameQueue()

    struct Key: Hashable, Sendable {
        var repo: String
        var path: String
        var revision: Int
    }

    typealias Work = @Sendable (SearchCancellation) throws -> [BlameSpan]

    private final class Job {
        let token = SearchCancellation()
        var waiters: [UUID: CheckedContinuation<[BlameSpan], Error>] = [:]
    }

    private let lock = NSLock()
    private let worker = DispatchQueue(label: "Gitling.blame", qos: .userInitiated)
    private var jobs: [Key: Job] = [:]

    func run(_ key: Key, work: @escaping Work) async throws -> [BlameSpan] {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                guard !Task.isCancelled else {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if let job = jobs[key] {
                    job.waiters[id] = continuation
                    lock.unlock()
                    return
                }
                let job = Job()
                job.waiters[id] = continuation
                jobs[key] = job
                let token = job.token
                lock.unlock()
                worker.async { self.execute(key, token, work) }
            }
        } onCancel: {
            leave(key, id)
        }
    }

    func waiterCount(_ key: Key) -> Int {
        lock.lock(); defer { lock.unlock() }
        return jobs[key]?.waiters.count ?? 0
    }

    private func leave(_ key: Key, _ id: UUID) {
        lock.lock()
        guard let job = jobs[key], let waiter = job.waiters.removeValue(forKey: id) else {
            lock.unlock()
            return
        }
        if job.waiters.isEmpty {
            job.token.cancel()
            jobs[key] = nil
        }
        lock.unlock()
        waiter.resume(throwing: CancellationError())
    }

    private func execute(_ key: Key, _ token: SearchCancellation, _ work: Work) {
        let result = Result {
            try token.check()
            return try work(token)
        }
        lock.lock()
        // A job leaves `jobs` only here or in `leave` once it has no waiters, so a missing
        // or replaced entry means nobody is waiting for this result.
        var waiters: [CheckedContinuation<[BlameSpan], Error>] = []
        if let job = jobs[key], job.token === token {
            jobs[key] = nil
            waiters = Array(job.waiters.values)
            job.waiters.removeAll()
        }
        lock.unlock()
        for waiter in waiters { waiter.resume(with: result) }
    }
}

struct SyntaxSpan: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case keyword, string, comment, number
    }

    var location: Int
    var length: Int
    var kind: Kind
}

/// Linear scan for a few common languages. Unknown types and files over the preview limit stay plain.
enum SyntaxHighlighter {
    static func spans(in text: String, path: String) -> [SyntaxSpan] {
        guard text.utf8.count <= FileInspection.maximumBytes, let language = Language.match(path) else { return [] }
        let source = text as NSString
        let length = source.length
        var spans: [SyntaxSpan] = []
        var index = 0
        while index < length {
            let character = source.character(at: index)
            if character == 32 || character == 9 || character == 10 || character == 13 {
                index += 1
                continue
            }
            if let marker = language.lineComment, hasPrefix(source, index, marker) {
                let end = lineEnd(source, index)
                append(SyntaxSpan(location: index, length: end - index, kind: .comment), to: &spans)
                index = end
                continue
            }
            if let start = language.blockStart, let finish = language.blockEnd, hasPrefix(source, index, start) {
                let from = index + (start as NSString).length
                let found = source.range(of: finish, range: NSRange(location: from, length: length - from))
                let end = found.location == NSNotFound ? length : found.location + found.length
                append(SyntaxSpan(location: index, length: end - index, kind: .comment), to: &spans)
                index = end
                continue
            }
            if character == 34 || character == 39 {
                let triple = language.tripleQuotes && index + 2 < length
                    && source.character(at: index + 1) == character && source.character(at: index + 2) == character
                let end = stringEnd(source, index, quote: character, triple: triple)
                append(SyntaxSpan(location: index, length: end - index, kind: .string), to: &spans)
                index = end
                continue
            }
            if isDigit(character) {
                let end = scan(source, index, while: { isDigit($0) || $0 == 46 || $0 == 120 || $0 == 88 || ($0 >= 65 && $0 <= 70) || ($0 >= 97 && $0 <= 102) })
                append(SyntaxSpan(location: index, length: end - index, kind: .number), to: &spans)
                index = end
                continue
            }
            if isIdentifierStart(character) {
                let end = scan(source, index + 1, while: isIdentifier)
                let word = source.substring(with: NSRange(location: index, length: end - index))
                let key = language.caseInsensitive ? word.lowercased() : word
                if language.keywords.contains(key) {
                    append(SyntaxSpan(location: index, length: end - index, kind: .keyword), to: &spans)
                }
                index = end
                continue
            }
            index += 1
        }
        return spans
    }

    private static func append(_ span: SyntaxSpan, to spans: inout [SyntaxSpan]) {
        guard span.length > 0 else { return }
        spans.append(span)
    }

    private static func hasPrefix(_ source: NSString, _ index: Int, _ prefix: String) -> Bool {
        let token = prefix as NSString
        guard index + token.length <= source.length else { return false }
        return source.substring(with: NSRange(location: index, length: token.length)) == prefix
    }

    private static func lineEnd(_ source: NSString, _ index: Int) -> Int {
        let found = source.range(of: "\n", range: NSRange(location: index, length: source.length - index))
        return found.location == NSNotFound ? source.length : found.location
    }

    private static func stringEnd(_ source: NSString, _ index: Int, quote: unichar, triple: Bool) -> Int {
        var cursor = index + (triple ? 3 : 1)
        while cursor < source.length {
            let character = source.character(at: cursor)
            if character == 92, cursor + 1 < source.length {
                cursor += 2
                continue
            }
            if triple {
                if character == quote, cursor + 2 < source.length,
                   source.character(at: cursor + 1) == quote, source.character(at: cursor + 2) == quote {
                    return cursor + 3
                }
            } else if character == quote {
                return cursor + 1
            } else if character == 10 {
                return cursor
            }
            cursor += 1
        }
        return source.length
    }

    private static func scan(_ source: NSString, _ index: Int, while include: (unichar) -> Bool) -> Int {
        var cursor = index
        while cursor < source.length, include(source.character(at: cursor)) { cursor += 1 }
        return cursor
    }

    private static func isDigit(_ character: unichar) -> Bool { character >= 48 && character <= 57 }
    private static func isIdentifierStart(_ character: unichar) -> Bool {
        character == 95 || (character >= 65 && character <= 90) || (character >= 97 && character <= 122)
    }
    private static func isIdentifier(_ character: unichar) -> Bool { isIdentifierStart(character) || isDigit(character) }

    private struct Language {
        var lineComment: String?
        var blockStart: String?
        var blockEnd: String?
        var keywords: Set<String>
        var caseInsensitive = false
        var tripleQuotes = false

        static func match(_ path: String) -> Language? {
            switch (path as NSString).pathExtension.lowercased() {
            case "swift": return cFamily(swiftKeywords)
            case "kt", "kts": return cFamily(kotlinKeywords)
            case "java": return cFamily(javaKeywords)
            case "js", "jsx", "ts", "tsx": return cFamily(scriptKeywords)
            case "go": return cFamily(goKeywords)
            case "rs": return cFamily(rustKeywords)
            case "c", "h", "hh", "hpp", "cc", "cpp", "m", "mm", "cs": return cFamily(cKeywords)
            case "php": return cFamily(phpKeywords)
            case "py": return Language(lineComment: "#", blockStart: nil, blockEnd: nil, keywords: pythonKeywords, tripleQuotes: true)
            case "sh", "bash", "zsh": return Language(lineComment: "#", blockStart: nil, blockEnd: nil, keywords: shellKeywords)
            case "rb": return Language(lineComment: "#", blockStart: nil, blockEnd: nil, keywords: rubyKeywords)
            case "yml", "yaml": return Language(lineComment: "#", blockStart: nil, blockEnd: nil, keywords: [])
            case "sql": return Language(lineComment: "--", blockStart: "/*", blockEnd: "*/", keywords: sqlKeywords, caseInsensitive: true)
            case "html", "htm", "xml", "svg": return Language(lineComment: nil, blockStart: "<!--", blockEnd: "-->", keywords: [])
            case "css": return Language(lineComment: nil, blockStart: "/*", blockEnd: "*/", keywords: [])
            case "json": return Language(lineComment: nil, blockStart: nil, blockEnd: nil, keywords: ["true", "false", "null"])
            default: return nil
            }
        }

        private static func cFamily(_ keywords: Set<String>) -> Language {
            Language(lineComment: "//", blockStart: "/*", blockEnd: "*/", keywords: keywords)
        }
    }
}

private let cKeywords: Set<String> = ["if", "else", "for", "while", "do", "switch", "case", "break", "continue", "return", "struct", "enum", "typedef", "const", "static", "sizeof", "void", "int", "char", "long", "short", "float", "double", "unsigned", "signed", "goto", "default"]
private let swiftKeywords: Set<String> = ["associatedtype", "class", "deinit", "enum", "extension", "func", "import", "init", "inout", "internal", "let", "operator", "private", "protocol", "public", "static", "struct", "subscript", "typealias", "var", "break", "case", "continue", "default", "defer", "do", "else", "fallthrough", "for", "guard", "if", "in", "repeat", "return", "switch", "where", "while", "as", "catch", "false", "is", "nil", "throw", "throws", "true", "try"]
private let kotlinKeywords: Set<String> = ["class", "fun", "val", "var", "if", "else", "when", "for", "while", "return", "object", "interface", "package", "import", "true", "false", "null", "this", "super", "in", "is", "as", "try", "catch", "finally", "throw"]
private let javaKeywords: Set<String> = ["class", "interface", "enum", "extends", "implements", "if", "else", "for", "while", "return", "new", "package", "import", "public", "private", "protected", "static", "final", "void", "true", "false", "null", "try", "catch", "throw", "throws"]
private let scriptKeywords: Set<String> = ["class", "function", "const", "let", "var", "if", "else", "for", "while", "return", "import", "export", "from", "new", "this", "true", "false", "null", "undefined", "async", "await", "try", "catch", "throw", "typeof", "interface", "type"]
private let goKeywords: Set<String> = ["func", "package", "import", "var", "const", "type", "struct", "interface", "if", "else", "for", "range", "return", "switch", "case", "go", "defer", "map", "chan", "true", "false", "nil"]
private let rustKeywords: Set<String> = ["fn", "let", "mut", "struct", "enum", "impl", "trait", "if", "else", "for", "while", "loop", "return", "match", "use", "mod", "pub", "crate", "self", "super", "true", "false", "as", "in", "where"]
private let phpKeywords: Set<String> = ["function", "class", "if", "else", "elseif", "foreach", "for", "while", "return", "public", "private", "protected", "static", "new", "echo", "namespace", "use", "true", "false", "null"]
private let pythonKeywords: Set<String> = ["def", "class", "if", "elif", "else", "for", "while", "return", "import", "from", "as", "with", "try", "except", "finally", "raise", "lambda", "pass", "break", "continue", "True", "False", "None", "and", "or", "not", "in", "is", "yield", "async", "await"]
private let shellKeywords: Set<String> = ["if", "then", "else", "elif", "fi", "for", "while", "do", "done", "case", "esac", "in", "function", "return", "local"]
private let rubyKeywords: Set<String> = ["def", "class", "module", "if", "elsif", "else", "unless", "end", "do", "while", "until", "for", "return", "yield", "begin", "rescue", "ensure", "true", "false", "nil", "self"]
private let sqlKeywords: Set<String> = ["select", "from", "where", "and", "or", "insert", "into", "values", "update", "set", "delete", "create", "table", "join", "left", "right", "inner", "on", "as", "null", "not", "in", "order", "by", "group", "limit"]
