import XCTest
@testable import Gitling

final class CommitGraphTests: XCTestCase {

    func testAdjacentRowsShareLaneEndpoints() {
        let commits = [
            CommitInfo(id: "f", summary: "merge", author: "", date: .now, parents: ["e", "d"]),
            CommitInfo(id: "e", summary: "main", author: "", date: .now, parents: ["b"]),
            CommitInfo(id: "d", summary: "feature", author: "", date: .now, parents: ["b"]),
            CommitInfo(id: "b", summary: "base", author: "", date: .now, parents: ["a"]),
            CommitInfo(id: "a", summary: "root", author: "", date: .now, parents: [])
        ]
        let rows = CommitGraph.rows(from: commits)
        for (above, below) in zip(rows, rows.dropFirst()) {
            let width = max(above.outgoing.count, below.incoming.count, above.columnCount)
            for lane in 0..<width {
                let outgoing = lane < above.outgoing.count ? above.outgoing[lane] : ""
                let incoming = lane < below.incoming.count ? below.incoming[lane] : ""
                XCTAssertEqual(
                    outgoing,
                    incoming,
                    "lane \(lane) must connect \(above.commit.id) to \(below.commit.id)"
                )
            }
        }
    }

    func testMergeKeepsTwoLanesUntilTheyJoin() {
        let commits = [
            CommitInfo(id: "d", summary: "merge", author: "", date: .now, parents: ["b", "c"]),
            CommitInfo(id: "c", summary: "side", author: "", date: .now, parents: ["a"]),
            CommitInfo(id: "b", summary: "main", author: "", date: .now, parents: ["a"]),
            CommitInfo(id: "a", summary: "root", author: "", date: .now, parents: [])
        ]
        let rows = CommitGraph.rows(from: commits)
        XCTAssertEqual(rows.map(\.commit.id), ["d", "c", "b", "a"])
        XCTAssertEqual(rows[0].lane, 0)
        XCTAssertGreaterThan(rows[0].columnCount, 1)
        XCTAssertFalse(rows[0].merges.isEmpty)
        XCTAssertEqual(rows[3].outgoing.filter { !$0.isEmpty }, [])
    }
}
