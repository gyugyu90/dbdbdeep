import Foundation
import CSQLite

public actor SQLiteDatabase {
    private var handle: OpaquePointer?
    public init(path: String) throws {
        var db: OpaquePointer?
        let status = sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard status == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "Could not open database."
            if let db { sqlite3_close_v2(db) }
            throw DatabaseError(message)
        }
        handle = db
        sqlite3_busy_timeout(db, 5000)
        sqlite3_exec(db, "PRAGMA foreign_keys = ON", nil, nil, nil)
    }

    deinit { if let handle { sqlite3_close_v2(handle) } }

    public func execute(_ sql: String, rowLimit: Int = 1000) throws -> QueryResult {
        guard let db = handle else { throw DatabaseError("Database is closed.") }
        let start = Date()
        var result = QueryResult()
        var statements = 0
        let changesBefore = sqlite3_total_changes(db)
        try sql.withCString { base in
            var cursor: UnsafePointer<CChar>? = base
            while let current = cursor, current.pointee != 0 {
                var statement: OpaquePointer?
                var tail: UnsafePointer<CChar>?
                let prepared = sqlite3_prepare_v2(db, current, -1, &statement, &tail)
                guard prepared == SQLITE_OK else { throw DatabaseError(String(cString: sqlite3_errmsg(db))) }
                cursor = tail
                guard let statement else { continue }
                defer { sqlite3_finalize(statement) }
                statements += 1
                let columnCount = Int(sqlite3_column_count(statement))
                var rows: [[String?]] = []
                var truncated = false
                var status = sqlite3_step(statement)
                while status == SQLITE_ROW {
                    if rows.count < rowLimit {
                        rows.append((0..<columnCount).map { index in
                            let i = Int32(index)
                            switch sqlite3_column_type(statement, i) {
                            case SQLITE_NULL: return nil
                            case SQLITE_BLOB: return "[BLOB · \(sqlite3_column_bytes(statement, i)) bytes]"
                            default:
                                guard let bytes = sqlite3_column_text(statement, i) else { return nil }
                                let size = Int(sqlite3_column_bytes(statement, i))
                                return String(decoding: UnsafeBufferPointer(start: bytes, count: size), as: UTF8.self)
                            }
                        })
                    } else {
                        truncated = true
                        if sqlite3_stmt_readonly(statement) != 0 { break }
                    }
                    status = sqlite3_step(statement)
                }
                guard status == SQLITE_DONE || (truncated && status == SQLITE_ROW) else {
                    throw DatabaseError(String(cString: sqlite3_errmsg(db)))
                }
                result.columns = (0..<columnCount).map { String(cString: sqlite3_column_name(statement, Int32($0))) }
                result.columnMetadata = (0..<columnCount).map { index in
                    ResultColumnMetadata(type: sqlite3_column_decltype(statement, Int32(index)).map { String(cString: $0) })
                }
                result.rows = rows
                result.truncated = truncated
            }
        }
        guard statements > 0 else { throw DatabaseError("실행할 SQL을 입력해 주세요.") }
        result.affected = Int(sqlite3_total_changes(db) - changesBefore)
        result.elapsed = Date().timeIntervalSince(start)
        result.message = statements > 1 ? "\(statements) statements executed · last result shown" : "Query completed"
        return result
    }

    public func exportCSV(_ sql: String, to destination: URL, onProgress: QueryExportProgressHandler = { _ in }) throws -> QueryExportSummary {
        guard let db = handle, let query = SQLStatementLocator.selectStatement(in: sql) else {
            throw DatabaseError("Full export requires one SELECT query, including SELECT with a WITH clause.")
        }
        let start = Date()
        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(db, query.text, -1, &statement, nil)
        guard prepared == SQLITE_OK, let statement else { throw DatabaseError(String(cString: sqlite3_errmsg(db))) }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_stmt_readonly(statement) != 0, sqlite3_column_count(statement) > 0 else { throw DatabaseError("Only read-only SELECT results can be exported with a cursor.") }
        let output = try AtomicQueryExport(destination: destination)
        defer { output.discard() }
        let writer = try CSVStreamWriter(url: output.temporary)
        let count = Int(sqlite3_column_count(statement))
        try writer.row((0..<count).map { String(cString: sqlite3_column_name(statement, Int32($0))) })
        var rows = 0
        var lastProgress = Date()
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            try writer.row((0..<count).map { index in
                let column = Int32(index)
                switch sqlite3_column_type(statement, column) {
                case SQLITE_NULL: return nil
                case SQLITE_BLOB:
                    let size = Int(sqlite3_column_bytes(statement, column))
                    guard size > 0, let bytes = sqlite3_column_blob(statement, column) else { return "0x" }
                    let digits = Array("0123456789ABCDEF".utf8)
                    let source = UnsafeRawBufferPointer(start: bytes, count: size)
                    var text = [UInt8](repeating: 0, count: size * 2 + 2)
                    text[0] = 48; text[1] = 120
                    for index in 0..<size {
                        text[index * 2 + 2] = digits[Int(source[index] >> 4)]
                        text[index * 2 + 3] = digits[Int(source[index] & 15)]
                    }
                    return String(decoding: text, as: UTF8.self)
                default:
                    guard let bytes = sqlite3_column_text(statement, column) else { return nil }
                    return String(decoding: UnsafeBufferPointer(start: bytes, count: Int(sqlite3_column_bytes(statement, column))), as: UTF8.self)
                }
            })
            rows += 1
            if rows.isMultiple(of: 1000), Date().timeIntervalSince(lastProgress) >= 0.1 {
                onProgress(rows); lastProgress = Date()
            }
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { throw DatabaseError(String(cString: sqlite3_errmsg(db))) }
        try writer.close()
        try output.finish()
        onProgress(rows)
        return QueryExportSummary(rows: rows, bytes: writer.bytes, elapsed: Date().timeIntervalSince(start))
    }

    public func schema() throws -> [SchemaTable] {
        let tables = try execute("SELECT name, type FROM sqlite_master WHERE type IN ('table', 'view') AND name NOT LIKE 'sqlite_%' ORDER BY name")
        return try tables.rows.compactMap { row in
            guard let name = row[0] else { return nil }
            let info = try execute("PRAGMA table_info(\(SQLIdentifier.quote(name)))")
            let columns = info.rows.compactMap { value -> SchemaColumn? in
                guard let column = value[1] else { return nil }
                return SchemaColumn(name: column, type: value[2] ?? "", primaryKey: value[5] != "0", nullable: value[3] == "0" && value[5] == "0")
            }
            return SchemaTable(name: name, isView: row[1] == "view", columns: columns)
        }
    }

    public func ensureTransaction() throws {
        guard let handle else { return }
        if sqlite3_get_autocommit(handle) != 0 { _ = try execute("BEGIN") }
    }

    public func seed() throws {
        let existing = try execute("SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'customers'")
        if !existing.rows.isEmpty { return }
        _ = try execute("""
        CREATE TABLE IF NOT EXISTS customers (
            id INTEGER PRIMARY KEY, name TEXT NOT NULL, email TEXT NOT NULL,
            plan TEXT NOT NULL DEFAULT 'starter', status TEXT NOT NULL DEFAULT 'active', joined_at TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS orders (
            id INTEGER PRIMARY KEY, customer_id INTEGER NOT NULL REFERENCES customers(id),
            total REAL NOT NULL, status TEXT NOT NULL, created_at TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS products (
            id INTEGER PRIMARY KEY, name TEXT NOT NULL, price REAL NOT NULL, stock INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS notes (id INTEGER PRIMARY KEY, content TEXT NOT NULL, created_at TEXT DEFAULT CURRENT_TIMESTAMP);
        """)
        let count = try execute("SELECT COUNT(*) FROM customers")
        if count.rows.first?.first == "0" {
            _ = try execute("""
            INSERT INTO customers VALUES
              (1, 'Olivia Park', 'olivia@mochi.studio', 'pro', 'active', '2026-10-01'),
              (2, 'Noah Kim', 'noah@littlecloud.io', 'starter', 'active', '2026-10-02'),
              (3, 'Emma Lee', 'emma@peach.design', 'team', 'active', '2026-10-03'),
              (4, 'Liam Choi', 'liam@softspace.co', 'pro', 'inactive', '2026-10-04'),
              (5, 'Ava Jung', 'ava@mintclub.io', 'starter', 'active', '2026-10-05'),
              (6, 'Oliver Han', 'oliver@bloom.app', 'team', 'active', '2026-10-06'),
              (7, 'Sophia Yoon', 'sophia@daylight.so', 'pro', 'active', '2026-10-07'),
              (8, 'James Shin', 'james@cosy.dev', 'starter', 'inactive', '2026-10-08');
            INSERT INTO orders VALUES (1, 1, 49.0, 'paid', '2026-10-03'), (2, 3, 129.0, 'paid', '2026-10-04'), (3, 5, 19.0, 'pending', '2026-10-06');
            INSERT INTO products VALUES (1, 'Cloud notebook', 19.0, 42), (2, 'Peach keyboard', 89.0, 18), (3, 'Mochi mouse pad', 12.0, 64);
            INSERT INTO notes (content) VALUES ('Welcome to your little data playground.');
            """)
        }
    }
}
