import Foundation

struct TagInfo: Identifiable, Sendable {
    var id: String { name }
    let name: String
    let referenceOID: String
    let annotated: Bool
    let problem: String?
}

struct TagDetail: Sendable {
    let tag: TagInfo
    let targetOID: String
    let targetType: String
    let tagger: String?
    let tagDate: Date?
    let message: String?
    let commit: CommitInfo?
    var canCheckout: Bool { targetType == "commit" }
}
