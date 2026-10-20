import XCTest
import DBDeepCore
@testable import DBDeepApp

@MainActor
final class BookmarkFocusTests: XCTestCase {
    func testExistingQueryFocusKeepsOtherStatementsAndFormattingWithoutExecuting() throws {
        let store = try makeStore()
        let bookmark = saved("SELECT id FROM customers;", in: store)
        store.bookmarks = [bookmark]
        let draft = "SELECT 'before 🌷';\n\n-- saved lookup\nselect ID from CUSTOMERS;\nSELECT 'after';"
        store.query = draft
        store.selectedSQL = draft
        XCTAssertTrue(store.focusBookmark(bookmark))
        XCTAssertEqual(store.query, draft)
        XCTAssertTrue(store.selectedSQL.isEmpty)
        XCTAssertEqual(store.cursorLocation, (draft as NSString).range(of: "-- saved lookup").location)
        XCTAssertEqual(store.currentBookmark?.id, bookmark.id)
        XCTAssertEqual(store.editorFocusRequest?.range.location, store.cursorLocation)
        XCTAssertTrue(store.history.isEmpty)
        XCTAssertTrue(store.results.isEmpty)
        XCTAssertFalse(store.isConnected)
    }

    func testMissingQueryAppendsOnceAndRepeatedClicksIssueNewFocusRequests() throws {
        let store = try makeStore()
        let bookmark = saved("SELECT 'new 💜';", in: store)
        store.bookmarks = [bookmark]
        store.query = "SELECT 'keep 한글';"
        XCTAssertTrue(store.focusBookmark(bookmark))
        let draft = store.query
        let request = try XCTUnwrap(store.editorFocusRequest)
        XCTAssertEqual(draft, "SELECT 'keep 한글';\n\nSELECT 'new 💜';")
        XCTAssertEqual((draft as NSString).substring(with: request.range), bookmark.sql)
        XCTAssertEqual(store.currentBookmark?.id, bookmark.id)
        XCTAssertTrue(store.focusBookmark(bookmark))
        XCTAssertEqual(store.query, draft)
        XCTAssertNotEqual(store.editorFocusRequest?.id, request.id)
        XCTAssertEqual(store.editorFocusRequest?.range, request.range)
    }

    func testDuplicateStatementsKeepCurrentOccurrenceAndLiteralValuesRemainDistinct() throws {
        let store = try makeStore()
        let bookmark = saved("SELECT 'same';", in: store)
        store.query = "SELECT 'same';\nSELECT 'SAME';\nSELECT 'same';"
        store.cursorLocation = (store.query as NSString).range(of: "SELECT 'same';", options: .backwards).location
        let expected = store.cursorLocation
        XCTAssertTrue(store.focusBookmark(bookmark))
        XCTAssertEqual(store.cursorLocation, expected)
        XCTAssertEqual(SQLStatementLocator.statements(in: store.query).count, 3)
    }

    func testCardPlayRunsOnlyTheSavedQueryDespiteASelectionElsewhere() async throws {
        let store = try makeStore()
        let bookmark = saved("SELECT 'saved' AS marker;", in: store)
        let draft = "SELECT * FROM should_not_run;\nSELECT 'saved' AS marker;\nSELECT * FROM also_should_not_run;"
        store.query = draft
        store.selectedSQL = draft
        XCTAssertTrue(store.canRunBookmark(bookmark))
        await store.runBookmark(bookmark)
        XCTAssertNil(store.error)
        XCTAssertEqual(store.result?.rows, [["saved"]])
        XCTAssertEqual(store.history.map(\.sql), [bookmark.sql])
        XCTAssertEqual(store.query, draft)
        XCTAssertFalse(store.isBusy)
        XCTAssertFalse(store.isRunningQuery)
    }

    func testCardPlayAddsMissingQueryWithoutExecutingExistingDraft() async throws {
        let store = try makeStore()
        let bookmark = saved("SELECT 'new' AS marker;", in: store)
        store.query = "SELECT * FROM should_not_run;"
        await store.runBookmark(bookmark)
        XCTAssertNil(store.error)
        XCTAssertEqual(store.result?.rows, [["new"]])
        XCTAssertEqual(store.query, "SELECT * FROM should_not_run;\n\n" + bookmark.sql)
        XCTAssertEqual(store.history.count, 1)
    }

    func testIncompleteDraftIsPreservedWhilePlayRunsTheSavedQueryIndependently() async throws {
        let store = try makeStore()
        let bookmark = saved("SELECT 'saved';", in: store)
        let draft = "SELECT 'unfinished"
        store.query = draft
        XCTAssertFalse(store.focusBookmark(bookmark))
        await store.runBookmark(bookmark)
        XCTAssertEqual(store.query, draft)
        XCTAssertNil(store.error)
        XCTAssertNil(store.editorFocusRequest)
        XCTAssertEqual(store.history.map(\.sql), [bookmark.sql])
        XCTAssertEqual(store.result?.rows, [["saved"]])
    }

    func testBusyOtherConnectionAndMultiStatementBookmarksDoNotModifyOrExecute() async throws {
        let store = try makeStore()
        store.query = "SELECT 'keep';"
        let draft = store.query
        let invalid = saved("SELECT 1; SELECT 2;", in: store)
        XCTAssertFalse(store.canRunBookmark(invalid))
        XCTAssertFalse(store.focusBookmark(invalid))
        let foreign = QueryBookmark(name: "Other", sql: "SELECT 1;", connectionID: UUID())
        XCTAssertFalse(store.canRunBookmark(foreign))
        await store.runBookmark(foreign)
        let local = saved("SELECT 2;", in: store)
        store.isBusy = true
        XCTAssertFalse(store.focusBookmark(local))
        await store.runBookmark(local)
        XCTAssertEqual(store.query, draft)
        XCTAssertNil(store.editorFocusRequest)
        XCTAssertTrue(store.history.isEmpty)
    }

    private func saved(_ sql: String, in store: AppStore) -> QueryBookmark {
        QueryBookmark(name: "Saved", sql: sql, connectionID: store.selectedID)
    }

    private func makeStore() throws -> AppStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return AppStore(directory: directory)
    }
}
