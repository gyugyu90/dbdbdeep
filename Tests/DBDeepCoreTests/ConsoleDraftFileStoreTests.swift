import XCTest
@testable import DBDeepCore

final class ConsoleDraftFileStoreTests: XCTestCase {
    func testLargeUnicodeDraftsAndIntentionalEmptyConsoleRoundTrip() throws {
        let files = ConsoleDraftFileStore(directory: try temporaryDirectory())
        XCTAssertTrue(try files.load().drafts.isEmpty)
        let query = String(repeating: "SELECT '한글 🌷' FROM dual;\n", count: 100_000)
        let drafts = ["oracle": ConsoleDraft(connectionName: "Oracle", query: query),
                      "mongo": ConsoleDraft(connectionName: "Mongo", query: "db.items.find({})"),
                      "empty": ConsoleDraft(connectionName: "Empty", query: "")]
        try files.save(drafts)
        XCTAssertEqual(try files.load().drafts, drafts)
        XCTAssertFalse(try files.load().recoveredFromBackup)
    }

    func testCorruptCurrentRecoversPreviousAndPreservesDamagedFileOnNextSave() throws {
        let files = ConsoleDraftFileStore(directory: try temporaryDirectory())
        let first = ["db": ConsoleDraft(connectionName: "DB", query: "SELECT 1;")]
        try files.save(first)
        try files.save(["db": ConsoleDraft(connectionName: "DB", query: "SELECT 2;")])
        let current = files.directory.appendingPathComponent("current.json")
        let damaged = Data("{unfinished".utf8)
        try damaged.write(to: current)
        XCTAssertEqual(try files.load().drafts, first)
        XCTAssertTrue(try files.load().recoveredFromBackup)
        try files.save(first)
        XCTAssertFalse(try files.load().recoveredFromBackup)
        let preserved = try FileManager.default.contentsOfDirectory(at: files.directory, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.hasPrefix("unreadable-") }
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(preserved)), damaged)
    }

    func testUnreadableDraftsWithoutBackupCannotBeOverwritten() throws {
        let files = ConsoleDraftFileStore(directory: try temporaryDirectory())
        try FileManager.default.createDirectory(at: files.directory, withIntermediateDirectories: true)
        let current = files.directory.appendingPathComponent("current.json")
        let original = Data("broken draft".utf8)
        try original.write(to: current)
        XCTAssertThrowsError(try files.load())
        XCTAssertThrowsError(try files.save([:]))
        XCTAssertEqual(try Data(contentsOf: current), original)
    }

    func testClearingConsoleKeepsCheckpointEvenDuringFrequentEdits() throws {
        let files = ConsoleDraftFileStore(directory: try temporaryDirectory())
        let start = Date()
        for index in 0..<5 {
            try files.save(["db": ConsoleDraft(connectionName: "DB", query: "SELECT \(index);")], now: start.addingTimeInterval(Double(index)))
        }
        let history = files.directory.appendingPathComponent("History")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: history.path).count, 1)
        try files.save(["db": ConsoleDraft(connectionName: "DB", query: "")], now: start.addingTimeInterval(5))
        XCTAssertEqual(try files.load().drafts["db"]?.query, "")
        let checkpoints = try FileManager.default.contentsOfDirectory(at: history, includingPropertiesForKeys: nil)
        XCTAssertEqual(checkpoints.count, 2)
        let values = try checkpoints.map { try JSONDecoder().decode(ConsoleDraftFileStore.Snapshot.self, from: Data(contentsOf: $0)) }
        XCTAssertTrue(values.contains { $0.drafts["db"]?.query == "SELECT 4;" })
    }

    func testHistoryIsBoundedAndCanRecoverWhenBothRecentFilesAreCorrupt() throws {
        let files = ConsoleDraftFileStore(directory: try temporaryDirectory())
        let start = Date()
        for index in 0..<30 {
            try files.save(["db": ConsoleDraft(connectionName: "DB", query: "SELECT \(index);")], now: start.addingTimeInterval(Double(index) * 301))
        }
        let history = files.directory.appendingPathComponent("History")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: history.path).count, 20)
        for name in ["current.json", "previous.json"] {
            try Data("broken".utf8).write(to: files.directory.appendingPathComponent(name))
        }
        XCTAssertEqual(try files.load().drafts["db"]?.query, "SELECT 28;")
        XCTAssertTrue(try files.load().recoveredFromBackup)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return directory
    }
}
