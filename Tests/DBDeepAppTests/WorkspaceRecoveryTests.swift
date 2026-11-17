import XCTest
import DBDeepCore
@testable import DBDeepApp

@MainActor
final class WorkspaceRecoveryTests: XCTestCase {
    func testFailedLoadBlocksTerminationSaveAndConnectionChanges() async throws {
        let directory = try temporaryDirectory()
        let file = directory.appendingPathComponent("workspace.json")
        let original = Data("{unreadable workspace".utf8)
        try original.write(to: file)
        let store = AppStore(directory: directory, readPassword: { _ in
            XCTFail("An unreadable workspace must not access credentials.")
            return ""
        })
        XCTAssertNotNil(store.error)
        store.error = nil
        store.query = "SELECT 1;"
        store.persist()
        XCTAssertNotNil(store.error)
        XCTAssertEqual(try Data(contentsOf: file), original)
        store.newConnection()
        XCTAssertFalse(store.showConnection)
        let saved = await store.saveConnection(DBConnection(name: "Replacement"), password: "")
        XCTAssertFalse(saved)
        XCTAssertTrue(store.connections.isEmpty)
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    func testFailedLoadRemainsProtectedWhenFileIsExternallyRemoved() throws {
        let directory = try temporaryDirectory()
        let file = directory.appendingPathComponent("workspace.json")
        try Data("invalid workspace".utf8).write(to: file)
        let store = AppStore(directory: directory)
        try FileManager.default.removeItem(at: file)
        store.persist()
        XCTAssertNotNil(store.error)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testLegacyConsoleMigratesAndIndependentDraftSurvivesWorkspaceDraftLoss() throws {
        let directory = try temporaryDirectory()
        let connection = DBConnection(name: "Development")
        let files = WorkspaceFileStore(directory: directory)
        try files.save(WorkspaceState(connections: [connection], bookmarks: [], drafts: [connection.id.uuidString: "SELECT '이전 쿼리';"], selectedConnection: connection.id))
        let store = AppStore(directory: directory)
        XCTAssertEqual(try ConsoleDraftFileStore(directory: directory).load().drafts[connection.id.uuidString]?.query, "SELECT '이전 쿼리';")
        store.query = "SELECT '자동 저장 🌷';"
        store.persist(waitForDrafts: true)
        try files.save(WorkspaceState(connections: [connection], bookmarks: [], selectedConnection: connection.id))
        let reopened = AppStore(directory: directory)
        XCTAssertEqual(reopened.query, "SELECT '자동 저장 🌷';")
    }

    func testConsoleSaveSucceedsEvenWhenWorkspaceCannotBeSaved() throws {
        let directory = try temporaryDirectory()
        let store = AppStore(directory: directory)
        let connectionID = try XCTUnwrap(store.selectedID)
        let workspace = directory.appendingPathComponent("workspace.json")
        let damaged = Data("unreadable workspace".utf8)
        try damaged.write(to: workspace)
        store.query = "SELECT 'separate safety copy';"
        store.persist(waitForDrafts: true)
        XCTAssertNotNil(store.error)
        XCTAssertEqual(try Data(contentsOf: workspace), damaged)
        XCTAssertEqual(try ConsoleDraftFileStore(directory: directory).load().drafts[connectionID.uuidString]?.query, store.query)
    }

    func testSavedEmptyConsoleDoesNotResurrectAnOlderQueryOnRelaunch() throws {
        let directory = try temporaryDirectory()
        let store = AppStore(directory: directory)
        store.query = "SELECT 'old query';"
        store.persist(waitForDrafts: true)
        store.query = ""
        store.persist(waitForDrafts: true)
        XCTAssertEqual(AppStore(directory: directory).query, "")
    }

    func testDamagedLatestAutosaveRestoresPreviousConsoleOnLaunch() throws {
        let directory = try temporaryDirectory()
        let store = AppStore(directory: directory)
        store.query = "SELECT 'recover this';"
        store.persist(waitForDrafts: true)
        store.query = "SELECT 'interrupted';"
        store.persist(waitForDrafts: true)
        let current = ConsoleDraftFileStore(directory: directory).directory.appendingPathComponent("current.json")
        try Data("broken".utf8).write(to: current)
        try WorkspaceFileStore(directory: directory).save(WorkspaceState(connections: store.connections, bookmarks: [], selectedConnection: store.selectedID))
        let reopened = AppStore(directory: directory)
        XCTAssertEqual(reopened.query, "SELECT 'recover this';")
        XCTAssertEqual(reopened.status, "Console restored from an autosave backup")
        XCTAssertNil(reopened.error)
    }

    func testNewerWorkspaceDraftWinsOverOlderFallbackAndRepairsAutosave() throws {
        let directory = try temporaryDirectory()
        let store = AppStore(directory: directory)
        store.query = "SELECT 'older';"
        store.persist(waitForDrafts: true)
        store.query = "SELECT 'newer workspace';"
        store.persist(waitForDrafts: true)
        let files = ConsoleDraftFileStore(directory: directory)
        try Data("broken".utf8).write(to: files.directory.appendingPathComponent("current.json"))
        let reopened = AppStore(directory: directory)
        XCTAssertEqual(reopened.query, "SELECT 'newer workspace';")
        XCTAssertEqual(try files.load().drafts[try XCTUnwrap(store.selectedID).uuidString]?.query, reopened.query)
    }

    func testEditingAutosavesWithoutSwiftUIViewAndSwitchingPreservesEachConsole() async throws {
        let directory = try temporaryDirectory()
        let first = DBConnection(name: "First")
        let second = DBConnection(name: "Second", kind: .mongodb)
        try WorkspaceFileStore(directory: directory).save(WorkspaceState(connections: [first, second], bookmarks: [], selectedConnection: first.id))
        let store = AppStore(directory: directory)
        store.query = "SELECT 'first console';"
        store.select(second)
        store.query = "db.items.find({name: 'second console'})"
        try await Task.sleep(for: .milliseconds(800))
        let saved = try ConsoleDraftFileStore(directory: directory).load().drafts
        XCTAssertEqual(saved[first.id.uuidString]?.query, "SELECT 'first console';")
        XCTAssertEqual(saved[second.id.uuidString]?.query, store.query)
        store.select(first)
        XCTAssertEqual(store.query, "SELECT 'first console';")
        store.persist(waitForDrafts: true)
    }

    func testUnreadableConsoleFilesDoNotBlockWorkspaceButAreNotOverwritten() throws {
        let directory = try temporaryDirectory()
        let files = ConsoleDraftFileStore(directory: directory)
        try FileManager.default.createDirectory(at: files.directory, withIntermediateDirectories: true)
        let current = files.directory.appendingPathComponent("current.json")
        let original = Data("unreadable console".utf8)
        try original.write(to: current)
        let store = AppStore(directory: directory)
        XCTAssertNotNil(store.error)
        store.query = "SELECT 123;"
        store.persist(waitForDrafts: true)
        XCTAssertEqual(try Data(contentsOf: current), original)
        XCTAssertEqual(try WorkspaceFileStore(directory: directory).load()?.drafts[try XCTUnwrap(store.selectedID).uuidString], store.query)
    }

    func testRemovingConnectionKeepsItsLastConsoleInIndependentFile() async throws {
        let directory = try temporaryDirectory()
        let connection = DBConnection(name: "Removed DB", kind: .mongodb)
        try WorkspaceFileStore(directory: directory).save(WorkspaceState(connections: [connection], bookmarks: [], selectedConnection: connection.id))
        let store = AppStore(directory: directory)
        store.query = "db.items.find({keep: true})"
        await store.removeConnection(connection)
        store.persist(waitForDrafts: true)
        XCTAssertTrue(store.connections.isEmpty)
        XCTAssertEqual(try ConsoleDraftFileStore(directory: directory).load().drafts[connection.id.uuidString]?.query, "db.items.find({keep: true})")
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return directory
    }
}
