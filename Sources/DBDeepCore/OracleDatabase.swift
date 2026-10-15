import Foundation

public typealias ConnectionEventHandler = @Sendable (ConnectionEvent) async -> Void

private final class ProcessErrorBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        data.append(chunk.prefix(max(0, 8192 - data.count)))
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private final class OracleSession {
    let process = Process()
    let input = Pipe()
    let output = Pipe()
    private let errors = Pipe()
    private let errorBuffer = ProcessErrorBuffer()

    private init(connection: DBConnection, runtime: URL) throws {
        let java = runtime.appendingPathComponent("jre/bin/java")
        let classes = runtime.appendingPathComponent("classes")
        guard FileManager.default.isExecutableFile(atPath: java.path),
              FileManager.default.fileExists(atPath: classes.appendingPathComponent("OracleBridge.class").path) else {
            throw OracleConnectionFailure(message: "Oracle 런타임 파일이 없습니다. scripts/build-app.sh로 앱을 다시 빌드해 주세요.", details: ["Runtime: \(runtime.path)"], stage: .runtime)
        }
        let libraries = OracleDriverLibraries.resolve(connection: connection, runtime: runtime)
        try OracleDriverLibraries.validate(libraries)
        process.executableURL = java
        process.arguments = ["-Djava.awt.headless=true", "-cp", ([classes.path] + libraries.map(\.path)).joined(separator: ":"), "OracleBridge"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        let buffer = errorBuffer
        errors.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            else { buffer.append(data) }
        }
        try process.run()
    }

    static func open(connection: DBConnection, password: String, runtime: URL, onEvent: ConnectionEventHandler) async throws -> OracleSession {
        await onEvent(ConnectionEvent(stage: .runtime, message: "번들 Oracle 런타임 확인 · \(runtime.path)"))
        do {
            let session = try OracleSession(connection: connection, runtime: runtime)
            await onEvent(ConnectionEvent(stage: .runtime, level: .success, message: "Java 브리지 프로세스를 시작했습니다."))
            let libraries = OracleDriverLibraries.resolve(connection: connection, runtime: runtime)
            await onEvent(ConnectionEvent(stage: .driver, message: "사용하는 JAR 파일:\n" + libraries.map(\.path).joined(separator: "\n")))
            try session.send([connection.jdbcURL, connection.username, password])
            while true {
                switch try session.receiveFrame() {
                case .event(let event):
                    await onEvent(ConnectionEvent(stage: event.stage, level: event.level, message: DiagnosticRedactor.redact(event.message, password: password), date: event.date))
                case .failure(let failure): throw failure
                case .result: return session
                }
            }
        } catch let failure as OracleConnectionFailure { throw failure.redacted(password: password) }
        catch {
            throw OracleConnectionFailure(message: DiagnosticRedactor.redact(error.localizedDescription, password: password), stage: .runtime)
        }
    }

    deinit {
        errors.fileHandleForReading.readabilityHandler = nil
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
                let details = errorBuffer.text
                throw OracleConnectionFailure(message: "Oracle 브리지의 응답이 종료되었습니다. \(details.isEmpty ? "연결 또는 런타임 상태를 확인해 주세요." : details)", stage: .runtime)
            }
            data.append(part)
        }
        return data
    }

    private func receiveFrame() throws -> OracleBridgeFrame {
        let header = try readExactly(4)
        let size = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard size <= 64_000_000 else { throw DatabaseError("Oracle 응답이 너무 큽니다.") }
        return try OracleBridgeFrame.decode(readExactly(Int(size)))
    }

    func request(_ action: String, sql: String = "") throws -> QueryResult {
        try send([action, sql])
        switch try receiveFrame() {
        case .result(let result): return result
        case .failure(let failure): throw failure
        case .event: throw DatabaseError("예상하지 못한 Oracle 응답입니다. 앱을 다시 실행해 주세요.")
        }
    }
}

public actor OracleDatabase {
    private let connection: DBConnection
    private let runtime: URL
    private var session: OracleSession?

    public init(connection: DBConnection, runtime: URL) {
        self.connection = connection; self.runtime = runtime
    }

    public func connect(password: String, onEvent: @escaping ConnectionEventHandler = { _ in }) async throws {
        session = try await OracleSession.open(connection: connection, password: password, runtime: runtime, onEvent: onEvent)
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
