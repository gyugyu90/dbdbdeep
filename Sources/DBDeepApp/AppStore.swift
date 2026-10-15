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
    @Published var tables: [SchemaTable] = []
    @Published var results: [UUID: QueryResult] = [:]
    @Published var connectedIDs: Set<UUID> = []
    @Published var isBusy = false
    @Published var error: String?
    @Published var status = "Ready when you are"
    @Published var showConnection = false
    @Published var editingConnection: DBConnection?
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
    private var oracle: [UUID: OracleDatabase] = [:]
    private var drafts: [String: String] = [:]
    private var persistWork: DispatchWorkItem?
    private var schemaByConnection: [UUID: [SchemaTable]] = [:]

    var connection: DBConnection? { connections.first { $0.id == selectedID } }
    var result: QueryResult? { selectedID.flatMap { results[$0] } }
    var isConnected: Bool { selectedID.map { connectedIDs.contains($0) } ?? false }
    var filteredTables: [SchemaTable] { tables.filter { schemaSearch.isEmpty || $0.name.localizedCaseInsensitiveContains(schemaSearch) } }
    var filteredBookmarks: [QueryBookmark] {
        bookmarks.filter { (bookmarkSearch.isEmpty || $0.name.localizedCaseInsensitiveContains(bookmarkSearch) || $0.sql.localizedCaseInsensitiveContains(bookmarkSearch)) && (bookmarkFilter == nil || $0.color == bookmarkFilter) }
    }

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("DBDeep")
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
        selectedID = target.id; selectedSQL = ""; error = nil
        query = drafts[target.id.uuidString] ?? defaultQuery
        tables = schemaByConnection[target.id] ?? []
        status = connectedIDs.contains(target.id) ? "Connected · ready when you are" : "Connect to start exploring"
        persist()
        if target.kind == .sample && !connectedIDs.contains(target.id) { Task { await connect(target) } }
    }

    func connect(_ target: DBConnection, password: String? = nil) async {
        guard !isBusy else { return }
        isBusy = true; error = nil; status = "Connecting…"
        defer { isBusy = false }
        do {
            if target.kind == .sample {
                if sqlite == nil {
                    let database = try SQLiteDatabase(path: directory.appendingPathComponent("playground.sqlite").path)
                    try await database.seed()
                    _ = try await database.execute("BEGIN")
                    sqlite = database
                }
            } else {
                let secret = try password ?? PasswordKeychain.read(for: target.id)
                let database = OracleDatabase(connection: target, runtime: oracleRuntime)
                try await database.connect(password: secret)
                oracle[target.id] = database
            }
            connectedIDs.insert(target.id)
            status = "Connected · \(target.name)"
            do { try await loadSchema(target) }
            catch { self.error = "연결되었습니다. 스키마를 불러올 수 없습니다: \(error.localizedDescription)" }
        } catch { self.error = error.localizedDescription; status = "Connection failed" }
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
            showConnection = false
            await connect(target, password: password.isEmpty ? nil : password)
            return true
        } catch { self.error = error.localizedDescription; return false }
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
        guard let connection, isConnected, !isBusy else { return }
        let sql = selectedSQL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? query : selectedSQL
        guard !sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isBusy = true; error = nil; status = "A little query in progress…"
        defer { isBusy = false }
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
            self.error = error.localizedDescription
            status = "Query needs a little attention"
        }
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
        Task { await run() }
    }

    func loadBookmark(_ bookmark: QueryBookmark) {
        guard !isBusy else { return }
        if let id = bookmark.connectionID, let target = connections.first(where: { $0.id == id }) { select(target) }
        query = bookmark.sql; selectedSQL = ""; persist()
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
