import DBDeepCore

protocol OracleConnectionSession: Actor {
    func connect(password: String, onEvent: @escaping ConnectionEventHandler) async throws
    func validateConnection() async throws
    func execute(_ sql: String) async throws -> QueryResult
    func schema() async throws -> [SchemaTable]
    func commit() async throws -> QueryResult
    func rollback() async throws -> QueryResult
    func disconnect() async
}

extension OracleDatabase: OracleConnectionSession {}
