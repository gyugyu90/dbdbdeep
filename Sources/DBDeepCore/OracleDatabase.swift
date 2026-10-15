import Foundation

private final class OracleSession {
    let process = Process()
    let input = Pipe()
    let output = Pipe()

    init(connection: DBConnection, password: String, runtime: URL) throws {
        process.executableURL = runtime.appendingPathComponent("jre/bin/java")
        let classpath = runtime.appendingPathComponent("classes").path + ":" + runtime.appendingPathComponent("ojdbc11.jar").path
        process.arguments = ["-Djava.awt.headless=true", "-cp", classpath, "OracleBridge"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard FileManager.default.isExecutableFile(atPath: process.executableURL!.path) else {
            throw DatabaseError("Oracle 런타임이 없습니다. scripts/build-app.sh로 앱을 빌드해 주세요.")
        }
        try process.run()
        let address = connection.usesSID
            ? "jdbc:oracle:thin:@\(connection.host):\(connection.port):\(connection.service)"
            : "jdbc:oracle:thin:@//\(connection.host):\(connection.port)/\(connection.service)"
        do {
            try send([address, connection.username, password])
            _ = try receive()
        } catch {
            if process.isRunning { process.terminate() }
            throw error
        }
    }

    deinit {
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }

    private func send(_ fields: [String]) throws {
        guard process.isRunning else { throw DatabaseError("Oracle 세션이 종료되었습니다. 다시 연결해 주세요.") }
        for field in fields {
            let bytes = Data(field.utf8)
            var size = UInt32(bytes.count).bigEndian
            try withUnsafeBytes(of: &size) { try input.fileHandleForWriting.write(contentsOf: Data($0)) }
            try input.fileHandleForWriting.write(contentsOf: bytes)
        }
    }

    private func readExactly(_ count: Int) throws -> Data {
        var data = Data()
        while data.count < count {
            guard let part = try output.fileHandleForReading.read(upToCount: count - data.count), !part.isEmpty else {
                throw DatabaseError("Oracle 연결이 끊어졌습니다. 다시 연결해 주세요.")
            }
            data.append(part)
        }
        return data
    }

    private func receive() throws -> QueryResult {
        let header = try readExactly(4)
        let size = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard size <= 64_000_000 else { throw DatabaseError("Oracle 응답이 너무 큽니다.") }
        let payload = try readExactly(Int(size))
        struct Failure: Decodable { let error: String }
        if let failure = try? JSONDecoder().decode(Failure.self, from: payload) { throw DatabaseError(failure.error) }
        return try JSONDecoder().decode(QueryResult.self, from: payload)
    }

    func request(_ action: String, sql: String = "") throws -> QueryResult {
        try send([action, sql])
        return try receive()
    }
}

public actor OracleDatabase {
    private let connection: DBConnection
    private let runtime: URL
    private var session: OracleSession?

    public init(connection: DBConnection, runtime: URL) {
        self.connection = connection; self.runtime = runtime
    }

    public func connect(password: String) throws {
        session = try OracleSession(connection: connection, password: password, runtime: runtime)
    }

    public func execute(_ sql: String) throws -> QueryResult {
        guard let session else { throw DatabaseError("먼저 Oracle에 연결해 주세요.") }
        guard !sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw DatabaseError("실행할 SQL을 입력해 주세요.") }
        return try session.request("execute", sql: sql)
    }

    public func commit() throws -> QueryResult {
        guard let session else { throw DatabaseError("연결된 세션이 없습니다.") }
        return try session.request("commit")
    }

    public func rollback() throws -> QueryResult {
        guard let session else { throw DatabaseError("연결된 세션이 없습니다.") }
        return try session.request("rollback")
    }

    public func disconnect() { session = nil }

    private func schemaQuery(_ sql: String) throws -> QueryResult {
        guard let session else { throw DatabaseError("먼저 Oracle에 연결해 주세요.") }
        let result = try session.request("schema", sql: sql)
        guard !result.truncated else { throw DatabaseError("스키마가 100,000개 항목을 초과했습니다. 메타데이터 조회 범위를 줄여 주세요.") }
        return result
    }

    public func schema() throws -> [SchemaTable] {
        let tables = try schemaQuery("SELECT table_name, 'TABLE' AS object_type FROM user_tables UNION ALL SELECT view_name, 'VIEW' FROM user_views ORDER BY 1")
        let columns = try schemaQuery("""
        SELECT c.table_name, c.column_name, c.data_type,
               CASE WHEN p.column_name IS NOT NULL THEN 'Y' ELSE 'N' END AS is_pk, c.nullable
        FROM user_tab_columns c
        LEFT JOIN (
            SELECT cc.table_name, cc.column_name
            FROM user_cons_columns cc JOIN user_constraints k ON cc.constraint_name = k.constraint_name
            WHERE k.constraint_type = 'P'
        ) p ON c.table_name = p.table_name AND c.column_name = p.column_name
        ORDER BY c.table_name, c.column_id
        """)
        return tables.rows.compactMap { row in
            guard let name = row[0] else { return nil }
            return SchemaTable(name: name, isView: row[1] == "VIEW", columns: columns.rows.filter { $0[0] == name }.compactMap { column in
                guard let columnName = column[1] else { return nil }
                return SchemaColumn(name: columnName, type: column[2] ?? "", primaryKey: column[3] == "Y", nullable: column[4] == "Y")
            })
        }
    }
}
