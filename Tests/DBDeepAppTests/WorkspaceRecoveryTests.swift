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

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return directory
    }
}
