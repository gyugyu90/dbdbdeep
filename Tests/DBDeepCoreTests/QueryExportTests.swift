import XCTest
@testable import DBDeepCore

final class QueryExportTests: XCTestCase {
    func testCursorExportsAllRowsBeyondPreviewAndKeepsFullQuotedUnicodeValues() async throws {
        let directory = try temporaryDirectory()
        let destination = directory.appendingPathComponent("all.csv")
        let database = try SQLiteDatabase(path: ":memory:")
        let note = "한글 🌷,\"quoted\"\n" + String(repeating: "긴 값", count: 12_000)
        let escaped = note.replacingOccurrences(of: "'", with: "''")
        let sql = "WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM seq WHERE n<25000) SELECT n, CASE WHEN n=1 THEN '\(escaped)' ELSE 'row '||n END AS note FROM seq ORDER BY n;"
        let preview = try await database.execute(sql)
        XCTAssertEqual(preview.rows.count, 1000)
        XCTAssertTrue(preview.truncated)
        let progress = ExportProgressProbe()
        let summary = try await database.exportCSV(sql, to: destination, onProgress: { progress.append($0) })
        let contents = try String(contentsOf: destination, encoding: .utf8)
        XCTAssertEqual(summary.rows, 25_000)
        XCTAssertEqual(summary.bytes, Int64(try Data(contentsOf: destination).count))
        XCTAssertTrue(contents.hasPrefix("\"n\",\"note\"\r\n\"1\",\"" + note.replacingOccurrences(of: "\"", with: "\"\"") + "\"\r\n"))
        XCTAssertTrue(contents.hasSuffix("\"25000\",\"row 25000\"\r\n"))
        XCTAssertEqual(progress.values.last, 25_000)
        XCTAssertEqual(progress.values, progress.values.sorted())
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasSuffix(".part") })
    }

    func testExplicitQueryLimitAndEmptyResultKeepTheirMeaning() async throws {
        let directory = try temporaryDirectory()
        let database = try SQLiteDatabase(path: ":memory:")
        let destination = directory.appendingPathComponent("limited.csv")
        let summary = try await database.exportCSV("WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM n WHERE x<2000) SELECT x FROM n LIMIT 7", to: destination)
        XCTAssertEqual(summary.rows, 7)
        XCTAssertTrue(try String(contentsOf: destination, encoding: .utf8).hasSuffix("\"7\"\r\n"))
        let empty = try await database.exportCSV("SELECT 1 AS empty WHERE 0", to: destination)
        XCTAssertEqual(empty.rows, 0)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "\"empty\"\r\n")
    }

    func testFailedFetchAfterManyRowsPreservesExistingDestinationAndClosesCursor() async throws {
        let directory = try temporaryDirectory()
        let destination = directory.appendingPathComponent("existing.csv")
        try Data("keep original file".utf8).write(to: destination)
        let database = try SQLiteDatabase(path: ":memory:")
        do {
            _ = try await database.exportCSV("WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM n WHERE x<3000) SELECT CASE WHEN x=1500 THEN abs(-9223372036854775808) ELSE x END FROM n", to: destination)
            XCTFail("A fetch error must fail the export")
        } catch {}
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "keep original file")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["existing.csv"])
        let usable = try await database.execute("SELECT 42")
        XCTAssertEqual(usable.rows, [["42"]])
    }

    func testExportDoesNotCommitOrRepeatWrites() async throws {
        let database = try SQLiteDatabase(path: ":memory:")
        let destination = try temporaryDirectory().appendingPathComponent("rows.csv")
        _ = try await database.execute("CREATE TABLE notes (body TEXT); BEGIN; INSERT INTO notes VALUES ('uncommitted');")
        let summary = try await database.exportCSV("SELECT * FROM notes", to: destination)
        XCTAssertEqual(summary.rows, 1)
        for sql in ["INSERT INTO notes VALUES ('extra') RETURNING body", "WITH x AS(SELECT 1) DELETE FROM notes RETURNING body", "SELECT * FROM notes; DELETE FROM notes;"] {
            do { _ = try await database.exportCSV(sql, to: destination); XCTFail("Writing SQL cannot be exported by rerunning it") }
            catch {}
        }
        let unchanged = try await database.execute("SELECT COUNT(*) FROM notes")
        XCTAssertEqual(unchanged.rows, [["1"]])
        _ = try await database.execute("ROLLBACK")
        let rolledBack = try await database.execute("SELECT COUNT(*) FROM notes")
        XCTAssertEqual(rolledBack.rows, [["0"]])
    }

    func testNullEmptyBinaryAndTextAreExportedWithoutPreviewPlaceholders() async throws {
        let destination = try temporaryDirectory().appendingPathComponent("values.csv")
        let database = try SQLiteDatabase(path: ":memory:")
        _ = try await database.exportCSV("SELECT NULL AS n, '' AS e, X'00ff22' AS b, X'' AS eb, 'a,b' AS t", to: destination)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "\"n\",\"e\",\"b\",\"eb\",\"t\"\r\n,\"\",\"0x00FF22\",\"0x\",\"a,b\"\r\n")
    }

    func testSelectClassifierHandlesCommentsCTEsAndQuotedKeywords() {
        for sql in ["SELECT 1; -- done", "/* header */ select 'DELETE; UPDATE'", "WITH RECURSIVE n(x) AS(SELECT 1 UNION ALL SELECT x+1 FROM n WHERE x<3) SELECT x FROM n", "WITH \"UPDATE\" AS(SELECT q'{) ; ' DELETE}' FROM dual) SELECT * FROM \"UPDATE\""] {
            XCTAssertNotNil(SQLStatementLocator.selectStatement(in: sql), sql)
        }
        for sql in ["UPDATE notes SET body='SELECT' RETURNING body", "WITH x AS(SELECT 1) INSERT INTO notes VALUES ('x')", "WITH FUNCTION f RETURN NUMBER IS BEGIN RETURN 1; END; SELECT f FROM dual", "SELECT 1; DELETE FROM notes", "BEGIN NULL; END;", "SELECT 'unfinished", "SELECT 1\0"] {
            XCTAssertNil(SQLStatementLocator.selectStatement(in: sql), sql)
        }
    }

    func testExportFramesDecodeProgressCompletionAndDatabaseErrors() throws {
        if case .progress(let rows) = try QueryExportFrame.decode(Data(#"{"exportProgress":12000}"#.utf8)) { XCTAssertEqual(rows, 12000) }
        else { XCTFail("Expected progress") }
        if case .complete(let summary) = try QueryExportFrame.decode(Data(#"{"exportComplete":{"rows":12000,"bytes":5000000,"elapsed":2.5}}"#.utf8)) { XCTAssertEqual(summary.rows, 12000); XCTAssertEqual(summary.bytes, 5_000_000) }
        else { XCTFail("Expected completion") }
        if case .failure(let error) = try QueryExportFrame.decode(Data(#"{"error":"disk full","stage":"session"}"#.utf8)) { XCTAssertEqual(error.message, "disk full") }
        else { XCTFail("Expected export error") }
        XCTAssertThrowsError(try QueryExportFrame.decode(Data(#"{"exportProgress":-1}"#.utf8)))
        XCTAssertThrowsError(try QueryExportFrame.decode(Data(#"{"rows":[]}"#.utf8)))
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return directory
    }
}

private final class ExportProgressProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var rows: [Int] = []
    func append(_ value: Int) { lock.lock(); defer { lock.unlock() }; rows.append(value) }
    var values: [Int] { lock.lock(); defer { lock.unlock() }; return rows }
}
