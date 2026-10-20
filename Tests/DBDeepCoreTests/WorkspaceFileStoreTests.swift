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
        XCTAssertThrowsError(try WorkspaceFileStore(directory: directory).load())
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
