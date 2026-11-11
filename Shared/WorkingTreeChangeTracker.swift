import Foundation

/// Anchors refer to immutable snapshots, rather than the last directory enumeration.
/// After eviction or an extension restart, expire the anchor so Files does a full scan.
final class WorkingTreeChangeTracker {
    enum Failure: Error { case expiredAnchor }

    struct Changes {
        var removed: Set<String>
        var anchor: Data
        var hasChanges: Bool
    }

    private struct Snapshot {
        var container: String
        var identifiers: Set<String>
    }

    private let session = UUID().uuidString
    private let lock = NSLock()
    private var snapshots: [Data: Snapshot] = [:]
    private var order: [Data] = []
    private let capacity: Int

    init(capacity: Int = 128) { self.capacity = max(1, capacity) }

    func record(container: String, nodes: [WorkingTree.Node]) -> Data {
        lock.lock()
        defer { lock.unlock() }
        return recordUnlocked(container: container, nodes: nodes)
    }

    func changes(container: String, nodes: [WorkingTree.Node], from anchor: Data) throws -> Changes {
        lock.lock()
        defer { lock.unlock() }
        guard let previous = snapshots[anchor], previous.container == container else {
            throw Failure.expiredAnchor
        }
        let current = identifiers(nodes)
        let next = recordUnlocked(container: container, nodes: nodes)
        return Changes(removed: previous.identifiers.subtracting(current), anchor: next, hasChanges: next != anchor)
    }

    private func identifiers(_ nodes: [WorkingTree.Node]) -> Set<String> {
        Set(nodes.map { WorkingTree.identifier(repo: $0.repoName, relative: $0.relative) })
    }

    private func recordUnlocked(container: String, nodes: [WorkingTree.Node]) -> Data {
        var value: UInt64 = 1469598103934665603
        func mix(_ text: String) {
            for byte in text.utf8 {
                value ^= UInt64(byte)
                value = value &* 1099511628211
            }
            value ^= 0
            value = value &* 1099511628211
        }
        mix(container)
        for node in nodes.sorted(by: { $0.relative < $1.relative }) {
            mix(WorkingTree.identifier(repo: node.repoName, relative: node.relative))
            mix("\(node.modified?.timeIntervalSince1970 ?? 0):\(node.fileSize ?? 0)")
        }
        let anchor = Data("\(session):\(value)".utf8)
        if snapshots[anchor] == nil {
            snapshots[anchor] = Snapshot(container: container, identifiers: identifiers(nodes))
            order.append(anchor)
            if order.count > capacity { snapshots.removeValue(forKey: order.removeFirst()) }
        }
        return anchor
    }
}
