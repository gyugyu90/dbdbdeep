import XCTest
import DBDeepCore
@testable import DBDeepApp

@MainActor
final class BookmarkTargetTests: XCTestCase {
    func testOnlyCursorStatementIsCapturedEvenWithMultipleStatementsSelected() throws {
        let store = try makeStore()
        store.query = "SELECT 'first';\nSELECT 'middle';\nSELECT 'last';"
        store.selectedSQL = store.query
        store.cursorLocation = (store.query as NSString).range(of: "middle").location

        store.newBookmark()

        XCTAssertTrue(store.showBookmark)
        XCTAssertNil(store.editingBookmark)
        XCTAssertEqual(store.bookmarkDraftSQL, "SELECT 'middle';")
        XCTAssertEqual(store.bookmarkDraftConnectionID, store.selectedID)
        store.cursorLocation = 0
        store.query = "SELECT 'changed';"
        XCTAssertEqual(store.bookmarkDraftSQL, "SELECT 'middle';")
    }

    func testBlankGapAndEndOfEditorTargetPreviousQuery() throws {
        let store = try makeStore()
        store.query = "SELECT 1;\n\n\nSELECT 2;\n\n"
        store.cursorLocation = (store.query as NSString).range(of: "\n\n\n").location + 1
        XCTAssertEqual(store.sqlToBookmark, "SELECT 1;")
        XCTAssertTrue(store.canBookmarkQuery)
        XCTAssertEqual(store.sqlToRun, store.sqlToBookmark)
        store.cursorLocation = store.query.utf16.count
        XCTAssertEqual(store.sqlToBookmark, "SELECT 2;")
        XCTAssertEqual(store.sqlToRun, store.sqlToBookmark)
    }

    func testExistingBookmarkIsRecognizedAndOpenedForEditing() throws {
        let store = try makeStore()
        let bookmark = QueryBookmark(name: "Customer lookup", emoji: "🌷", color: "rose", sql: "SELECT id, name FROM customers;", connectionID: store.selectedID)
        store.bookmarks = [bookmark]
        store.query = "SELECT * FROM orders;\n-- customer lookup\nselect ID,\nNAME from CUSTOMERS"
        store.cursorLocation = store.query.utf16.count

        XCTAssertEqual(store.currentBookmark?.id, bookmark.id)
        store.newBookmark()

        XCTAssertEqual(store.editingBookmark, bookmark)
        XCTAssertTrue(store.showBookmark)
        var edited = bookmark
        edited.name = "Renamed lookup"
        XCTAssertTrue(store.saveBookmark(edited))
        XCTAssertEqual(store.bookmarks.count, 1)
        XCTAssertEqual(store.bookmarks.first?.id, bookmark.id)
        XCTAssertEqual(store.bookmarks.first?.name, "Renamed lookup")
        XCTAssertFalse(store.showBookmark)
    }

    func testSavedStateTracksCursorAndSQLChanges() throws {
        let store = try makeStore()
        let saved = QueryBookmark(name: "First", sql: "SELECT 'first';", connectionID: store.selectedID)
        store.bookmarks = [saved]
        store.query = "SELECT 'first';\nSELECT 'second';"
        XCTAssertEqual(store.currentBookmark?.id, saved.id)
        store.cursorLocation = store.query.utf16.count
        XCTAssertNil(store.currentBookmark)
        store.query = "SELECT 'FIRST';"
        store.cursorLocation = 0
        XCTAssertNil(store.currentBookmark)
    }

    func testOnlyCurrentConnectionBookmarkMatchesQuery() throws {
        let store = try makeStore()
        store.query = "SELECT 1;"
        let other = QueryBookmark(name: "Another connection", sql: store.query, connectionID: UUID())
        let global = QueryBookmark(name: "Any connection", sql: store.query)
        let current = QueryBookmark(name: "Current connection", sql: store.query, connectionID: store.selectedID)
        store.bookmarks = [other]
        XCTAssertNil(store.currentBookmark)
        store.bookmarks.append(global)
        XCTAssertNil(store.currentBookmark)
        store.bookmarks.append(current)
        XCTAssertEqual(store.currentBookmark?.id, current.id)
    }

    func testSaveRejectsMultipleQueriesOrAnIncompleteTrailingQuery() throws {
        let store = try makeStore()
        let original = store.bookmarks
        store.showBookmark = true
        for sql in ["SELECT 1; SELECT 2;", "SELECT 1; SELECT 'unfinished", "BEGIN NULL;", "-- comment only", " "] {
            XCTAssertFalse(store.saveBookmark(QueryBookmark(name: "Invalid", sql: sql, connectionID: store.selectedID)), sql)
            XCTAssertEqual(store.bookmarks, original)
            XCTAssertTrue(store.showBookmark)
        }
    }

    func testSavesPLSQLBlockAsOneBookmarkAndUpdatesSavedState() throws {
        let store = try makeStore()
        let block = "BEGIN NULL; NULL; END;"
        store.query = block + "\n/\nSELECT 2;"
        store.cursorLocation = (store.query as NSString).range(of: "NULL").location
        store.newBookmark()
        XCTAssertEqual(store.bookmarkDraftSQL, block)
        let saved = QueryBookmark(name: "Block", sql: store.bookmarkDraftSQL, connectionID: store.selectedID)
        XCTAssertTrue(store.saveBookmark(saved))
        XCTAssertEqual(store.currentBookmark?.id, saved.id)
        store.removeBookmark(saved)
        XCTAssertNil(store.currentBookmark)
    }

    func testNoQueryOrBusyStateDoesNotOpenBookmarkSheet() throws {
        let store = try makeStore()
        for sql in ["", "-- comment", "SELECT 'unfinished", "  SELECT 1;"] {
            store.query = sql
            store.cursorLocation = 0
            XCTAssertFalse(store.canBookmarkQuery, sql)
            store.newBookmark()
            XCTAssertFalse(store.showBookmark)
        }
        store.query = "SELECT 1; SELECT 'unfinished"
        store.cursorLocation = store.query.utf16.count
        XCTAssertFalse(store.canBookmarkQuery)
        store.query = "SELECT 1;"
        store.cursorLocation = 0
        store.isBusy = true
        XCTAssertFalse(store.canBookmarkQuery)
        store.newBookmark()
        XCTAssertFalse(store.showBookmark)
    }

    private func makeStore() throws -> AppStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return AppStore(directory: directory)
    }
}
