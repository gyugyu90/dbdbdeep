import XCTest
@testable import DBDeepCore

final class WorkspaceFileStoreTests: XCTestCase {
    func testMissingWorkspaceAndRoundTripKeepConnectionsBookmarksAndDrafts() throws {
        let directory = try temporaryDirectory().appendingPathComponent("nested")
        let files = WorkspaceFileStore(directory: directory)
        XCTAssertNil(try files.load())
        let connection = DBConnection(name: "Development", username: "APP")
        let bookmark = QueryBookmark(name: "한글 🌷", sql: "SELECT '💜' FROM dual;", connectionID: connection.id)
        let state = WorkspaceState(connections: [connection], bookmarks: [bookmark], drafts: [connection.id.uuidString: "SELECT 1;"], selectedConnection: connection.id)
        try files.save(state)
        let reloaded = try XCTUnwrap(WorkspaceFileStore(directory: directory).load())
        XCTAssertEqual(reloaded.connections, state.connections)
        XCTAssertEqual(reloaded.bookmarks, state.bookmarks)
        XCTAssertEqual(reloaded.drafts, state.drafts)
        XCTAssertEqual(reloaded.selectedConnection, connection.id)
        let data = try Data(contentsOf: directory.appendingPathComponent("workspace.json"))
        let legacyReader = try JSONDecoder().decode(WorkspaceState.self, from: data)
        XCTAssertEqual(legacyReader.bookmarks, state.bookmarks)
    }

    func testCorruptWorkspaceThrowsWithoutReplacingExistingData() throws {
        let directory = try temporaryDirectory()
        let file = directory.appendingPathComponent("workspace.json")
        let original = Data("{unfinished workspace".utf8)
        try original.write(to: file)
        let files = WorkspaceFileStore(directory: directory)
        XCTAssertThrowsError(try files.load())
        XCTAssertThrowsError(try files.save(WorkspaceState(connections: [], bookmarks: [])))
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    func testUnsupportedConnectionKindCannotBeOverwritten() throws {
        let directory = try temporaryDirectory()
        let file = directory.appendingPathComponent("workspace.json")
        let state = WorkspaceState(connections: [DBConnection(name: "Future database")], bookmarks: [])
        let original = Data(String(decoding: try JSONEncoder().encode(state), as: UTF8.self)
            .replacingOccurrences(of: "oracle", with: "future-database").utf8)
        try original.write(to: file)
        let files = WorkspaceFileStore(directory: directory)
        XCTAssertThrowsError(try files.load())
        XCTAssertThrowsError(try files.save(WorkspaceState(connections: [], bookmarks: [])))
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    func testRemovingConnectionsAndBookmarksBacksUpTheirPreviousState() throws {
        let directory = try temporaryDirectory()
        let files = WorkspaceFileStore(directory: directory)
        let connection = DBConnection(name: "Development")
        let bookmark = QueryBookmark(name: "Saved query", sql: "SELECT 1;", connectionID: connection.id)
        let state = WorkspaceState(connections: [connection], bookmarks: [bookmark], drafts: [connection.id.uuidString: "SELECT 2;"], selectedConnection: connection.id)
        try files.save(state)
        try files.save(WorkspaceState(connections: [], bookmarks: []))
        let backups = try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("Backups"), includingPropertiesForKeys: nil)
        let backup = try JSONDecoder().decode(WorkspaceState.self, from: Data(contentsOf: XCTUnwrap(backups.first)))
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(backup.connections, state.connections)
        XCTAssertEqual(backup.bookmarks, state.bookmarks)
        XCTAssertEqual(backup.drafts, state.drafts)
        XCTAssertEqual(backup.selectedConnection, state.selectedConnection)
        XCTAssertTrue(try XCTUnwrap(files.load()).connections.isEmpty)
    }

    func testDraftEditsCreateOnlyOneBaselineBackup() throws {
        let directory = try temporaryDirectory()
        let files = WorkspaceFileStore(directory: directory)
        let connection = DBConnection(name: "Development")
        var state = WorkspaceState(connections: [connection], bookmarks: [], selectedConnection: connection.id)
        try files.save(state)
        for index in 1...5 {
            state.drafts[connection.id.uuidString] = "SELECT \(index);"
            try files.save(state)
        }
        let backups = try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("Backups").path)
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try XCTUnwrap(files.load()).drafts, state.drafts)
    }

    func testBackupFailureLeavesWorkspaceUntouched() throws {
        let directory = try temporaryDirectory()
        let files = WorkspaceFileStore(directory: directory)
        try files.save(WorkspaceState(connections: [DBConnection(name: "Development")], bookmarks: []))
        let file = directory.appendingPathComponent("workspace.json")
        let original = try Data(contentsOf: file)
        try Data("blocking file".utf8).write(to: directory.appendingPathComponent("Backups"))
        XCTAssertThrowsError(try files.save(WorkspaceState(connections: [], bookmarks: [])))
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    func testStorageFailuresAreReportedWithoutOverwritingTheBlockingFile() throws {
        let directory = try temporaryDirectory()
        let blocker = directory.appendingPathComponent("not-a-directory")
        let original = Data("keep this file".utf8)
        try original.write(to: blocker)
        let files = WorkspaceFileStore(directory: blocker)
        let state = WorkspaceState(connections: [], bookmarks: [])
        XCTAssertThrowsError(try files.load())
        XCTAssertThrowsError(try files.save(state))
        XCTAssertEqual(try Data(contentsOf: blocker), original)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return directory
    }
}
