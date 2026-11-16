import UIKit
import XCTest
@testable import Gitling

@MainActor final class CommitClipboardTests: XCTestCase {
    func testCopiesFullOIDWhenCommitsShareAnAbbreviatedPrefix() {
        let pasteboard = UIPasteboard.withUniqueName()
        defer { UIPasteboard.remove(withName: pasteboard.name) }
        let first = "abcdef0" + String(repeating: "1", count: 33)
        let second = "abcdef0" + String(repeating: "2", count: 33)
        XCTAssertTrue(CommitClipboard.copy(first, to: pasteboard))
        XCTAssertEqual(pasteboard.string, first)
        XCTAssertTrue(CommitClipboard.copy(second, to: pasteboard))
        XCTAssertEqual(pasteboard.string, second)
        XCTAssertEqual(pasteboard.numberOfItems, 1)
        let sha256 = String(repeating: "aF12", count: 16)
        XCTAssertTrue(CommitClipboard.copy(sha256, to: pasteboard))
        XCTAssertEqual(pasteboard.string, sha256)
    }

    func testAbbreviatedOrInvalidOIDCannotReplaceClipboard() {
        let pasteboard = UIPasteboard.withUniqueName()
        defer { UIPasteboard.remove(withName: pasteboard.name) }
        pasteboard.string = "keep"
        for invalid in ["", "abcdef0", "HEAD", String(repeating: "g", count: 40), String(repeating: "a", count: 39) + "\n"] {
            XCTAssertFalse(CommitClipboard.copy(invalid, to: pasteboard))
            XCTAssertEqual(pasteboard.string, "keep")
        }
    }
}
