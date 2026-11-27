import Foundation
import DBDeepCore

@MainActor
final class DatabaseSessions {
    private let directory: URL
    private let runtime: URL
    private let makeOracleSession: (DBConnection, URL) -> any DatabaseConnectionSession
    private let makeMongoSession: (DBConnection, URL) -> any DatabaseConnectionSession
    private var sqlite: SQLiteDatabase?
    private var remote: [UUID: any DatabaseConnectionSession] = [:]

    init(directory: URL, runtime: URL, makeOracleSession: @escaping (DBConnection, URL) -> any DatabaseConnectionSession, makeMongoSession: @escaping (DBConnection, URL) -> any DatabaseConnectionSession) {
        self.directory = directory
        self.runtime = runtime
        self.makeOracleSession = makeOracleSession
        self.makeMongoSession = makeMongoSession
    }

    static var bundledRuntime: URL {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("Oracle"),
           FileManager.default.fileExists(atPath: bundled.path) { return bundled }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".oracle")
    }

    func contains(_ connection: DBConnection) -> Bool {
        connection.kind == .sample ? sqlite != nil : remote[connection.id] != nil
    }

    func connect(_ connection: DBConnection, password: String = "", onEvent: @escaping ConnectionEventHandler = { _ in }) async throws {
        if connection.kind == .sample {
            if sqlite == nil {
                let database = try SQLiteDatabase(path: directory.appendingPathComponent("playground.sqlite").path)
                try await database.seed()
                _ = try await database.execute("BEGIN")
                sqlite = database
            }
        } else {
            let database = connection.kind == .mongodb ? makeMongoSession(connection, runtime) : makeOracleSession(connection, runtime)
            try await database.connect(password: password, onEvent: onEvent)
            remote[connection.id] = database
        }
    }

    func testConnection(_ connection: DBConnection, password: String, onEvent: @escaping ConnectionEventHandler) async throws {
        let database = connection.kind == .mongodb ? makeMongoSession(connection, runtime) : makeOracleSession(connection, runtime)
        do { try await database.connect(password: password, onEvent: onEvent) }
        catch {
            await database.disconnect()
            throw error
        }
        await database.disconnect()
    }

    func validate(_ connection: DBConnection) async throws {
        if connection.kind == .sample {
            guard sqlite != nil else { throw DatabaseError("먼저 연결해 주세요.") }
        } else {
            try await remoteSession(for: connection).validateConnection()
        }
    }

    func execute(_ sql: String, on connection: DBConnection) async throws -> QueryResult {
        if connection.kind == .sample {
            guard let sqlite else { throw DatabaseError("먼저 연결해 주세요.") }
            do {
                let result = try await sqlite.execute(sql)
                try await sqlite.ensureTransaction()
                return result
            } catch {
                try? await sqlite.ensureTransaction()
                throw error
            }
        }
        return try await remoteSession(for: connection).execute(sql)
    }

    func exportCSV(_ sql: String, on connection: DBConnection, to destination: URL, onProgress: @escaping QueryExportProgressHandler) async throws -> QueryExportSummary {
        if connection.kind == .sample {
            guard let sqlite else { throw DatabaseError("먼저 연결해 주세요.") }
            return try await sqlite.exportCSV(sql, to: destination, onProgress: onProgress)
        }
        guard connection.kind == .oracle else { throw DatabaseError("Full CSV export requires an Oracle or SQLite SELECT query.") }
        return try await remoteSession(for: connection).exportCSV(sql, to: destination, onProgress: onProgress)
    }

    func schema(for connection: DBConnection) async throws -> [SchemaTable] {
        if connection.kind == .sample {
            guard let sqlite else { throw DatabaseError("먼저 연결해 주세요.") }
            return try await sqlite.schema()
        }
        return try await remoteSession(for: connection).schema()
    }

    func transaction(on connection: DBConnection, commit: Bool) async throws {
        guard connection.supportsTransactions else { throw DatabaseError("MongoDB writes are applied immediately.") }
        if connection.kind == .sample {
            guard let sqlite else { throw DatabaseError("먼저 연결해 주세요.") }
            _ = try await sqlite.execute(commit ? "COMMIT; BEGIN" : "ROLLBACK; BEGIN")
        } else {
            let database = try remoteSession(for: connection)
            _ = try await (commit ? database.commit() : database.rollback())
        }
    }

    func collectionFields(_ name: String, on connection: DBConnection) async throws -> [SchemaColumn] {
        try await remoteSession(for: connection).collectionFields(name)
    }

    func disconnect(_ connection: DBConnection) async {
        if connection.kind == .sample { sqlite = nil }
        else if let database = remote.removeValue(forKey: connection.id) { await database.disconnect() }
    }

    private func remoteSession(for connection: DBConnection) throws -> any DatabaseConnectionSession {
        guard let database = remote[connection.id] else { throw DatabaseError("먼저 데이터베이스에 연결해 주세요.") }
        return database
    }
}
