import XCTest
import DBDeepCore
@testable import DBDeepApp

@MainActor
final class BookmarkConnectionTests: XCTestCase {
    func testLibrarySearchAndColorFiltersOnlyIncludeTheSelectedConnection() throws {
        let store = try makeStore()
        let first = try XCTUnwrap(store.connection)
        let second = DBConnection(name: "Development")
        store.connections.append(second)
        let local = QueryBookmark(name: "Lookup", color: "mint", sql: "SELECT 1;", connectionID: first.id)
        let remote = QueryBookmark(name: "Other lookup", color: "mint", sql: "SELECT 2;", connectionID: second.id)
        let global = QueryBookmark(name: "Old lookup", sql: "SELECT 3;")
        store.bookmarks = [local, remote, global]
        XCTAssertEqual(store.connectionBookmarks, [local])
        store.bookmarkSearch = "LOOKUP"
        store.bookmarkFilter = "mint"
        XCTAssertEqual(store.filteredBookmarks, [local])
        store.bookmarkSearch = "SELECT 2"
        XCTAssertTrue(store.filteredBookmarks.isEmpty)
        store.bookmarkSearch = ""
        store.bookmarkFilter = "rose"
        XCTAssertTrue(store.filteredBookmarks.isEmpty)

        store.select(second)
        XCTAssertTrue(store.bookmarkSearch.isEmpty)
        XCTAssertNil(store.bookmarkFilter)
        XCTAssertEqual(store.connectionBookmarks, [remote])
        XCTAssertEqual(store.filteredBookmarks, [remote])
        XCTAssertEqual(store.unassignedBookmarks, [global])
    }

    func testIdenticalSQLIsSavedAndRecognizedIndependentlyPerConnection() throws {
        let store = try makeStore()
        let first = try XCTUnwrap(store.connection)
        let second = DBConnection(name: "Development")
        store.connections.append(second)
        store.bookmarks = []
        store.query = "SELECT 1;"
        let local = QueryBookmark(name: "Local lookup", sql: store.query, connectionID: first.id)
        XCTAssertTrue(store.saveBookmark(local))
        store.newBookmark()
        XCTAssertEqual(store.editingBookmark?.id, local.id)
        store.showBookmark = false
        store.select(second)
        store.query = "SELECT 1;"
        XCTAssertNil(store.currentBookmark)
        store.newBookmark()
        XCTAssertNil(store.editingBookmark)
        XCTAssertEqual(store.bookmarkDraftConnectionID, second.id)
        let remote = QueryBookmark(name: "Remote lookup", sql: store.bookmarkDraftSQL, connectionID: second.id)
        XCTAssertTrue(store.saveBookmark(remote))
        XCTAssertEqual(store.currentBookmark?.id, remote.id)
        XCTAssertEqual(store.filteredBookmarks, [remote])
        XCTAssertEqual(store.bookmarks.count, 2)
        let restored = AppStore(directory: store.directory)
        XCTAssertEqual(restored.selectedID, second.id)
        XCTAssertEqual(restored.filteredBookmarks, [remote])
        store.connectedIDs.insert(first.id)
        store.select(first)
        XCTAssertEqual(store.currentBookmark?.id, local.id)
        XCTAssertEqual(store.filteredBookmarks, [local])
    }

    func testSaveRejectsMissingUnknownOrOtherConnectionAndCannotReassignAnExistingBookmark() throws {
        let store = try makeStore()
        let currentID = try XCTUnwrap(store.selectedID)
        let other = DBConnection(name: "Other")
        store.connections.append(other)
        let foreign = QueryBookmark(name: "Foreign", sql: "SELECT 1;", connectionID: other.id)
        store.bookmarks = [foreign]
        for id in [nil, Optional(UUID()), Optional(other.id)] {
            XCTAssertFalse(store.saveBookmark(QueryBookmark(name: "Invalid owner", sql: "SELECT 1;", connectionID: id)))
        }
        var reassigned = foreign
        reassigned.connectionID = currentID
        XCTAssertFalse(store.saveBookmark(reassigned))
        XCTAssertEqual(store.bookmarks, [foreign])
        store.query = "SELECT 'snapshot';"
        store.newBookmark()
        store.select(other)
        XCTAssertEqual(store.bookmarkDraftConnectionID, currentID)
        XCTAssertFalse(store.saveBookmark(QueryBookmark(name: "Stale sheet", sql: store.bookmarkDraftSQL, connectionID: store.bookmarkDraftConnectionID)))
    }

    func testLoadingOrEditingOtherConnectionQueryDoesNotSwitchConnectionOrModifyEditor() throws {
        let store = try makeStore()
        let selected = store.selectedID
        let other = DBConnection(name: "Other")
        store.connections.append(other)
        store.query = "SELECT 'keep me';"
        store.selectedSQL = "keep me"
        store.cursorLocation = 10
        let foreign = QueryBookmark(name: "Foreign", sql: "SELECT 'other';", connectionID: other.id)
        store.focusBookmark(foreign)
        store.editBookmark(foreign)
        XCTAssertEqual(store.selectedID, selected)
        XCTAssertEqual(store.query, "SELECT 'keep me';")
        XCTAssertEqual(store.selectedSQL, "keep me")
        XCTAssertEqual(store.cursorLocation, 10)
        XCTAssertFalse(store.showBookmark)
        let local = QueryBookmark(name: "Local", sql: "SELECT 'local';", connectionID: selected)
        store.editBookmark(local)
        XCTAssertEqual(store.editingBookmark, local)
        store.focusBookmark(local)
        XCTAssertEqual(store.query, "SELECT 'keep me';\n\n" + local.sql)
        XCTAssertTrue(store.selectedSQL.isEmpty)
        XCTAssertEqual(store.cursorLocation, ("SELECT 'keep me';\n\n" as NSString).length)
        XCTAssertTrue(store.results.isEmpty)
        XCTAssertTrue(store.history.isEmpty)
    }

    func testUnassignedAndOrphanedQueriesMoveExplicitlyWithoutLosingMetadataAndPersist() throws {
        let store = try makeStore()
        let connectionID = try XCTUnwrap(store.selectedID)
        let unassigned = QueryBookmark(name: "Legacy", emoji: "🌷", color: "rose", sql: "SELECT 1; SELECT 2;")
        let orphan = QueryBookmark(name: "Removed connection", sql: "SELECT 3;", connectionID: UUID())
        let local = QueryBookmark(name: "Local", sql: "SELECT 4;", connectionID: connectionID)
        store.bookmarks = [unassigned, orphan, local]
        let query = store.query
        store.persist()
        let restored = AppStore(directory: store.directory)
        XCTAssertEqual(restored.unassignedBookmarks, [unassigned, orphan])
        XCTAssertEqual(restored.connectionBookmarks, [local])
        restored.bookmarkSearch = "missing"
        restored.bookmarkFilter = "mint"
        XCTAssertTrue(restored.assignBookmark(unassigned))
        var moved = unassigned
        moved.connectionID = connectionID
        XCTAssertEqual(restored.bookmarks.first, moved)
        XCTAssertEqual(restored.filteredBookmarks, [moved, local])
        XCTAssertEqual(restored.unassignedBookmarks, [orphan])
        XCTAssertEqual(restored.query, query)
        XCTAssertFalse(restored.assignBookmark(moved))
        XCTAssertTrue(restored.assignBookmark(orphan))
        XCTAssertTrue(restored.unassignedBookmarks.isEmpty)
        let reloaded = AppStore(directory: store.directory)
        XCTAssertEqual(reloaded.bookmarks, restored.bookmarks)
        XCTAssertEqual(reloaded.connectionBookmarks.count, 3)
        XCTAssertTrue(reloaded.history.isEmpty)
    }

    func testMissingConnectionAndBusyStateDisableSavingAndMoving() throws {
        let store = try makeStore()
        let unassigned = QueryBookmark(name: "Legacy", sql: "SELECT 1;")
        store.bookmarks = [unassigned]
        store.query = "SELECT 1;"
        store.selectedID = nil
        XCTAssertFalse(store.canBookmarkQuery)
        XCTAssertNil(store.currentBookmark)
        XCTAssertTrue(store.filteredBookmarks.isEmpty)
        store.newBookmark()
        XCTAssertFalse(store.showBookmark)
        XCTAssertFalse(store.assignBookmark(unassigned))
        XCTAssertFalse(store.saveBookmark(unassigned))
        store.selectedID = store.connections.first?.id
        store.isBusy = true
        XCTAssertFalse(store.assignBookmark(unassigned))
        XCTAssertFalse(store.saveBookmark(QueryBookmark(name: "Busy", sql: "SELECT 1;", connectionID: store.selectedID)))
    }

    private func makeStore() throws -> AppStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return AppStore(directory: directory)
    }
}
