// Gitling/CommitComparison.swift
import Foundation

// MARK: - Fixed endpoints

/// A commit endpoint resolved once to a full object ID.
///
/// `input` is kept only for display. Every later read uses `oid`, so a branch or tag
/// that moves after selection cannot silently change an already chosen comparison.
struct ComparisonEndpoint: Identifiable, Hashable, Sendable {
    enum Source: String, Hashable, Sendable {
        case head
        case localBranch
        case remoteBranch
        case tag
        case oidPrefix
    }

    /// Full 40-character commit object ID.
    let oid: String
    /// The exact text the user chose: `main`, `v1.0`, `HEAD`, or an OID prefix.
    let input: String
    /// How `input` was interpreted.
    let source: Source
    let summary: String
    let author: String
    let date: Date

    var id: String { oid }
    var shortOID: String { String(oid.prefix(7)) }

    init(oid: String, input: String, source: Source, summary: String, author: String, date: Date) {
        self.oid = oid
        self.input = input
        self.source = source
        self.summary = summary
        self.author = author
        self.date = date
    }
}

/// A base-to-target comparison between two fixed commit OIDs.
struct CommitComparison: Identifiable, Hashable, Sendable {
    let base: ComparisonEndpoint
    let target: ComparisonEndpoint

    var id: String { base.oid + ".." + target.oid }
    var isSameCommit: Bool { base.oid == target.oid }

    func swapped() -> CommitComparison {
        CommitComparison(base: target, target: base)
    }
}

/// One selectable endpoint for the comparison UI.
///
/// For annotated tags `targetOID` is the tag object, not the peeled commit; resolving
/// the endpoint performs the bounded peel. `isCurrent` is meaningful for local branches.
struct ComparisonReference: Identifiable, Hashable, Sendable {
    enum Kind: String, Hashable, Sendable {
        case head
        case localBranch
        case remoteBranch
        case tag
    }

    let name: String
    /// Full ref name (`refs/heads/main`, `refs/remotes/origin/main`, `refs/tags/v1`), or `HEAD`.
    let reference: String
    let kind: Kind
    let targetOID: String?
    let annotated: Bool
    let isCurrent: Bool

    var id: String { reference }

    init(name: String,
         reference: String,
         kind: Kind,
         targetOID: String?,
         annotated: Bool = false,
         isCurrent: Bool = false) {
        self.name = name
        self.reference = reference
        self.kind = kind
        self.targetOID = targetOID
        self.annotated = annotated
        self.isCurrent = isCurrent
    }
}

// MARK: - Budgets

/// Budgets for the next comparison rounds.
///
/// These are deliberately conservative defaults, not proven performance guarantees.
/// Tree metadata, pack deltas, and libgit2 internals still have their own memory/CPU
/// costs; callers must report every limit reached instead of showing an empty result.
struct ComparisonLimits: Hashable, Sendable {
    /// Maximum changed-file entries returned by one comparison.
    var maximumFiles: Int
    /// Blob-side ceiling before text is loaded; larger objects stay metadata-only.
    var maximumBlobBytes: Int
    /// UTF-8 byte budget for one generated patch; the result marks truncation.
    var maximumPatchBytes: Int
    /// Estimated blob bytes rename detection may compare; over budget disables renames.
    var maximumRenameCandidates: Int
    var maximumRenameBytes: Int
    /// Annotated tag objects followed before rejecting a chain.
    var maximumTagPeelDepth: Int
    /// Object-header ceiling for each peeled tag and the final commit before loading.
    var maximumMetadataBytes: Int

    static let standard = ComparisonLimits()

    init(maximumFiles: Int = 5_000,
         maximumBlobBytes: Int = FileInspection.maximumBytes,
         maximumPatchBytes: Int = 80 * 1024,
         maximumRenameBytes: Int = 64 * 1024 * 1024,
         maximumRenameCandidates: Int = 256,
         maximumTagPeelDepth: Int = 32,
         maximumMetadataBytes: Int = 1_048_576) {
        self.maximumFiles = maximumFiles
        self.maximumBlobBytes = maximumBlobBytes
        self.maximumPatchBytes = maximumPatchBytes
        self.maximumRenameCandidates = maximumRenameCandidates
        self.maximumRenameBytes = maximumRenameBytes
        self.maximumTagPeelDepth = maximumTagPeelDepth
        self.maximumMetadataBytes = maximumMetadataBytes
    }
}

// MARK: - File metadata

enum ComparisonChangeKind: String, Hashable, Sendable {
    case added
    case deleted
    case modified
    case renamed
    case typeChanged
    case modeChanged
    case other
}

enum ComparisonContentKind: String, Hashable, Sendable {
    case unknown
    case text
    case binary
    case symlink
    case gitlink
    case tooLarge
    case notUTF8
    case missing
    case directory
}

/// One changed path in a commit-tree comparison.
///
/// OIDs and sizes are optional because one side may be absent. Sizes come from the
/// object header when available; content kinds are provisional until a file diff is
/// loaded and may stay `.unknown`.
struct ComparisonFile: Identifiable, Hashable, Sendable {
    let baseOID: String
    let targetOID: String
    var change: ComparisonChangeKind
    var oldPath: String?
    var newPath: String?
    var oldMode: UInt32?
    var newMode: UInt32?
    var oldOID: String?
    var newOID: String?
    var oldSize: Int?
    var newSize: Int?
    var oldContent: ComparisonContentKind
    var newContent: ComparisonContentKind
    /// libgit2 rename similarity score (0...100), when applicable.
    var similarity: Int?

    var id: String { baseOID + "\u{0}" + targetOID + "\u{0}" + (oldPath ?? "") + "\u{0}" + (newPath ?? "") }

    var path: String { newPath ?? oldPath ?? "" }

    var displayPath: String {
        if let oldPath, let newPath, oldPath != newPath {
            return oldPath + " → " + newPath
        }
        return path
    }

    init(baseOID: String, targetOID: String, change: ComparisonChangeKind,
         oldPath: String? = nil,
         newPath: String? = nil,
         oldMode: UInt32? = nil,
         newMode: UInt32? = nil,
         oldOID: String? = nil,
         newOID: String? = nil,
         oldSize: Int? = nil,
         newSize: Int? = nil,
         oldContent: ComparisonContentKind = .unknown,
         newContent: ComparisonContentKind = .unknown,
         similarity: Int? = nil) {
        self.baseOID = baseOID
        self.targetOID = targetOID
        self.change = change
        self.oldPath = oldPath
        self.newPath = newPath
        self.oldMode = oldMode
        self.newMode = newMode
        self.oldOID = oldOID
        self.newOID = newOID
        self.oldSize = oldSize
        self.newSize = newSize
        self.oldContent = oldContent
        self.newContent = newContent
        self.similarity = similarity
    }
}

enum ComparisonLimitReason: String, Hashable, Sendable {
    /// The changed-file list reached `maximumFiles`.
    case fileCount
    /// Rename detection was disabled by `maximumRenameBytes`.
    case renameCandidates
}

struct ComparisonListResult: Hashable, Sendable {
    var files: [ComparisonFile]
    var truncated: Bool
    var limitsReached: Set<ComparisonLimitReason>
    var limits: ComparisonLimits

    init(files: [ComparisonFile] = [],
         truncated: Bool = false,
         limitsReached: Set<ComparisonLimitReason> = [],
         limits: ComparisonLimits = .standard) {
        self.files = files
        self.truncated = truncated
        self.limitsReached = limitsReached
        self.limits = limits
    }
}

// MARK: - Single-file diff result

struct ComparisonPatch: Hashable, Sendable {
    var text: String
    /// True when `text` stops before the complete patch because of `maximumPatchBytes`.
    var truncated: Bool
    var insertions: Int
    var deletions: Int

    init(text: String, truncated: Bool = false, insertions: Int = 0, deletions: Int = 0) {
        self.text = text
        self.truncated = truncated
        self.insertions = insertions
        self.deletions = deletions
    }
}

enum ComparisonDiffContent: Hashable, Sendable {
    case patch(ComparisonPatch)
    case binary
    case notUTF8
    /// Historical symlink targets only; neither target is followed.
    case symlink(oldTarget: String?, newTarget: String?)
    /// Submodule gitlink OIDs; no recursion and no checkout.
    case gitlink(oldOID: String?, newOID: String?)
    /// At least one blob exceeded `maximumBlobBytes`, so no content was loaded.
    case tooLarge(oldBytes: Int?, newBytes: Int?)
    case missingObject
    case directory
    case unchanged
}

struct ComparisonFileDiff: Identifiable, Hashable, Sendable {
    var file: ComparisonFile
    var content: ComparisonDiffContent

    var id: String { file.id }

    init(file: ComparisonFile, content: ComparisonDiffContent) {
        self.file = file
        self.content = content
    }
}
