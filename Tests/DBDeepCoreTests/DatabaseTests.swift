import XCTest
@testable import DBDeepCore

final class DatabaseTests: XCTestCase {
    func testCRUDAndRollback() async throws {
        let db = try SQLiteDatabase(path: ":memory:")
        _ = try await db.execute("CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT NOT NULL)")
        _ = try await db.execute("BEGIN")
        let insert = try await db.execute("INSERT INTO notes (body) VALUES ('hello 🌱')")
        XCTAssertEqual(insert.affected, 1)
        let select = try await db.execute("SELECT id, body FROM notes")
        XCTAssertEqual(select.columns, ["id", "body"])
        XCTAssertEqual(select.rows, [["1", "hello 🌱"]])
        _ = try await db.execute("COMMIT; BEGIN")
        let update = try await db.execute("UPDATE notes SET body = 'updated' WHERE id = 1")
        XCTAssertEqual(update.affected, 1)
        _ = try await db.execute("ROLLBACK; BEGIN")
        let restored = try await db.execute("SELECT body FROM notes")
        XCTAssertEqual(restored.rows, [["hello 🌱"]])
        let delete = try await db.execute("DELETE FROM notes WHERE id = 1")
        XCTAssertEqual(delete.affected, 1)
        _ = try await db.execute("COMMIT; BEGIN")
        let empty = try await db.execute("SELECT * FROM notes")
        XCTAssertTrue(empty.rows.isEmpty)
    }

    func testQuotedIdentifiersAndSchemaConstraints() async throws {
        let db = try SQLiteDatabase(path: ":memory:")
        let name = "a\"strange table"
        _ = try await db.execute("CREATE TABLE \(SQLIdentifier.quote(name)) (id INTEGER PRIMARY KEY, required TEXT NOT NULL, optional REAL)")
        let tables = try await db.schema()
        XCTAssertEqual(tables.count, 1)
        XCTAssertEqual(tables[0].name, name)
        XCTAssertTrue(tables[0].columns[0].primaryKey)
        XCTAssertFalse(tables[0].columns[0].nullable)
        XCTAssertFalse(tables[0].columns[1].nullable)
        XCTAssertTrue(tables[0].columns[2].nullable)
    }

    func testSemicolonsCommentsNullsAndErrors() async throws {
        let db = try SQLiteDatabase(path: ":memory:")
        let output = try await db.execute("-- a comment;\nSELECT 'a;b' AS text, NULL AS missing; /* done; */")
        XCTAssertEqual(output.rows, [["a;b", nil]])
        do {
            _ = try await db.execute("SELECT * FROM missing_table")
            XCTFail("Invalid query should fail")
        } catch { XCTAssertTrue(error.localizedDescription.contains("missing_table")) }
        do {
            _ = try await db.execute(" -- no SQL")
            XCTFail("Comment-only query should fail")
        } catch { XCTAssertTrue(error.localizedDescription.contains("SQL")) }
        let recovered = try await db.execute("SELECT 42")
        XCTAssertEqual(recovered.rows, [["42"]])
    }

    func testRowLimitAndReturningDMLCompletes() async throws {
        let db = try SQLiteDatabase(path: ":memory:")
        _ = try await db.execute("CREATE TABLE numbers (n INTEGER)")
        _ = try await db.execute("WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 1100) INSERT INTO numbers SELECT n FROM seq")
        let output = try await db.execute("SELECT n FROM numbers ORDER BY n", rowLimit: 10)
        XCTAssertEqual(output.rows.count, 10)
        XCTAssertTrue(output.truncated)
        let update = try await db.execute("UPDATE numbers SET n = n + 1 RETURNING n", rowLimit: 5)
        XCTAssertEqual(update.affected, 1100)
        XCTAssertEqual(update.rows.count, 5)
        let total = try await db.execute("SELECT MIN(n), MAX(n), COUNT(*) FROM numbers")
        XCTAssertEqual(total.rows, [["2", "1101", "1100"]])
    }

    func testSampleAndDiskPersistence() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let first = try SQLiteDatabase(path: url.path)
        try await first.seed()
        let customers = try await first.execute("SELECT COUNT(*) FROM customers")
        XCTAssertEqual(customers.rows, [["8"]])
        _ = try await first.execute("DELETE FROM orders; DELETE FROM customers")
        let second = try SQLiteDatabase(path: url.path)
        try await second.seed()
        let persisted = try await second.execute("SELECT COUNT(*) FROM customers")
        XCTAssertEqual(persisted.rows, [["0"]], "Opening a playground must not recreate deleted data")
    }

    func testBookmarkPersistenceAndCSV() throws {
        let id = UUID()
        let bookmark = QueryBookmark(name: "한글 쿼리", emoji: "🐳", color: "mint", sql: "SELECT 'a;b' FROM dual", connectionID: id)
        let state = WorkspaceState(connections: [DBConnection(id: id, name: "Dev", username: "SCOTT")], bookmarks: [bookmark], drafts: [id.uuidString: "SELECT 1 FROM dual"], selectedConnection: id)
        let data = try JSONEncoder().encode(state)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("password"))
        let restored = try JSONDecoder().decode(WorkspaceState.self, from: data)
        XCTAssertEqual(restored.bookmarks, [bookmark])
        XCTAssertEqual(restored.selectedConnection, id)
        XCTAssertEqual(restored.drafts[id.uuidString], "SELECT 1 FROM dual")
        let result = QueryResult(columns: ["name", "note"], rows: [["Kim, Lee", "a\"b\nc"], [nil, ""]])
        XCTAssertEqual(result.csv, "\"name\",\"note\"\r\n\"Kim, Lee\",\"a\"\"b\nc\"\r\n,\"\"")
    }
}
