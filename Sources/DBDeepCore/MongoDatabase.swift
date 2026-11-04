import Foundation

private final class MongoProcessErrorBuffer: @unchecked Sendable {
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

private final class MongoSession {
    let process = Process()
    let input = Pipe()
    let output = Pipe()
    private let errors = Pipe()
    private let errorBuffer = MongoProcessErrorBuffer()

    private init(connection: DBConnection, runtime: URL) throws {
        let java = runtime.appendingPathComponent("jre/bin/java")
        let classes = runtime.appendingPathComponent("classes")
        guard FileManager.default.isExecutableFile(atPath: java.path),
              FileManager.default.fileExists(atPath: classes.appendingPathComponent("MongoBridge.class").path) else {
            throw OracleConnectionFailure(message: "MongoDB 런타임 파일이 없습니다. scripts/build-app.sh로 앱을 다시 빌드해 주세요.", details: ["Runtime: \(runtime.path)"], stage: .runtime)
        }
        let libraries = ["bson.jar", "mongodb-driver-core.jar", "mongodb-driver-sync.jar"].map { runtime.appendingPathComponent($0) }
        try OracleDriverLibraries.validate(libraries)
        process.executableURL = java
        process.arguments = ["-Djava.awt.headless=true", "-cp", ([classes.path] + libraries.map(\.path)).joined(separator: ":"), "MongoBridge"]
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

    static func open(connection: DBConnection, password: String, runtime: URL, onEvent: ConnectionEventHandler) async throws -> MongoSession {
        await onEvent(ConnectionEvent(stage: .runtime, message: "번들 MongoDB 런타임 확인 · \(runtime.path)"))
        do {
            let session = try MongoSession(connection: connection, runtime: runtime)
            await onEvent(ConnectionEvent(stage: .runtime, level: .success, message: "MongoDB 브리지 프로세스를 시작했습니다."))
            let libraries = ["bson.jar", "mongodb-driver-core.jar", "mongodb-driver-sync.jar"].map { runtime.appendingPathComponent($0) }
            await onEvent(ConnectionEvent(stage: .driver, message: "사용하는 JAR 파일:\n" + libraries.map(\.path).joined(separator: "\n")))
            let config: [String: String] = ["uri": connection.mongoURI, "database": connection.service,
                "username": connection.username, "password": password, "authSource": connection.effectiveMongoAuthSource]
            let payload = try JSONSerialization.data(withJSONObject: config)
            try session.send([String(decoding: payload, as: UTF8.self)])
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
        guard process.isRunning else { throw DatabaseError("MongoDB 세션이 종료되었습니다. 다시 연결해 주세요.") }
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
                throw OracleConnectionFailure(message: "MongoDB 브리지의 응답이 종료되었습니다. \(details.isEmpty ? "연결 또는 런타임 상태를 확인해 주세요." : details)", stage: .runtime)
            }
            data.append(part)
        }
        return data
    }

    private func receiveFrame() throws -> OracleBridgeFrame {
        let header = try readExactly(4)
        let size = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard size <= 64_000_000 else { throw DatabaseError("MongoDB 응답이 너무 큽니다.") }
        return try OracleBridgeFrame.decode(readExactly(Int(size)))
    }

    func request(_ action: String, sql: String = "") throws -> QueryResult {
        try send([action, sql])
        switch try receiveFrame() {
        case .result(let result): return result
        case .failure(let failure): throw failure
        case .event: throw DatabaseError("예상하지 못한 MongoDB 응답입니다. 앱을 다시 실행해 주세요.")
        }
    }
}

public actor MongoDatabase {
    private let connection: DBConnection
    private let runtime: URL
    private var session: MongoSession?
    private var fieldCache: [String: (date: Date, columns: [SchemaColumn])] = [:]

    public init(connection: DBConnection, runtime: URL) {
        self.connection = connection; self.runtime = runtime
    }

    public func connect(password: String, onEvent: @escaping ConnectionEventHandler = { _ in }) async throws {
        if let error = connection.configurationError { throw DatabaseError(error) }
        session = try await MongoSession.open(connection: connection, password: password, runtime: runtime, onEvent: onEvent)
    }

    public func execute(_ command: String) throws -> QueryResult {
        guard let session else { throw DatabaseError("먼저 MongoDB에 연결해 주세요.") }
        guard let statement = MongoQueryDocument.singleStatement(in: command) else {
            throw DatabaseError("Enter one complete MongoDB query, such as db.customers.find({}).limit(100), or a JSON command.")
        }
        return try session.request("execute", sql: statement.text)
    }

    public func validateConnection() throws {
        guard let session else { throw DatabaseError("연결된 세션이 없습니다.") }
        _ = try session.request("validate")
    }

    public func schema() throws -> [SchemaTable] {
        guard let session else { throw DatabaseError("먼저 MongoDB에 연결해 주세요.") }
        return try session.request("schema").rows.compactMap { row in
            guard let name = row.first ?? nil else { return nil }
            return SchemaTable(name: name, columns: fieldCache[name]?.columns ?? [])
        }
    }

    public func collectionFields(_ name: String) throws -> [SchemaColumn] {
        guard let session else { throw DatabaseError("먼저 MongoDB에 연결해 주세요.") }
        if let cached = fieldCache[name], Date().timeIntervalSince(cached.date) < 60 { return cached.columns }
        if fieldCache.count >= 256 { fieldCache.removeAll() }
        fieldCache[name] = (Date(), [])
        let result = try session.request("fields", sql: name)
        let columns = result.rows.compactMap { row -> SchemaColumn? in
            guard row.count >= 2, let name = row[0], let type = row[1] else { return nil }
            return SchemaColumn(name: name, type: type, primaryKey: name == "_id")
        }
        fieldCache[name] = (Date(), columns)
        return columns
    }

    public func commit() throws -> QueryResult { throw DatabaseError("MongoDB writes are applied immediately; manual commit is unavailable.") }
    public func rollback() throws -> QueryResult { throw DatabaseError("MongoDB writes are applied immediately; rollback is unavailable.") }
    public func disconnect() { session = nil; fieldCache.removeAll() }
}
