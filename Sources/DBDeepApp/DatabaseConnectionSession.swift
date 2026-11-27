import Foundation
import DBDeepCore

protocol DatabaseConnectionSession: Actor {
    func connect(password: String, onEvent: @escaping ConnectionEventHandler) async throws
    func validateConnection() async throws
    func execute(_ sql: String) async throws -> QueryResult
    func exportCSV(_ sql: String, to destination: URL, onProgress: QueryExportProgressHandler) async throws -> QueryExportSummary
    func schema() async throws -> [SchemaTable]
    func collectionFields(_ name: String) async throws -> [SchemaColumn]
    func commit() async throws -> QueryResult
    func rollback() async throws -> QueryResult
    func disconnect() async
}

extension DatabaseConnectionSession {
    func exportCSV(_ sql: String, to destination: URL, onProgress: QueryExportProgressHandler) async throws -> QueryExportSummary {
        throw DatabaseError("Cursor CSV export is supported for Oracle and SQLite SELECT queries.")
    }
    func collectionFields(_ name: String) async throws -> [SchemaColumn] { [] }
}

extension OracleDatabase: DatabaseConnectionSession {}

extension MongoDatabase: DatabaseConnectionSession {}
