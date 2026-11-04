import DBDeepCore

protocol DatabaseConnectionSession: Actor {
    func connect(password: String, onEvent: @escaping ConnectionEventHandler) async throws
    func validateConnection() async throws
    func execute(_ sql: String) async throws -> QueryResult
    func schema() async throws -> [SchemaTable]
    func collectionFields(_ name: String) async throws -> [SchemaColumn]
    func commit() async throws -> QueryResult
    func rollback() async throws -> QueryResult
    func disconnect() async
}

extension DatabaseConnectionSession {
    func collectionFields(_ name: String) async throws -> [SchemaColumn] { [] }
}

extension OracleDatabase: DatabaseConnectionSession {}

extension MongoDatabase: DatabaseConnectionSession {}
