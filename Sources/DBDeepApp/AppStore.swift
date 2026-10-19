import AppKit
import SwiftUI
import DBDeepCore

@MainActor
final class AppStore: ObservableObject {
    @Published var connections: [DBConnection] = []
    @Published var bookmarks: [QueryBookmark] = []
    @Published var selectedID: UUID?
    @Published var query = ""
    @Published var selectedSQL = ""
    @Published var cursorLocation = 0
    @Published var tables: [SchemaTable] = []
    @Published var results: [UUID: QueryResult] = [:]
    @Published var connectedIDs: Set<UUID> = []
    @Published var isBusy = false
    @Published var error: String?
    @Published var status = "Ready when you are"
    @Published var showConnection = false
    @Published var editingConnection: DBConnection?
    @Published var connectionAttempts: [UUID: ConnectionAttempt] = [:]
    @Published var diagnosticConnectionID: UUID?
    @Published var showConnectionDetails = false
    @Published var showBookmark = false
    @Published var editingBookmark: QueryBookmark?
    @Published var schemaSearch = ""
    @Published var bookmarkSearch = ""
    @Published var bookmarkFilter: String?
    @Published var history: [(sql: String, time: Date)] = []
    @Published var showHistory = false
    @Published var showBookmarks = true
    @Published var expandedTables: Set<String> = ["customers"]

    let directory: URL
    private var sqlite: SQLiteDatabase?
    private var oracle: [UUID: any OracleConnectionSession] = [:]
    private let makeOracleSession: (DBConnection, URL) -> any OracleConnectionSession
    private let readPassword: (UUID) throws -> String
    private var drafts: [String: String] = [:]
    private var persistWork: DispatchWorkItem?
    private var schemaByConnection: [UUID: [SchemaTable]] = [:]

    var connection: DBConnection? { connections.first { $0.id == selectedID } }
    var result: QueryResult? { selectedID.flatMap { results[$0] } }
    var isConnected: Bool { selectedID.map { connectedIDs.contains($0) } ?? false }
    var sqlToRun: String { selectedSQL.isEmpty ? SQLStatementLocator.statement(in: query, atUTF16Offset: cursorLocation)?.text ?? "" : selectedSQL }
    var canRunQuery: Bool { connection != nil && !isBusy && !sqlToRun.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var filteredTables: [SchemaTable] { tables.filter { schemaSearch.isEmpty || $0.name.localizedCaseInsensitiveContains(schemaSearch) } }
    var filteredBookmarks: [QueryBookmark] {
        bookmarks.filter { (bookmarkSearch.isEmpty || $0.name.localizedCaseInsensitiveContains(bookmarkSearch) || $0.sql.localizedCaseInsensitiveContains(bookmarkSearch)) && (bookmarkFilter == nil || $0.color == bookmarkFilter) }
    }

    init(directory: URL? = nil,
         makeOracleSession: @escaping (DBConnection, URL) -> any OracleConnectionSession = { OracleDatabase(connection: $0, runtime: $1) },
         readPassword: @escaping (UUID) throws -> String = { try PasswordKeychain.read(for: $0) }) {
        self.makeOracleSession = makeOracleSession
        self.readPassword = readPassword
        let workspaceName = Bundle.main.bundleIdentifier == "studio.dbdbdeep.preview" ? "DBDeep Preview" : "DBDeep"
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(workspaceName)
        do {
            try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
            let file = self.directory.appendingPathComponent("workspace.json")
            if FileManager.default.fileExists(atPath: file.path) {
                let state = try JSONDecoder().decode(WorkspaceState.self, from: Data(contentsOf: file))
                connections = state.connections; bookmarks = state.bookmarks; drafts = state.drafts
                selectedID = state.selectedConnection ?? connections.first?.id
            } else {
                let sample = DBConnection(name: "Little playground", kind: .sample, color: "mint")
                connections = [sample]; selectedID = sample.id
                bookmarks = [
                    QueryBookmark(name: "All the lovely customers", emoji: "🌷", color: "lavender", sql: Self.sampleQuery, connectionID: sample.id),
                    QueryBookmark(name: "Who's on the pro plan?", emoji: "⚡️", color: "peach", sql: "SELECT name, email, plan\nFROM customers\nWHERE plan = 'pro';", connectionID: sample.id),
                    QueryBookmark(name: "A little order check", emoji: "🧺", color: "mint", sql: "SELECT o.id, c.name, o.total, o.status\nFROM orders o\nJOIN customers c ON c.id = o.customer_id;", connectionID: sample.id),
                    QueryBookmark(name: "Make room for a new note", emoji: "✏️", color: "yellow", sql: "INSERT INTO notes (content)\nVALUES ('Something good is on its way.');", connectionID: sample.id)
                ]
            }
            query = selectedID.flatMap { drafts[$0.uuidString] } ?? defaultQuery
        } catch { self.error = "작업 공간을 읽을 수 없습니다: \(error.localizedDescription)" }
    }

    static let sampleQuery = "-- A little peek at our customers 🌷\nSELECT\n    id, name, email, plan, status\nFROM customers\nORDER BY id;"
    var oracleRuntime: URL {
        let bundled = Bundle.main.resourceURL!.appendingPathComponent("Oracle")
        return FileManager.default.fileExists(atPath: bundled.path) ? bundled : URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".oracle")
    }
    var defaultQuery: String { connection?.kind == .oracle ? "-- Hello, Oracle ✨\nSELECT *\nFROM user_tables\nFETCH FIRST 100 ROWS ONLY;" : Self.sampleQuery }

    func start() async {
        guard let connection, connection.kind == .sample else { return }
        await connect(connection)
        if isConnected && query == Self.sampleQuery { await run() }
    }

    func select(_ target: DBConnection) {
        guard !isBusy, target.id != selectedID else { return }
        if let selectedID { drafts[selectedID.uuidString] = query }
        selectedID = target.id; selectedSQL = ""; cursorLocation = 0; error = nil
        query = drafts[target.id.uuidString] ?? defaultQuery
        tables = schemaByConnection[target.id] ?? []
        status = connectedIDs.contains(target.id) ? "Connected · ready when you are" : "Run a query to connect"
        persist()
        if target.kind == .sample && !connectedIDs.contains(target.id) { Task { await connect(target) } }
    }

    private func beginAttempt(_ target: DBConnection, purpose: String, savedPassword: Bool) -> UUID {
        var attempt = ConnectionAttempt(connection: target, purpose: purpose)
        attempt.record(ConnectionEvent(stage: .credentials, message: savedPassword ? "macOS Keychain에서 저장된 비밀번호를 읽습니다." : "입력한 비밀번호를 사용합니다. 로그에는 포함하지 않습니다."))
        connectionAttempts[target.id] = attempt
        return attempt.id
    }

    private func record(_ event: ConnectionEvent, connectionID: UUID, attemptID: UUID) {
        guard connectionAttempts[connectionID]?.id == attemptID else { return }
        connectionAttempts[connectionID]?.record(event)
    }

    private func finishFailure(_ error: Error, target: DBConnection, attemptID: UUID) {
        guard let attempt = connectionAttempts[target.id], attempt.id == attemptID else { return }
        let failure = error as? OracleConnectionFailure ?? OracleConnectionFailure(message: error.localizedDescription, stage: attempt.events.last?.stage)
        record(ConnectionEvent(stage: failure.stage ?? .connecting, level: .error, message: failure.message), connectionID: target.id, attemptID: attemptID)
        connectionAttempts[target.id]?.finish(.failed, failure: failure)
    }

    func testConnection(_ target: DBConnection, password: String) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        let attemptID = beginAttempt(target, purpose: "Test connection", savedPassword: password.isEmpty)
        do {
            let secret = try password.isEmpty ? PasswordKeychain.read(for: target.id) : password
            record(ConnectionEvent(stage: .credentials, level: .success, message: "접속 계정을 준비했습니다 · \(target.username)"), connectionID: target.id, attemptID: attemptID)
            let database = OracleDatabase(connection: target, runtime: oracleRuntime)
            try await database.connect(password: secret) { [weak self] event in
                await self?.record(event, connectionID: target.id, attemptID: attemptID)
            }
            await database.disconnect()
            record(ConnectionEvent(stage: .session, level: .success, message: "테스트 세션을 닫았습니다. 데이터 변경은 없습니다."), connectionID: target.id, attemptID: attemptID)
            connectionAttempts[target.id]?.finish(.succeeded)
        } catch { finishFailure(error, target: target, attemptID: attemptID) }
    }

    @discardableResult
    func connect(_ target: DBConnection, password: String? = nil) async -> Bool {
        guard !isBusy else { return false }
        isBusy = true; error = nil; status = "Connecting…"
        defer { isBusy = false }
        return await openConnection(target, password: password)
    }

    private func openConnection(_ target: DBConnection, password: String? = nil, purpose: String = "Connect") async -> Bool {
        var attemptID: UUID?
        do {
            if target.kind == .sample {
                if sqlite == nil {
                    let database = try SQLiteDatabase(path: directory.appendingPathComponent("playground.sqlite").path)
                    try await database.seed()
                    _ = try await database.execute("BEGIN")
                    sqlite = database
                }
            } else {
                let identifier = beginAttempt(target, purpose: purpose, savedPassword: password == nil)
                attemptID = identifier
                let secret = try password ?? readPassword(target.id)
                record(ConnectionEvent(stage: .credentials, level: .success, message: "접속 계정을 준비했습니다 · \(target.username)"), connectionID: target.id, attemptID: identifier)
                let database = makeOracleSession(target, oracleRuntime)
                try await database.connect(password: secret) { [weak self] event in
                    await self?.record(event, connectionID: target.id, attemptID: identifier)
                }
                oracle[target.id] = database
            }
            connectedIDs.insert(target.id)
            status = "Connected · \(target.name)"
            if let attemptID { record(ConnectionEvent(stage: .schema, message: "현재 계정의 테이블·뷰·컬럼을 조회합니다."), connectionID: target.id, attemptID: attemptID) }
            do {
                try await loadSchema(target)
                if let attemptID {
                    record(ConnectionEvent(stage: .schema, level: .success, message: "스키마를 불러왔습니다 · \(schemaByConnection[target.id]?.count ?? 0) tables / views"), connectionID: target.id, attemptID: attemptID)
                    connectionAttempts[target.id]?.finish(.succeeded)
                }
            } catch {
                self.error = "연결되었습니다. 스키마를 불러올 수 없습니다: \(error.localizedDescription)"
                if let attemptID {
                    let failure = OracleConnectionFailure(message: error.localizedDescription, stage: .schema)
                    record(ConnectionEvent(stage: .schema, level: .warning, message: failure.message), connectionID: target.id, attemptID: attemptID)
                    connectionAttempts[target.id]?.finish(.partial, failure: failure)
                }
            }
            return true
        } catch {
            if let attemptID { finishFailure(error, target: target, attemptID: attemptID) }
            self.error = error.localizedDescription; status = "Connection failed"
            return false
        }
    }

    func saveConnection(_ target: DBConnection, password: String) async -> Bool {
        guard !isBusy else { return false }
        do {
            if !password.isEmpty { try PasswordKeychain.save(password, for: target.id) }
            else { _ = try PasswordKeychain.read(for: target.id) }
            if let old = oracle.removeValue(forKey: target.id) { await old.disconnect() }
            connectedIDs.remove(target.id)
            schemaByConnection.removeValue(forKey: target.id)
            if let index = connections.firstIndex(where: { $0.id == target.id }) { connections[index] = target }
            else { connections.append(target) }
            select(target)
            persist()
            let connected = await connect(target, password: password.isEmpty ? nil : password)
            if connected && connectionAttempts[target.id]?.outcome == .succeeded { showConnection = false }
            return connected
        } catch {
            let attemptID = beginAttempt(target, purpose: "Save & connect", savedPassword: password.isEmpty)
            finishFailure(error, target: target, attemptID: attemptID)
            self.error = error.localizedDescription
            return false
        }
    }

    func removeConnection(_ target: DBConnection) async {
        guard !isBusy, target.kind != .sample else { return }
        if let db = oracle.removeValue(forKey: target.id) { await db.disconnect() }
        PasswordKeychain.delete(for: target.id)
        connections.removeAll { $0.id == target.id }
        connectedIDs.remove(target.id); results.removeValue(forKey: target.id)
        schemaByConnection.removeValue(forKey: target.id); drafts.removeValue(forKey: target.id.uuidString)
        if selectedID == target.id {
            selectedID = nil
            if let first = connections.first { select(first) }
        }
        persist()
    }

    private func loadSchema(_ target: DBConnection) async throws {
        let snapshot: [SchemaTable]
        if target.kind == .sample, let sqlite { snapshot = try await sqlite.schema() }
        else if let db = oracle[target.id] { snapshot = try await db.schema() }
        else { return }
        schemaByConnection[target.id] = snapshot
        if selectedID == target.id { tables = snapshot }
    }

    func refreshSchema() async {
        guard let connection, isConnected, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do { try await loadSchema(connection) } catch { self.error = error.localizedDescription }
    }

    func run() async {
        guard let connection, canRunQuery else { return }
        let sql = sqlToRun
        isBusy = true; error = nil
        defer { isBusy = false }
        guard await prepareConnectionForQuery(connection) else { return }
        status = "A little query in progress…"
        do {
            let output: QueryResult
            if connection.kind == .sample, let sqlite {
                output = try await sqlite.execute(sql)
                try await sqlite.ensureTransaction()
            }
            else if let db = oracle[connection.id] { output = try await db.execute(sql) }
            else { throw DatabaseError("먼저 연결해 주세요.") }
            results[connection.id] = output
            history.insert((sql, Date()), at: 0)
            history = Array(history.prefix(50))
            status = output.message
            do { try await loadSchema(connection) }
            catch { status += " · schema refresh unavailable" }
            persist()
        } catch {
            if connection.kind == .sample { try? await sqlite?.ensureTransaction() }
            else if let database = oracle[connection.id] {
                do { try await database.validateConnection() }
                catch { await invalidateOracleSession(connection) }
            }
            self.error = error.localizedDescription
            status = connectedIDs.contains(connection.id) ? "Query needs a little attention" : "Connection lost · run again to reconnect"
        }
    }

    private func prepareConnectionForQuery(_ target: DBConnection) async -> Bool {
        if target.kind == .sample {
            if sqlite != nil && connectedIDs.contains(target.id) { return true }
        } else if let database = oracle[target.id] {
            status = "Checking connection…"
            do {
                try await database.validateConnection()
                connectedIDs.insert(target.id)
                return true
            } catch {
                await invalidateOracleSession(target)
            }
        }
        status = "Connecting before query…"
        return await openConnection(target, purpose: "Connect before query")
    }

    private func invalidateOracleSession(_ target: DBConnection) async {
        connectedIDs.remove(target.id)
        results.removeValue(forKey: target.id)
        schemaByConnection.removeValue(forKey: target.id)
        if selectedID == target.id { tables = [] }
        if let database = oracle.removeValue(forKey: target.id) { await database.disconnect() }
    }

    func transaction(commit: Bool) async {
        guard let connection, isConnected, !isBusy else { return }
        isBusy = true; error = nil
        defer { isBusy = false }
        do {
            if connection.kind == .sample, let sqlite {
                _ = try await sqlite.execute(commit ? "COMMIT; BEGIN" : "ROLLBACK; BEGIN")
            } else if let db = oracle[connection.id] {
                _ = try await (commit ? db.commit() : db.rollback())
            }
            status = commit ? "Changes committed ✓" : "Changes rolled back ↶"
            results.removeValue(forKey: connection.id)
            try await loadSchema(connection)
        } catch { self.error = error.localizedDescription }
    }

    func browse(_ table: SchemaTable) {
        query = connection?.kind == .oracle
            ? "SELECT *\nFROM \(SQLIdentifier.quote(table.name))\nFETCH FIRST 100 ROWS ONLY;"
            : "SELECT *\nFROM \(SQLIdentifier.quote(table.name))\nLIMIT 100;"
        selectedSQL = ""
        cursorLocation = 0
        Task { await run() }
    }

    func loadBookmark(_ bookmark: QueryBookmark) {
        guard !isBusy else { return }
        if let id = bookmark.connectionID, let target = connections.first(where: { $0.id == id }) { select(target) }
        query = bookmark.sql; selectedSQL = ""; cursorLocation = 0; persist()
        status = "Bookmark loaded · \(bookmark.name)"
    }

    func saveBookmark(_ bookmark: QueryBookmark) {
        if let index = bookmarks.firstIndex(where: { $0.id == bookmark.id }) { bookmarks[index] = bookmark }
        else { bookmarks.insert(bookmark, at: 0) }
        persist(); showBookmark = false
    }

    func removeBookmark(_ bookmark: QueryBookmark) {
        bookmarks.removeAll { $0.id == bookmark.id }; persist()
    }

    func newBookmark() { editingBookmark = nil; showBookmark = true }
    func newConnection() { editingConnection = nil; showConnection = true }

    func queryChanged() {
        persistWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.persist() }
        persistWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func persist() {
        if let selectedID { drafts[selectedID.uuidString] = query }
        let state = WorkspaceState(connections: connections, bookmarks: bookmarks, drafts: drafts, selectedConnection: selectedID)
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(state).write(to: directory.appendingPathComponent("workspace.json"), options: .atomic)
        } catch { self.error = "저장 실패: \(error.localizedDescription)" }
    }

    func exportCSV() {
        guard let result, !result.columns.isEmpty else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "query-result.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try result.csv.write(to: url, atomically: true, encoding: .utf8); status = "CSV exported ✓" }
        catch { self.error = error.localizedDescription }
    }
}
