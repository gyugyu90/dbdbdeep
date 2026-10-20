import Foundation
import DBDeepCore

@MainActor
final class DatabaseSessions {
    private let directory: URL
    private let runtime: URL
    private let makeOracleSession: (DBConnection, URL) -> any OracleConnectionSession
    private var sqlite: SQLiteDatabase?
    private var oracle: [UUID: any OracleConnectionSession] = [:]

    init(directory: URL, runtime: URL, makeOracleSession: @escaping (DBConnection, URL) -> any OracleConnectionSession) {
        self.directory = directory
        self.runtime = runtime
        self.makeOracleSession = makeOracleSession
    }

    static var bundledOracleRuntime: URL {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("Oracle"),
           FileManager.default.fileExists(atPath: bundled.path) { return bundled }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".oracle")
    }

    func contains(_ connection: DBConnection) -> Bool {
        connection.kind == .sample ? sqlite != nil : oracle[connection.id] != nil
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
            let database = makeOracleSession(connection, runtime)
            try await database.connect(password: password, onEvent: onEvent)
            oracle[connection.id] = database
        }
    }

    func testConnection(_ connection: DBConnection, password: String, onEvent: @escaping ConnectionEventHandler) async throws {
        let database = makeOracleSession(connection, runtime)
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
            try await oracleSession(for: connection).validateConnection()
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
        return try await oracleSession(for: connection).execute(sql)
    }

    func schema(for connection: DBConnection) async throws -> [SchemaTable] {
        if connection.kind == .sample {
            guard let sqlite else { throw DatabaseError("먼저 연결해 주세요.") }
            return try await sqlite.schema()
        }
        return try await oracleSession(for: connection).schema()
    }

    func transaction(on connection: DBConnection, commit: Bool) async throws {
        if connection.kind == .sample {
            guard let sqlite else { throw DatabaseError("먼저 연결해 주세요.") }
            _ = try await sqlite.execute(commit ? "COMMIT; BEGIN" : "ROLLBACK; BEGIN")
        } else {
            let database = try oracleSession(for: connection)
            _ = try await (commit ? database.commit() : database.rollback())
        }
    }

    func disconnect(_ connection: DBConnection) async {
        if connection.kind == .sample { sqlite = nil }
        else if let database = oracle.removeValue(forKey: connection.id) { await database.disconnect() }
    }

    private func oracleSession(for connection: DBConnection) throws -> any OracleConnectionSession {
        guard let database = oracle[connection.id] else { throw DatabaseError("먼저 Oracle에 연결해 주세요.") }
        return database
    }
}
