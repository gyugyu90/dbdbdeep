import XCTest
import DBDeepCore
@testable import DBDeepApp

@MainActor
final class AppStoreConnectionTests: XCTestCase {
    func testRunConnectsOfflineProfileUsingSavedPassword() async throws {
        let session = FakeOracleSession()
        let store = try makeStore([session])
        store.query = "SELECT * FROM notes"

        await store.run()

        let actions = await session.actions
        let passwords = await session.passwords
        XCTAssertEqual(actions, ["connect", "schema", "execute:SELECT * FROM notes", "schema"])
        XCTAssertEqual(passwords, ["test-password"])
        XCTAssertTrue(store.isConnected)
        XCTAssertEqual(store.history.map(\.sql), ["SELECT * FROM notes"])
        XCTAssertEqual(store.connectionAttempts[store.selectedID!]?.purpose, "Connect before query")
        XCTAssertNil(store.error)
        XCTAssertFalse(store.isBusy)
    }

    func testExpiredSessionReconnectsBeforeSendingSQL() async throws {
        let expired = FakeOracleSession()
        let replacement = FakeOracleSession()
        let store = try makeStore([expired, replacement])
        await store.connect(store.connection!)
        await expired.expire()
        store.query = "INSERT INTO notes VALUES ('hello')"

        await store.run()

        let oldActions = await expired.actions
        let newActions = await replacement.actions
        XCTAssertEqual(oldActions, ["connect", "schema", "validate", "disconnect"])
        XCTAssertEqual(newActions, ["connect", "schema", "execute:INSERT INTO notes VALUES ('hello')", "schema"])
        XCTAssertTrue(store.isConnected)
        XCTAssertEqual(store.history.count, 1)
    }

    func testHealthySessionIsReusedWithoutChangingTransaction() async throws {
        let session = FakeOracleSession()
        let store = try makeStore([session])
        await store.connect(store.connection!)
        store.query = "UPDATE notes SET content = 'hello'"

        await store.run()

        let actions = await session.actions
        XCTAssertEqual(actions, ["connect", "schema", "validate", "execute:UPDATE notes SET content = 'hello'", "schema"])
        XCTAssertTrue(store.isConnected)
        XCTAssertNil(store.error)
    }

    func testFailedReconnectLeavesProfileOfflineAndDoesNotSendSQL() async throws {
        let expired = FakeOracleSession()
        let replacement = FakeOracleSession(connectionError: "Cannot reach listener")
        let store = try makeStore([expired, replacement])
        await store.connect(store.connection!)
        store.query = "SELECT * FROM notes"
        await store.run()
        XCTAssertNotNil(store.result)
        await expired.expire()

        await store.run()

        let actions = await replacement.actions
        XCTAssertEqual(actions, ["connect"])
        XCTAssertFalse(store.isConnected)
        XCTAssertNil(store.result)
        XCTAssertTrue(store.tables.isEmpty)
        XCTAssertEqual(store.history.count, 1)
        XCTAssertEqual(store.error, "Cannot reach listener")
        XCTAssertFalse(store.isBusy)
    }

    func testAuthenticationFailureStopsBeforeSQLExecution() async throws {
        let session = FakeOracleSession(connectionError: "ORA-01017: invalid credentials")
        let store = try makeStore([session])
        store.query = "DELETE FROM notes"

        await store.run()

        let actions = await session.actions
        XCTAssertEqual(actions, ["connect"])
        XCTAssertFalse(store.isConnected)
        XCTAssertTrue(store.history.isEmpty)
        XCTAssertEqual(store.connectionAttempts[store.selectedID!]?.outcome, .failed)
        XCTAssertEqual(store.query, "DELETE FROM notes")
        XCTAssertFalse(store.isRunningQuery)
    }

    func testSQLErrorDoesNotReconnectOrRepeatStatement() async throws {
        let session = FakeOracleSession(executionError: "ORA-00942: table does not exist")
        let store = try makeStore([session])
        await store.connect(store.connection!)
        store.query = "UPDATE missing_table SET content = 'hello'"

        await store.run()

        let actions = await session.actions
        XCTAssertEqual(actions, ["connect", "schema", "validate", "execute:UPDATE missing_table SET content = 'hello'", "validate"])
        XCTAssertTrue(store.isConnected)
        XCTAssertTrue(store.history.isEmpty)
        XCTAssertEqual(store.error, "ORA-00942: table does not exist")
    }

    func testConnectionLossDuringExecutionRequiresExplicitSecondRun() async throws {
        let interrupted = FakeOracleSession(executionError: "Connection lost", expiresDuringExecution: true)
        let replacement = FakeOracleSession()
        let store = try makeStore([interrupted, replacement])
        await store.connect(store.connection!)
        store.query = "INSERT INTO notes VALUES ('once')"

        await store.run()

        let firstActions = await interrupted.actions
        let replacementBeforeRetry = await replacement.actions
        XCTAssertEqual(firstActions, ["connect", "schema", "validate", "execute:INSERT INTO notes VALUES ('once')", "validate", "disconnect"])
        XCTAssertTrue(replacementBeforeRetry.isEmpty)
        XCTAssertFalse(store.isConnected)
        XCTAssertTrue(store.history.isEmpty)
        XCTAssertEqual(store.status, "Connection lost · run again to reconnect")

        await store.run()

        let replacementAfterRetry = await replacement.actions
        XCTAssertEqual(replacementAfterRetry, ["connect", "schema", "execute:INSERT INTO notes VALUES ('once')", "schema"])
        XCTAssertTrue(store.isConnected)
    }

    func testMissingSavedPasswordStopsBeforeCreatingSession() async throws {
        let session = FakeOracleSession()
        let store = try makeStore([session], missingPassword: true)
        store.query = "SELECT 1 FROM DUAL"

        await store.run()

        let actions = await session.actions
        XCTAssertTrue(actions.isEmpty)
        XCTAssertFalse(store.isConnected)
        XCTAssertEqual(store.error, "Saved password is missing")
        XCTAssertEqual(store.connectionAttempts[store.selectedID!]?.failure?.stage, .credentials)
    }

    func testConnectingKeepsRequestedSelectionAndRejectsDuplicateRun() async throws {
        let session = FakeOracleSession(pausesConnection: true)
        let store = try makeStore([session])
        store.query = "SELECT * FROM notes; DELETE FROM notes"
        store.selectedSQL = "SELECT * FROM notes"
        let execution = Task { await store.run() }
        await session.waitUntilConnecting()
        XCTAssertTrue(store.isBusy)
        XCTAssertTrue(store.isRunningQuery)
        store.query = "DELETE FROM notes"
        store.selectedSQL = ""

        await store.run()
        await session.resumeConnection()
        await execution.value

        let actions = await session.actions
        XCTAssertEqual(actions, ["connect", "schema", "execute:SELECT * FROM notes", "schema"])
        XCTAssertEqual(store.history.map(\.sql), ["SELECT * FROM notes"])
        XCTAssertEqual(store.query, "DELETE FROM notes")
        XCTAssertFalse(store.isBusy)
        XCTAssertFalse(store.isRunningQuery)
    }

    func testLoadingRemainsVisibleUntilQueryExecutionCompletes() async throws {
        let session = FakeOracleSession(pausesExecution: true)
        let store = try makeStore([session])
        await store.connect(store.connection!)
        store.query = "SELECT * FROM notes"
        let execution = Task { await store.run() }
        await session.waitUntilExecuting()

        XCTAssertTrue(store.isRunningQuery)
        XCTAssertTrue(store.isBusy)
        XCTAssertFalse(store.canRunQuery)

        await session.resumeExecution()
        await execution.value

        XCTAssertFalse(store.isRunningQuery)
        XCTAssertFalse(store.isBusy)
        XCTAssertNotNil(store.result)
        XCTAssertNil(store.error)
    }

    func testQueryFailureClearsLoadingAndPreservesError() async throws {
        let session = FakeOracleSession(executionError: "ORA-00942: table does not exist", pausesExecution: true)
        let store = try makeStore([session])
        await store.connect(store.connection!)
        store.query = "SELECT * FROM missing_table"
        let execution = Task { await store.run() }
        await session.waitUntilExecuting()
        XCTAssertTrue(store.isRunningQuery)

        await session.resumeExecution()
        await execution.value

        XCTAssertFalse(store.isRunningQuery)
        XCTAssertFalse(store.isBusy)
        XCTAssertEqual(store.error, "ORA-00942: table does not exist")
    }

    func testManualConnectionDoesNotShowQueryLoading() async throws {
        let session = FakeOracleSession(pausesConnection: true)
        let store = try makeStore([session])
        let connection = Task { await store.connect(store.connection!) }
        await session.waitUntilConnecting()

        XCTAssertTrue(store.isBusy)
        XCTAssertFalse(store.isRunningQuery)

        await session.resumeConnection()
        _ = await connection.value
        XCTAssertFalse(store.isRunningQuery)
    }

    private func makeStore(_ sessions: [FakeOracleSession], missingPassword: Bool = false) throws -> AppStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let profile = DBConnection(name: "Test Oracle", username: "app")
        let state = WorkspaceState(connections: [profile], bookmarks: [], selectedConnection: profile.id)
        try JSONEncoder().encode(state).write(to: directory.appendingPathComponent("workspace.json"))
        var created = 0
        return AppStore(directory: directory, makeOracleSession: { _, _ in
            XCTAssertLessThan(created, sessions.count, "Unexpected extra connection attempt")
            let session = sessions[min(created, sessions.count - 1)]
            created += 1
            return session
        }, readPassword: { id in
            XCTAssertEqual(id, profile.id)
            if missingPassword { throw DatabaseError("Saved password is missing") }
            return "test-password"
        })
    }
}

private actor FakeOracleSession: OracleConnectionSession {
    private(set) var actions: [String] = []
    private(set) var passwords: [String] = []
    private var valid = false
    private let connectionError: String?
    private let executionError: String?
    private let expiresDuringExecution: Bool
    private let pausesConnection: Bool
    private let pausesExecution: Bool
    private var connecting = false
    private var observers: [CheckedContinuation<Void, Never>] = []
    private var connectionWaiter: CheckedContinuation<Void, Never>?
    private var executing = false
    private var executionObservers: [CheckedContinuation<Void, Never>] = []
    private var executionWaiter: CheckedContinuation<Void, Never>?

    init(connectionError: String? = nil, executionError: String? = nil, expiresDuringExecution: Bool = false, pausesConnection: Bool = false, pausesExecution: Bool = false) {
        self.connectionError = connectionError
        self.executionError = executionError
        self.expiresDuringExecution = expiresDuringExecution
        self.pausesConnection = pausesConnection
        self.pausesExecution = pausesExecution
    }

    func connect(password: String, onEvent: @escaping ConnectionEventHandler) async throws {
        actions.append("connect")
        passwords.append(password)
        connecting = true
        observers.forEach { $0.resume() }
        observers.removeAll()
        if pausesConnection { await withCheckedContinuation { connectionWaiter = $0 } }
        if let connectionError { throw DatabaseError(connectionError) }
        valid = true
    }

    func validateConnection() throws {
        actions.append("validate")
        if !valid { throw DatabaseError("Session expired") }
    }

    func execute(_ sql: String) async throws -> QueryResult {
        actions.append("execute:" + sql)
        executing = true
        executionObservers.forEach { $0.resume() }
        executionObservers.removeAll()
        if pausesExecution { await withCheckedContinuation { executionWaiter = $0 } }
        if expiresDuringExecution { valid = false }
        if let executionError { throw DatabaseError(executionError) }
        return QueryResult(columns: ["value"], rows: [["1"]], message: "Query completed")
    }

    func schema() -> [SchemaTable] {
        actions.append("schema")
        return [SchemaTable(name: "notes")]
    }

    func commit() -> QueryResult { actions.append("commit"); return QueryResult() }
    func rollback() -> QueryResult { actions.append("rollback"); return QueryResult() }
    func disconnect() { actions.append("disconnect"); valid = false }
    func expire() { valid = false }

    func waitUntilConnecting() async {
        if connecting { return }
        await withCheckedContinuation { observers.append($0) }
    }

    func resumeConnection() {
        connectionWaiter?.resume()
        connectionWaiter = nil
    }

    func waitUntilExecuting() async {
        if executing { return }
        await withCheckedContinuation { executionObservers.append($0) }
    }

    func resumeExecution() {
        executionWaiter?.resume()
        executionWaiter = nil
    }
}
