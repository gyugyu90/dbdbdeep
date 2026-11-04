import XCTest
import DBDeepCore
@testable import DBDeepApp

@MainActor
final class MongoConnectionTests: XCTestCase {
    func testMongoConnectionSkipsKeychainWithoutAuthAndRoutesCommandsAndBookmarks() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let profile = DBConnection(name: "Mongo", kind: .mongodb, port: 27017, service: "test")
        try WorkspaceFileStore(directory: directory).save(WorkspaceState(connections: [profile], bookmarks: [], selectedConnection: profile.id))
        let session = FakeMongoSession()
        let probe = FakeMongoSession()
        var sessions = [session, probe]
        let store = AppStore(directory: directory, makeOracleSession: { _, _ in
            XCTFail("MongoDB must not use the Oracle driver.")
            return FakeMongoSession()
        }, makeMongoSession: { _, _ in sessions.removeFirst() }, readPassword: { _ in
            XCTFail("Unauthenticated MongoDB must not read Keychain.")
            return ""
        })
        XCTAssertEqual(store.query, "{\n  \"ping\": 1\n}")
        await store.run()
        XCTAssertTrue(store.isConnected)
        XCTAssertFalse(store.canUseTransactions)
        XCTAssertNil(store.error)
        await store.testConnection(profile, password: "")
        let probeActions = await probe.actions
        XCTAssertEqual(probeActions, ["connect:", "disconnect"])
        let command = #"{"find":"items","filter":{"name":"Case Sensitive"}}"#
        let bookmark = QueryBookmark(name: "Items", sql: command, connectionID: profile.id)
        XCTAssertTrue(store.saveBookmark(bookmark))
        XCTAssertTrue(store.focusBookmark(bookmark))
        XCTAssertEqual(store.currentBookmark?.id, bookmark.id)
        await store.runBookmark(bookmark)
        XCTAssertEqual(store.history.first?.sql, command)
        let actions = await session.actions
        XCTAssertEqual(actions, ["connect:", "schema", "execute:{\n  \"ping\": 1\n}", "schema", "validate", "execute:" + command, "schema"])
        await store.transaction(commit: true)
        let afterTransaction = await session.actions
        XCTAssertEqual(afterTransaction, actions)
        store.query = "db.items.find({name: 'first'});\n\ndb.items.find({name: 'second'}).limit(1)"
        store.cursorLocation = (store.query as NSString).range(of: "second").location
        await store.run()
        XCTAssertEqual(store.history.first?.sql, "db.items.find({name: 'second'}).limit(1)")
        let shellActions = await session.actions
        XCTAssertEqual(Array(shellActions.suffix(3)), ["validate", "execute:db.items.find({name: 'second'}).limit(1)", "schema"])
    }
}

private actor FakeMongoSession: DatabaseConnectionSession {
    var actions: [String] = []
    func connect(password: String, onEvent: @escaping ConnectionEventHandler) { actions.append("connect:" + password) }
    func validateConnection() { actions.append("validate") }
    func execute(_ sql: String) -> QueryResult { actions.append("execute:" + sql); return QueryResult(message: "Query completed") }
    func schema() -> [SchemaTable] { actions.append("schema"); return [SchemaTable(name: "items")] }
    func commit() -> QueryResult { actions.append("commit"); return QueryResult() }
    func rollback() -> QueryResult { actions.append("rollback"); return QueryResult() }
    func disconnect() { actions.append("disconnect") }
}
