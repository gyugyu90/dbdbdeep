import XCTest
import DBDeepCore
@testable import DBDeepApp

@MainActor
final class QueryExportAppTests: XCTestCase {
    func testFullExportUsesResultQueryInsteadOfEditedConsoleAndKeepsPreview() async throws {
        let directory = try temporaryDirectory()
        let store = AppStore(directory: directory)
        let sql = "WITH RECURSIVE n(x) AS(SELECT 1 UNION ALL SELECT x+1 FROM n WHERE x<2501) SELECT x FROM n ORDER BY x;"
        store.query = "SELECT 'not selected';\n" + sql
        store.selectedSQL = sql
        await store.run()
        let resultID = store.result?.id
        XCTAssertEqual(store.result?.rows.count, 1000)
        XCTAssertTrue(store.result?.truncated == true)
        XCTAssertTrue(store.canExportAllQueryRows)
        store.query = "DELETE FROM notes;"
        store.selectedSQL = "DELETE FROM notes;"
        store.cursorLocation = 5
        let destination = directory.appendingPathComponent("all.csv")
        await store.exportAllQueryRows(to: destination)
        XCTAssertNil(store.error)
        XCTAssertEqual(store.exportedRows, 2501)
        XCTAssertTrue(try String(contentsOf: destination, encoding: .utf8).hasSuffix("\"2501\"\r\n"))
        XCTAssertEqual(store.result?.id, resultID)
        XCTAssertEqual(store.result?.rows.count, 1000)
        XCTAssertEqual(store.history.count, 1)
        XCTAssertEqual(store.query, "DELETE FROM notes;")
        XCTAssertEqual(store.selectedSQL, "DELETE FROM notes;")
        XCTAssertEqual(store.cursorLocation, 5)
        XCTAssertFalse(store.isExporting)
        XCTAssertFalse(store.isBusy)
        let fetched = directory.appendingPathComponent("fetched.csv")
        await store.exportFetchedRows(to: fetched)
        XCTAssertEqual(store.exportedRows, 1000)
        XCTAssertFalse(try String(contentsOf: fetched, encoding: .utf8).contains("\"2501\""))
    }

    func testReturningDMLCanOnlyExportFetchedRowsAndIsNeverRepeated() async throws {
        let directory = try temporaryDirectory()
        let store = AppStore(directory: directory)
        store.query = "INSERT INTO notes(content) VALUES ('only once') RETURNING id;"
        await store.run()
        XCTAssertTrue(store.canExportFetchedRows)
        XCTAssertFalse(store.canExportAllQueryRows)
        let destination = directory.appendingPathComponent("not-created.csv")
        await store.exportAllQueryRows(to: destination)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        store.query = "SELECT COUNT(*) FROM notes WHERE content='only once';"
        await store.run()
        XCTAssertEqual(store.result?.rows, [["1"]])
    }

    func testExportProgressBlocksDuplicateOperationsAndKeepsConnection() async throws {
        let session = ExportTestSession(paused: true)
        let (store, directory) = try oracleStore(session)
        store.query = "SELECT id FROM original_table;"
        await store.run()
        let id = store.selectedID
        let task = Task { await store.exportAllQueryRows(to: directory.appendingPathComponent("all.csv")) }
        await session.waitForExport()
        XCTAssertTrue(store.isExporting)
        XCTAssertTrue(store.isBusy)
        XCTAssertFalse(store.canExportAllQueryRows)
        XCTAssertFalse(store.canRefreshResults)
        store.select(DBConnection(name: "Other", kind: .sample))
        XCTAssertEqual(store.selectedID, id)
        await store.exportAllQueryRows(to: directory.appendingPathComponent("duplicate.csv"))
        await session.resumeExport()
        await task.value
        XCTAssertFalse(store.isBusy)
        XCTAssertFalse(store.isExporting)
        XCTAssertEqual(store.exportedRows, 1200)
        let exports = await session.exports
        XCTAssertEqual(exports, ["SELECT id FROM original_table;"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("duplicate.csv").path))
    }

    func testExpiredConnectionReconnectsForExportWithoutRemovingVisibleResult() async throws {
        let session = ExportTestSession()
        let (store, directory) = try oracleStore(session)
        store.query = "SELECT id FROM original_table;"
        await store.run()
        let resultID = store.result?.id
        await session.expire()
        store.query = "SELECT 'edited console' FROM dual;"
        await store.exportAllQueryRows(to: directory.appendingPathComponent("all.csv"))
        XCTAssertNil(store.error)
        XCTAssertEqual(store.result?.id, resultID)
        XCTAssertTrue(store.canExportAllQueryRows)
        let exports = await session.exports
        XCTAssertEqual(exports, ["SELECT id FROM original_table;"])
        let connections = await session.connections
        XCTAssertEqual(connections, 2)
        XCTAssertEqual(store.query, "SELECT 'edited console' FROM dual;")
    }

    func testExportFailureClearsBusyStateAndDoesNotRetry() async throws {
        let session = ExportTestSession(fails: true)
        let (store, directory) = try oracleStore(session)
        store.query = "SELECT id FROM original_table;"
        await store.run()
        let resultID = store.result?.id
        await store.exportAllQueryRows(to: directory.appendingPathComponent("failed.csv"))
        XCTAssertEqual(store.error, "simulated export failure")
        XCTAssertFalse(store.isBusy)
        XCTAssertFalse(store.isExporting)
        XCTAssertEqual(store.result?.id, resultID)
        let exports = await session.exports
        XCTAssertEqual(exports.count, 1)
    }

    private func oracleStore(_ session: ExportTestSession) throws -> (AppStore, URL) {
        let directory = try temporaryDirectory()
        let connection = DBConnection(name: "Oracle fixture")
        try WorkspaceFileStore(directory: directory).save(WorkspaceState(connections: [connection], bookmarks: [], selectedConnection: connection.id))
        return (AppStore(directory: directory, makeOracleSession: { _, _ in session }, readPassword: { _ in "" }), directory)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return directory
    }
}

private actor ExportTestSession: DatabaseConnectionSession {
    let paused: Bool
    let fails: Bool
    var valid = false
    var started = false
    var observers: [CheckedContinuation<Void, Never>] = []
    var waiter: CheckedContinuation<Void, Never>?
    private(set) var exports: [String] = []
    private(set) var connections = 0

    init(paused: Bool = false, fails: Bool = false) { self.paused = paused; self.fails = fails }
    func connect(password: String, onEvent: @escaping ConnectionEventHandler) { valid = true; connections += 1 }
    func validateConnection() throws { if !valid { throw DatabaseError("expired") } }
    func execute(_ sql: String) -> QueryResult { QueryResult(columns: ["id"], rows: [["1"]]) }
    func schema() -> [SchemaTable] { [] }
    func commit() -> QueryResult { QueryResult() }
    func rollback() -> QueryResult { QueryResult() }
    func disconnect() { valid = false }
    func expire() { valid = false }

    func exportCSV(_ sql: String, to destination: URL, onProgress: QueryExportProgressHandler) async throws -> QueryExportSummary {
        exports.append(sql)
        onProgress(1200)
        started = true
        observers.forEach { $0.resume() }; observers = []
        if paused { await withCheckedContinuation { waiter = $0 } }
        if fails { throw DatabaseError("simulated export failure") }
        let data = Data(("\"id\"\r\n" + (1...1200).map { "\"\($0)\"\r\n" }.joined()).utf8)
        try data.write(to: destination)
        return QueryExportSummary(rows: 1200, bytes: Int64(data.count), elapsed: 0.1)
    }

    func waitForExport() async {
        if started { return }
        await withCheckedContinuation { observers.append($0) }
    }
    func resumeExport() { waiter?.resume(); waiter = nil }
}
