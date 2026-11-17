import Foundation
import Combine
import DBDeepCore

@MainActor
final class AppStore: ObservableObject {
    @Published var connections: [DBConnection] = []
    @Published var bookmarks: [QueryBookmark] = []
    @Published var selectedID: UUID?
    @Published var query = "" {
        didSet {
            cachedStatements = nil; cachedLineCount = nil; cachedCursorTarget = nil; cachedBookmarkKey = nil
            if query != oldValue { queryChanged() }
        }
    }
    @Published var selectedSQL = ""
    @Published var cursorLocation = 0 {
        didSet { cachedCursorTarget = nil; cachedBookmarkKey = nil }
    }
    @Published private(set) var editorFocusRequest: SQLEditorFocus?
    @Published var tables: [SchemaTable] = []
    @Published var results: [UUID: QueryResult] = [:]
    @Published var connectedIDs: Set<UUID> = []
    @Published var isBusy = false
    @Published private(set) var isRunningQuery = false
    @Published var error: String?
    @Published var status = "Ready when you are"
    @Published var showConnection = false
    @Published var editingConnection: DBConnection?
    @Published var connectionAttempts: [UUID: ConnectionAttempt] = [:]
    @Published var diagnosticConnectionID: UUID?
    @Published var showConnectionDetails = false
    @Published var showBookmark = false
    @Published var editingBookmark: QueryBookmark?
    @Published private(set) var bookmarkDraftSQL = ""
    @Published private(set) var bookmarkDraftConnectionID: UUID?
    @Published var schemaSearch = ""
    @Published var bookmarkSearch = ""
    @Published var bookmarkFilter: String?
    @Published var history: [(sql: String, time: Date)] = []
    @Published var showHistory = false
    @Published var showBookmarks = true
    @Published var expandedTables: Set<String> = ["customers"]

    var directory: URL { workspaceFiles.directory }
    private let workspaceFiles: WorkspaceFileStore
    private let consoleFiles: ConsoleDraftFileStore
    private let consoleQueue = DispatchQueue(label: "studio.dbdbdeep.console-autosave", qos: .utility)
    private var consoleDrafts: [String: ConsoleDraft] = [:]
    private var consoleLoadError: String?
    private let sessions: DatabaseSessions
    private let readPassword: (UUID) throws -> String
    private var workspaceLoadError: String?
    private var drafts: [String: String] = [:]
    private var persistWork: DispatchWorkItem?
    private var schemaByConnection: [UUID: [SchemaTable]] = [:]
    private var resultQueries: [UUID: (resultID: UUID, sql: String)] = [:]
    private var cachedStatements: [SQLStatement]?
    private var cachedLineCount: Int?
    private struct Cached<Value> { let value: Value }
    private var cachedCursorTarget: Cached<SQLStatement?>?
    private var cachedBookmarkKey: Cached<[String]?>?

    var queryLanguage: QueryLanguage { QueryLanguage(connection?.kind) }
    var canUseTransactions: Bool { connection?.supportsTransactions == true && isConnected && !isBusy }
    var connection: DBConnection? { connections.first { $0.id == selectedID } }
    var result: QueryResult? { selectedID.flatMap { results[$0] } }
    var canRefreshResults: Bool {
        guard !isBusy, let connection, let result, let source = resultQueries[connection.id] else { return false }
        return source.resultID == result.id
    }
    var isConnected: Bool { selectedID.map { connectedIDs.contains($0) } ?? false }
    var queryLineCount: Int {
        if let cachedLineCount { return cachedLineCount }
        let count = SQLLineIndex(query).count
        cachedLineCount = count
        return count
    }
    var cursorStatement: SQLStatement? {
        if let cachedCursorTarget { return cachedCursorTarget.value }
        let statements = cachedStatements ?? queryLanguage.statements(in: query)
        cachedStatements = statements
        let statement = queryLanguage.statementAtOrBefore(in: query, atUTF16Offset: cursorLocation, using: statements)
        cachedCursorTarget = Cached(value: statement)
        return statement
    }
    var sqlToRun: String { selectedSQL.isEmpty ? cursorStatement?.text ?? "" : selectedSQL }
    var canRunQuery: Bool { connection != nil && !isBusy && !sqlToRun.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var sqlToBookmark: String { cursorStatement?.text ?? "" }
    var canBookmarkQuery: Bool { connection != nil && !isBusy && !sqlToBookmark.isEmpty }
    var connectionBookmarks: [QueryBookmark] {
        guard let connection else { return [] }
        return bookmarks.filter { $0.connectionID == connection.id }
    }
    var unassignedBookmarks: [QueryBookmark] {
        let connectionIDs = Set(connections.map(\.id))
        return bookmarks.filter { bookmark in
            bookmark.connectionID.map { !connectionIDs.contains($0) } ?? true
        }
    }
    var currentBookmark: QueryBookmark? {
        let key: [String]?
        if let cachedBookmarkKey { key = cachedBookmarkKey.value }
        else {
            key = queryLanguage.comparisonKey(for: sqlToBookmark)
            cachedBookmarkKey = Cached(value: key)
        }
        guard let key else { return nil }
        return connectionBookmarks.first { queryLanguage.comparisonKey(for: $0.sql) == key }
    }
    var filteredTables: [SchemaTable] { tables.filter { schemaSearch.isEmpty || $0.name.localizedCaseInsensitiveContains(schemaSearch) } }
    var filteredBookmarks: [QueryBookmark] {
        connectionBookmarks.filter { (bookmarkSearch.isEmpty || $0.name.localizedCaseInsensitiveContains(bookmarkSearch) || $0.sql.localizedCaseInsensitiveContains(bookmarkSearch)) && (bookmarkFilter == nil || $0.color == bookmarkFilter) }
    }

    init(directory: URL? = nil,
         makeOracleSession: @escaping (DBConnection, URL) -> any DatabaseConnectionSession = { OracleDatabase(connection: $0, runtime: $1) },
         makeMongoSession: @escaping (DBConnection, URL) -> any DatabaseConnectionSession = { MongoDatabase(connection: $0, runtime: $1) },
         readPassword: @escaping (UUID) throws -> String = { try PasswordKeychain.read(for: $0) }) {
        self.readPassword = readPassword
        let workspaceDirectory = directory ?? WorkspaceDefaults.directory
        workspaceFiles = WorkspaceFileStore(directory: workspaceDirectory)
        consoleFiles = ConsoleDraftFileStore(directory: workspaceDirectory)
        sessions = DatabaseSessions(directory: workspaceDirectory, runtime: DatabaseSessions.bundledRuntime, makeOracleSession: makeOracleSession, makeMongoSession: makeMongoSession)
        do {
            let saved = try consoleFiles.load()
            consoleDrafts = saved.drafts
            if saved.recoveredFromBackup { status = "Console restored from an autosave backup" }
        } catch {
            consoleLoadError = "콘솔 자동 저장 파일을 읽지 못했습니다. 원본은 보존됩니다: \(error.localizedDescription)"
            self.error = consoleLoadError
        }
        do {
            let state = try workspaceFiles.load() ?? WorkspaceDefaults.makeWorkspace()
            connections = state.connections; bookmarks = state.bookmarks; drafts = state.drafts
            for connection in connections {
                let id = connection.id.uuidString
                guard let saved = consoleDrafts[id] else { continue }
                if let date = state.draftUpdatedAt?[id], date > saved.updatedAt, let text = drafts[id] {
                    consoleDrafts[id] = ConsoleDraft(connectionName: connection.name, query: text, updatedAt: date)
                } else { drafts[id] = saved.query }
            }
            selectedID = state.selectedConnection ?? connections.first?.id
            query = selectedID.flatMap { drafts[$0.uuidString] } ?? defaultQuery
            if consoleLoadError == nil {
                updateConsoleDrafts()
                do { try consoleFiles.save(consoleDrafts) }
                catch { self.error = "콘솔 자동 저장 실패: \(error.localizedDescription)" }
            }
        } catch {
            workspaceLoadError = "작업 공간을 읽을 수 없습니다. 원본 설정 파일을 보호하기 위해 저장을 중단했습니다: \(error.localizedDescription)"
            self.error = workspaceLoadError
        }
    }

    deinit { consoleQueue.sync {} }

    static let sampleQuery = WorkspaceDefaults.sampleQuery
    var defaultQuery: String { WorkspaceDefaults.query(for: connection?.kind) }

    func start() async {
        guard let connection, connection.kind == .sample else { return }
        await connect(connection)
        if isConnected && query == Self.sampleQuery { await run() }
    }

    func select(_ target: DBConnection) {
        guard !isBusy, target.id != selectedID else { return }
        if let selectedID { drafts[selectedID.uuidString] = query }
        selectedID = target.id; selectedSQL = ""; cursorLocation = 0; error = nil
        editorFocusRequest = nil
        bookmarkSearch = ""; bookmarkFilter = nil
        query = drafts[target.id.uuidString] ?? defaultQuery
        tables = schemaByConnection[target.id] ?? []
        status = connectedIDs.contains(target.id) ? "Connected · ready when you are" : "Run a query to connect"
        persist()
        if target.kind == .sample && !connectedIDs.contains(target.id) { Task { await connect(target) } }
    }

    private func beginAttempt(_ target: DBConnection, purpose: String, savedPassword: Bool) -> UUID {
        var attempt = ConnectionAttempt(connection: target, purpose: purpose)
        attempt.record(ConnectionEvent(stage: .credentials, message: !target.needsPassword ? "인증 없이 연결합니다. Keychain을 사용하지 않습니다." : savedPassword ? "macOS Keychain에서 저장된 비밀번호를 읽습니다." : "입력한 비밀번호를 사용합니다. 로그에는 포함하지 않습니다."))
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
            let secret = try target.needsPassword ? (password.isEmpty ? readPassword(target.id) : password) : ""
            record(ConnectionEvent(stage: .credentials, level: .success, message: "접속 계정을 준비했습니다 · \(target.needsPassword ? target.username : "No authentication")"), connectionID: target.id, attemptID: attemptID)
            try await sessions.testConnection(target, password: secret) { [weak self] event in
                await self?.record(event, connectionID: target.id, attemptID: attemptID)
            }
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
                try await sessions.connect(target)
            } else {
                let identifier = beginAttempt(target, purpose: purpose, savedPassword: password == nil)
                attemptID = identifier
                let secret = try target.needsPassword ? (password ?? readPassword(target.id)) : ""
                record(ConnectionEvent(stage: .credentials, level: .success, message: "접속 계정을 준비했습니다 · \(target.needsPassword ? target.username : "No authentication")"), connectionID: target.id, attemptID: identifier)
                try await sessions.connect(target, password: secret) { [weak self] event in
                    await self?.record(event, connectionID: target.id, attemptID: identifier)
                }
            }
            connectedIDs.insert(target.id)
            status = "Connected · \(target.name)"
            if let attemptID { record(ConnectionEvent(stage: .schema, message: target.kind == .mongodb ? "데이터베이스의 컬렉션을 조회합니다." : "현재 계정의 테이블·뷰·컬럼을 조회합니다."), connectionID: target.id, attemptID: attemptID) }
            do {
                try await loadSchema(target)
                if let attemptID {
                    record(ConnectionEvent(stage: .schema, level: .success, message: "스키마를 불러왔습니다 · \(schemaByConnection[target.id]?.count ?? 0) \(target.kind == .mongodb ? "collections" : "tables / views")"), connectionID: target.id, attemptID: attemptID)
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
        guard workspaceLoadError == nil else { error = workspaceLoadError; return false }
        do {
            if target.needsPassword && !password.isEmpty { try PasswordKeychain.save(password, for: target.id) }
            else if target.needsPassword { _ = try PasswordKeychain.read(for: target.id) }
            await sessions.disconnect(target)
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
        persist()
        await sessions.disconnect(target)
        PasswordKeychain.delete(for: target.id)
        connections.removeAll { $0.id == target.id }
        connectedIDs.remove(target.id); results.removeValue(forKey: target.id)
        resultQueries.removeValue(forKey: target.id)
        schemaByConnection.removeValue(forKey: target.id); drafts.removeValue(forKey: target.id.uuidString)
        if selectedID == target.id {
            selectedID = nil
            if let first = connections.first { select(first) }
        }
        persist()
    }

    private func loadSchema(_ target: DBConnection) async throws {
        guard sessions.contains(target) else { return }
        let snapshot = try await sessions.schema(for: target)
        schemaByConnection[target.id] = snapshot
        if selectedID == target.id { tables = snapshot }
    }

    func refreshSchema() async {
        guard let connection, isConnected, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do { try await loadSchema(connection) } catch { self.error = error.localizedDescription }
    }

    func mongoFields(in collection: String) async -> [SchemaColumn] {
        guard let connection, connection.kind == .mongodb, isConnected, !isBusy,
              tables.contains(where: { $0.name == collection }) else { return [] }
        return (try? await sessions.collectionFields(collection, on: connection)) ?? []
    }

    func run() async {
        guard let connection, canRunQuery else { return }
        let sql = sqlToRun
        await execute(sql, on: connection)
    }

    func refreshResults() async {
        guard canRefreshResults, let connection, let source = resultQueries[connection.id] else { return }
        await execute(source.sql, on: connection)
    }

    private func execute(_ sql: String, on connection: DBConnection) async {
        isBusy = true; isRunningQuery = true; error = nil
        defer { isRunningQuery = false; isBusy = false }
        guard await prepareConnectionForQuery(connection) else { return }
        status = "A little query in progress…"
        do {
            let output = try await sessions.execute(sql, on: connection)
            results[connection.id] = output
            resultQueries[connection.id] = (output.id, sql)
            history.insert((sql, Date()), at: 0)
            history = Array(history.prefix(50))
            status = output.message
            do { try await loadSchema(connection) }
            catch { status += " · schema refresh unavailable" }
            persist()
        } catch {
            if connection.kind != .sample && sessions.contains(connection) {
                do { try await sessions.validate(connection) }
                catch { await invalidateSession(connection) }
            }
            self.error = error.localizedDescription
            status = connectedIDs.contains(connection.id) ? "Query needs a little attention" : "Connection lost · run again to reconnect"
        }
    }

    private func prepareConnectionForQuery(_ target: DBConnection) async -> Bool {
        if target.kind == .sample {
            if sessions.contains(target) && connectedIDs.contains(target.id) { return true }
        } else if sessions.contains(target) {
            status = "Checking connection…"
            do {
                try await sessions.validate(target)
                connectedIDs.insert(target.id)
                return true
            } catch {
                await invalidateSession(target)
            }
        }
        status = "Connecting before query…"
        return await openConnection(target, purpose: "Connect before query")
    }

    private func invalidateSession(_ target: DBConnection) async {
        connectedIDs.remove(target.id)
        results.removeValue(forKey: target.id)
        resultQueries.removeValue(forKey: target.id)
        schemaByConnection.removeValue(forKey: target.id)
        if selectedID == target.id { tables = [] }
        await sessions.disconnect(target)
    }

    func transaction(commit: Bool) async {
        guard let connection, canUseTransactions else { return }
        isBusy = true; error = nil
        defer { isBusy = false }
        do {
            try await sessions.transaction(on: connection, commit: commit)
            status = commit ? "Changes committed ✓" : "Changes rolled back ↶"
            results.removeValue(forKey: connection.id)
            resultQueries.removeValue(forKey: connection.id)
            try await loadSchema(connection)
        } catch { self.error = error.localizedDescription }
    }

    func browse(_ table: SchemaTable) async {
        guard !isBusy, let connection else { return }
        let preview = connection.kind == .mongodb ? QueryLanguage.browseCollection(table.name) : connection.kind == .oracle
            ? "SELECT *\nFROM \(SQLIdentifier.quote(table.name))\nFETCH FIRST 100 ROWS ONLY;"
            : "SELECT *\nFROM \(SQLIdentifier.quote(table.name))\nLIMIT 100;"
        if let target = try? SavedQueryFocus.resolve(bookmarkSQL: preview, in: query, cursor: cursorLocation, kind: connection.kind),
           SQLLineIndex(target.sql).count <= SQLLineIndex.maximumLines {
            query = target.sql
            selectedSQL = ""; cursorLocation = target.range.location
            editorFocusRequest = SQLEditorFocus(range: target.range)
        }
        persist()
        await execute(preview, on: connection)
    }

    func canRunBookmark(_ bookmark: QueryBookmark) -> Bool {
        !isBusy && connection != nil && bookmark.connectionID == connection?.id && queryLanguage.singleStatement(in: bookmark.sql) != nil
    }

    @discardableResult
    func focusBookmark(_ bookmark: QueryBookmark, reportErrors: Bool = true) -> Bool {
        guard !isBusy, let connection, bookmark.connectionID == connection.id else { return false }
        do {
            let target = try SavedQueryFocus.resolve(bookmarkSQL: bookmark.sql, in: query, cursor: cursorLocation, kind: connection.kind)
            query = target.sql
            selectedSQL = ""; cursorLocation = target.range.location
            editorFocusRequest = SQLEditorFocus(range: target.range)
        } catch {
            if reportErrors { self.error = error.localizedDescription }
            return false
        }
        error = nil
        persist()
        status = "Query focused · \(bookmark.name)"
        return true
    }

    func runBookmark(_ bookmark: QueryBookmark) async {
        guard canRunBookmark(bookmark), let connection,
              let statement = queryLanguage.singleStatement(in: bookmark.sql) else { return }
        focusBookmark(bookmark, reportErrors: false)
        await execute(statement.text, on: connection)
    }

    func editBookmark(_ bookmark: QueryBookmark) {
        guard !isBusy, let connection, bookmark.connectionID == connection.id else { return }
        editingBookmark = bookmark
        showBookmark = true
    }

    @discardableResult
    func assignBookmark(_ bookmark: QueryBookmark) -> Bool {
        guard !isBusy, let connection,
              let index = bookmarks.firstIndex(where: { $0.id == bookmark.id }),
              unassignedBookmarks.contains(where: { $0.id == bookmark.id }) else { return false }
        bookmarks[index].connectionID = connection.id
        bookmarkSearch = ""; bookmarkFilter = nil
        persist()
        status = "Bookmark moved to \(connection.name)"
        return true
    }

    @discardableResult
    func saveBookmark(_ bookmark: QueryBookmark) -> Bool {
        guard !isBusy, let connection, bookmark.connectionID == connection.id,
              let statement = queryLanguage.singleStatement(in: bookmark.sql) else { return false }
        var saved = bookmark
        saved.sql = statement.text
        if let index = bookmarks.firstIndex(where: { $0.id == saved.id }) {
            guard bookmarks[index].connectionID == connection.id else { return false }
            bookmarks[index] = saved
        }
        else { bookmarks.insert(saved, at: 0) }
        persist(); showBookmark = false
        return true
    }

    func removeBookmark(_ bookmark: QueryBookmark) {
        bookmarks.removeAll { $0.id == bookmark.id }; persist()
    }

    func newBookmark() {
        guard canBookmarkQuery else { return }
        bookmarkDraftSQL = sqlToBookmark
        bookmarkDraftConnectionID = connection?.id
        editingBookmark = currentBookmark
        showBookmark = true
    }
    func newConnection() {
        guard workspaceLoadError == nil else { error = workspaceLoadError; return }
        editingConnection = nil; showConnection = true
    }

    func queryChanged() {
        if let selectedID { drafts[selectedID.uuidString] = query }
        persistWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.persist() }
        persistWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func updateConsoleDrafts() {
        if let selectedID { drafts[selectedID.uuidString] = query }
        for connection in connections {
            let id = connection.id.uuidString
            guard let text = drafts[id] else { continue }
            if consoleDrafts[id]?.query != text || consoleDrafts[id]?.connectionName != connection.name {
                consoleDrafts[id] = ConsoleDraft(connectionName: connection.name, query: text)
            }
        }
    }

    func persist(waitForDrafts: Bool = false) {
        guard workspaceLoadError == nil else { error = workspaceLoadError; return }
        persistWork?.cancel()
        updateConsoleDrafts()
        if let consoleLoadError { error = consoleLoadError }
        else {
            let files = consoleFiles
            let snapshot = consoleDrafts
            if waitForDrafts {
                do { try consoleQueue.sync { try files.save(snapshot) } }
                catch { self.error = "콘솔 자동 저장 실패: \(error.localizedDescription)" }
            } else {
                consoleQueue.async { [weak self] in
                    do { try files.save(snapshot) }
                    catch {
                        let message = "콘솔 자동 저장 실패: \(error.localizedDescription)"
                        Task { @MainActor [weak self] in self?.error = message }
                    }
                }
            }
        }
        let dates = consoleDrafts.filter { drafts[$0.key] != nil }.mapValues(\.updatedAt)
        let state = WorkspaceState(connections: connections, bookmarks: bookmarks, drafts: drafts, selectedConnection: selectedID, draftUpdatedAt: dates)
        do { try workspaceFiles.save(state) }
        catch { self.error = "저장 실패: \(error.localizedDescription)" }
    }

    func exportCSV() {
        guard let result, !result.columns.isEmpty else { return }
        do { if try QueryResultExporter.export(result) { status = "CSV exported ✓" } }
        catch { self.error = error.localizedDescription }
    }
}
