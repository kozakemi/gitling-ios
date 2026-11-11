import XCTest
@testable import Gitling

@MainActor
final class RepositorySearchModelTests: XCTestCase {
    private final class Counter: @unchecked Sendable { var page = 0 }

    func testNewQueryCancelsOldWalkAndLateResultCannotReplaceNewResults() async throws {
        let model = RepositorySearchModel<String>()
        let entered = expectation(description: "old query began")
        let stopped = expectation(description: "old query cancelled")
        let old = Task {
            await model.search(debounce: false) { token in
                RepositorySearchCursor(cancellation: token) { _, cancellation in
                    entered.fulfill()
                    do {
                        for _ in 0..<2000 { try cancellation.check(); Thread.sleep(forTimeInterval: 0.001) }
                        throw WorkingTreeError.busy
                    } catch { XCTAssertTrue(error is CancellationError); stopped.fulfill(); throw error }
                }
            }
        }
        await fulfillment(of: [entered], timeout: 3)
        await model.search(debounce: false) { token in
            RepositorySearchCursor(cancellation: token) { _, _ in .init(items: ["new query"], hasMore: false, scanned: 7) }
        }
        await fulfillment(of: [stopped], timeout: 3)
        await old.value
        XCTAssertEqual(model.items, ["new query"])
        XCTAssertEqual(model.scanned, 7)
        XCTAssertFalse(model.isLoading)
        XCTAssertNil(model.error)
    }

    func testLoadMoreAppendsPagesAndChangingScopeResetsResultsAndPagination() async {
        let model = RepositorySearchModel<String>(), counter = Counter()
        await model.search(debounce: false) { token in
            RepositorySearchCursor(cancellation: token) { _, _ in
                counter.page += 1
                return .init(items: ["page \(counter.page)"], hasMore: counter.page < 2, scanned: counter.page * 10)
            }
        }
        XCTAssertTrue(model.hasMore)
        await model.loadMore()
        XCTAssertEqual(model.items, ["page \(1)", "page \(2)"])
        XCTAssertFalse(model.hasMore)
        await model.search(debounce: false) { token in
            RepositorySearchCursor(cancellation: token) { _, _ in .init(items: ["different scope"], hasMore: false, scanned: 1) }
        }
        XCTAssertEqual(model.items, ["different scope"])
        XCTAssertEqual(model.scanned, 1)
    }

    func testReadFailureIsAnErrorAndNotAnEmptySuccessfulSearch() async {
        let model = RepositorySearchModel<String>()
        await model.search(debounce: false) { _ in throw WorkingTreeError.notFound }
        XCTAssertNotNil(model.error)
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertFalse(model.hasMore)
        XCTAssertFalse(model.isLoading)
    }

    func testLeavingPageCancelsPendingQueryWithoutPublishingResults() async throws {
        let model = RepositorySearchModel<String>()
        let entered = expectation(description: "reader began")
        let task = Task {
            await model.search(debounce: false) { token in
                RepositorySearchCursor(cancellation: token) { _, cancellation in
                    entered.fulfill()
                    for _ in 0..<2000 { try cancellation.check(); Thread.sleep(forTimeInterval: 0.001) }
                    return .init(items: ["late result"], hasMore: false, scanned: 1)
                }
            }
        }
        await fulfillment(of: [entered], timeout: 3)
        model.cancel()
        await task.value
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertFalse(model.isLoading)
        XCTAssertNil(model.error)
    }
}
