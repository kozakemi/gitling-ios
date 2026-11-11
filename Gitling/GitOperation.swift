import Foundation

// Native Git state and conflict stages are the source of truth after relaunch.
enum GitOperationKind: String, Codable, Sendable {
    case merge, rebase, cherryPick
    var title: String {
        switch self {
        case .merge: String(localized: "Merge in progress")
        case .rebase: String(localized: "Rebase in progress")
        case .cherryPick: String(localized: "Cherry-pick in progress")
        }
    }
}

struct ConflictVersion: Equatable, Sendable {
    var oid: String
    var mode: UInt32
}

struct ConflictFile: Identifiable, Equatable, Sendable {
    var path: String
    var ancestor: ConflictVersion?
    var ours: ConflictVersion?
    var theirs: ConflictVersion?
    var id: String { path }
}

struct GitOperationSnapshot: Sendable {
    var kind: GitOperationKind?
    var conflicts: [ConflictFile]
    var canContinue: Bool
    var canAbort: Bool
    var isExternal = false
    var step: Int?
    var total: Int?
    var needsAttention: Bool { kind != nil || !conflicts.isEmpty }
}

struct ConflictPreview: Sendable {
    var text: String?
    var byteCount: Int
    var oid: String?
}

struct ConflictEdit: Sendable {
    var conflict: ConflictFile
    var digest: String
    var contents: Data
}

// Written before a mutating operation. A planned commit is durable before HEAD
// advances, allowing recovery between object creation, ref update and cleanup.
struct GitOperationJournal: Codable {
    var kind: GitOperationKind
    var originalHead: String
    var reference: String
    var target: String
    var plannedCommit: String?
}
