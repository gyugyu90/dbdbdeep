import XCTest
import DBDeepCore
@testable import DBDeepApp

@MainActor
final class TableBrowseTests: XCTestCase {
    func testSQLitePreviewPreservesDraftAndIgnoresExistingSelection() async throws {
        let store = try makeStore(kind: .sample)
        let original = "-- 작성 중인 쿼리 🌷\nSELECT * FROM should_not_run;\nDELETE FROM customers;"
        store.query = original
        store.selectedSQL = original

        await store.browse(SchemaTable(name: "customers"))

        let preview = "SELECT *\nFROM \"customers\"\nLIMIT 100;"
        XCTAssertNil(store.error)
        XCTAssertEqual(store.query, original + "\n\n" + preview)
        XCTAssertEqual(store.history.map(\.sql), [preview])
        XCTAssertFalse(try XCTUnwrap(store.result).rows.isEmpty)
        XCTAssertTrue(store.selectedSQL.isEmpty)
        let range = try XCTUnwrap(store.editorFocusRequest).range
        XCTAssertEqual((store.query as NSString).substring(with: range), preview)
        XCTAssertEqual(store.cursorLocation, range.location)
    }

    func testRepeatedPreviewReusesExistingQueryWithoutChangingOtherText() async throws {
        let store = try makeStore(kind: .sample)
        let original = "SELECT '한글 💜';\n\nselect * from \"customers\" limit 100;\nSELECT 'after';"
        store.query = original

        await store.browse(SchemaTable(name: "customers"))
        let first = try XCTUnwrap(store.editorFocusRequest)
        await store.browse(SchemaTable(name: "customers"))

        XCTAssertEqual(store.query, original)
        XCTAssertEqual(store.editorFocusRequest?.range, first.range)
        XCTAssertNotEqual(store.editorFocusRequest?.id, first.id)
        XCTAssertEqual(store.history.count, 2)
    }

    func testOraclePreviewAddsSafeSeparatorAndPersistsEntireConsole() async throws {
        let store = try makeStore(kind: .oracle)
        let original = "SELECT 'keep my draft' FROM dual -- no final semicolon"
        store.query = original
        store.selectedSQL = original
        await store.browse(SchemaTable(name: "Order\" Items"))

        let preview = "SELECT *\nFROM \"Order\"\" Items\"\nFETCH FIRST 100 ROWS ONLY;"
        XCTAssertEqual(store.query, original + "\n;\n\n" + preview)
        XCTAssertEqual(store.history.map(\.sql), [preview])
        XCTAssertNil(store.error)
        store.persist(waitForDrafts: true)
        let id = try XCTUnwrap(store.selectedID).uuidString
        XCTAssertEqual(try WorkspaceFileStore(directory: store.directory).load()?.drafts[id], store.query)
        XCTAssertEqual(try ConsoleDraftFileStore(directory: store.directory).load().drafts[id]?.query, store.query)
    }

    func testMongoPreviewPreservesExistingCommandsAndDoesNotAppendDuplicates() async throws {
        let store = try makeStore(kind: .mongodb)
        let original = "db.items.find({keep: '작성 중'})"
        store.query = original
        await store.browse(SchemaTable(name: "other.items"))
        let combined = store.query
        XCTAssertTrue(combined.hasPrefix(original))
        XCTAssertTrue(combined.contains(QueryLanguage.browseCollection("other.items")))
        await store.browse(SchemaTable(name: "other.items"))
        XCTAssertEqual(store.query, combined)
        XCTAssertEqual(store.history.map(\.sql), Array(repeating: QueryLanguage.browseCollection("other.items"), count: 2))
        XCTAssertNil(store.error)
    }

    func testUnfinishedDraftAndSelectionStayUntouchedWhilePreviewRunsIndependently() async throws {
        for kind in [DBConnection.Kind.oracle, .mongodb] {
            let store = try makeStore(kind: kind)
            let original = kind == .oracle ? "SELECT 'unfinished 한글" : "db.items.find({name: 'unfinished"
            store.query = original
            store.selectedSQL = "unfinished"
            store.cursorLocation = 8
            await store.browse(SchemaTable(name: "items"))
            XCTAssertEqual(store.query, original)
            XCTAssertEqual(store.selectedSQL, "unfinished")
            XCTAssertEqual(store.cursorLocation, 8)
            XCTAssertNil(store.editorFocusRequest)
            XCTAssertEqual(store.history.count, 1)
            XCTAssertNil(store.error)
        }
    }

    func testConsoleAtLineLimitIsNotExtendedOrTruncatedByPreview() async throws {
        let store = try makeStore(kind: .oracle)
        let original = String(repeating: "-- keep this line\n", count: SQLLineIndex.maximumLines - 1) + "SELECT 1 FROM dual;"
        store.query = original
        await store.browse(SchemaTable(name: "items"))
        XCTAssertEqual(store.query, original)
        XCTAssertEqual(store.queryLineCount, SQLLineIndex.maximumLines)
        XCTAssertNil(store.editorFocusRequest)
        XCTAssertEqual(store.history.count, 1)
        XCTAssertNil(store.error)
    }

    func testBusyOrMissingConnectionDoesNotChangeConsoleOrRunPreview() async throws {
        let store = try makeStore(kind: .oracle)
        store.query = "SELECT 'keep';"
        store.selectedSQL = "keep"
        store.isBusy = true
        await store.browse(SchemaTable(name: "items"))
        store.isBusy = false
        store.connections = []
        store.selectedID = nil
        await store.browse(SchemaTable(name: "items"))
        XCTAssertEqual(store.query, "SELECT 'keep';")
        XCTAssertEqual(store.selectedSQL, "keep")
        XCTAssertTrue(store.history.isEmpty)
        XCTAssertNil(store.editorFocusRequest)
    }

    private func makeStore(kind: DBConnection.Kind) throws -> AppStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let connection = DBConnection(name: "Preview test", kind: kind)
        try WorkspaceFileStore(directory: directory).save(WorkspaceState(connections: [connection], bookmarks: [], selectedConnection: connection.id))
        return AppStore(directory: directory, makeOracleSession: { _, _ in PreviewSession() }, makeMongoSession: { _, _ in PreviewSession() }, readPassword: { _ in "" })
    }
}

private actor PreviewSession: DatabaseConnectionSession {
    func connect(password: String, onEvent: @escaping ConnectionEventHandler) {}
    func validateConnection() {}
    func execute(_ sql: String) -> QueryResult { QueryResult(columns: ["executed"], rows: [[sql]], message: "Preview complete") }
    func schema() -> [SchemaTable] { [] }
    func commit() -> QueryResult { QueryResult() }
    func rollback() -> QueryResult { QueryResult() }
    func disconnect() {}
}
