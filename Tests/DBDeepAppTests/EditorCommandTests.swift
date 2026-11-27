import AppKit
import XCTest
import DBDeepCore
@testable import DBDeepApp

@MainActor
final class EditorCommandTests: XCTestCase {
    func testKoreanAndOtherInputSourcesNormalizeCommandKeysOnly() throws {
        for (code, text, expected) in [(UInt16(15), "ㄱ", "r"), (8, "ㅊ", "c"), (2, "ㅇ", "d"), (45, "ㅜ", "n"), (14, "у", "e")] {
            let event = key(code, text)
            XCTAssertEqual(CommandKeyboard.character(in: event), expected)
            let normalized = CommandKeyboard.normalize(event)
            XCTAssertEqual(normalized.charactersIgnoringModifiers, expected)
            XCTAssertEqual(normalized.keyCode, code)
            XCTAssertEqual(normalized.modifierFlags, event.modifierFlags)
        }
        XCTAssertEqual(CommandKeyboard.normalize(key(14, "ㄷ", modifiers: [.command, .shift])).charactersIgnoringModifiers, "E")
        XCTAssertEqual(CommandKeyboard.normalize(key(15, "ㄱ", modifiers: [])).charactersIgnoringModifiers, "ㄱ")
        XCTAssertEqual(CommandKeyboard.normalize(key(15, "ㄱ", modifiers: [.command, .option])).charactersIgnoringModifiers, "ㄱ")
    }

    func testResultsRefreshAndCopyRecognizeKoreanEventsWithoutMonitorOrdering() {
        let scope = ResultsShortcutView(content: NSView())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = scope
        defer { window.contentView = nil }
        window.makeFirstResponder(scope)
        var refreshed = 0; var copied = 0
        scope.canRefresh = true; scope.refresh = { refreshed += 1 }
        scope.canCopy = true; scope.copySelection = { copied += 1 }
        XCTAssertNil(scope.handle(key(15, "ㄱ", window: window)))
        XCTAssertNil(scope.handle(key(8, "ㅊ", window: window)))
        XCTAssertEqual(refreshed, 1); XCTAssertEqual(copied, 1)
    }

    func testBothCommentShortcutsAndSelectionIndentWorkInNativeEditor() {
        let view = SQLCompletionTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        defer { window.contentView = nil }
        window.makeFirstResponder(view)
        view.string = "SELECT 1;\nSELECT 2;"
        view.setSelectedRange(NSRange(location: 0, length: view.string.utf16.count))
        XCTAssertTrue(view.performKeyEquivalent(with: key(44, "/", window: window)))
        XCTAssertEqual(view.string, "-- SELECT 1;\n-- SELECT 2;")
        XCTAssertTrue(view.performKeyEquivalent(with: key(27, "-", window: window)))
        XCTAssertEqual(view.string, "SELECT 1;\nSELECT 2;")
        XCTAssertTrue(view.performKeyEquivalent(with: key(48, "\t", modifiers: [], window: window)))
        XCTAssertEqual(view.string, "    SELECT 1;\n    SELECT 2;")
        XCTAssertTrue(view.performKeyEquivalent(with: key(48, "\t", modifiers: .shift, window: window)))
        XCTAssertEqual(view.string, "SELECT 1;\nSELECT 2;")
    }

    func testBookmarkHeaderUpdatesMatchingConsoleOnlyAndDoesNotDuplicateOnRename() throws {
        let store = try store()
        store.query = "SELECT 1;\n\n-- keep this note\nSELECT 2;\n\nSELECT 3;"
        store.cursorLocation = (store.query as NSString).range(of: "SELECT 2").location
        var bookmark = QueryBookmark(name: "Lookup", emoji: "🌷", sql: "SELECT 2;", connectionID: store.selectedID)
        XCTAssertTrue(store.saveBookmark(bookmark))
        XCTAssertEqual(store.query, "SELECT 1;\n\n/* 🌷 Lookup */\n-- keep this note\nSELECT 2;\n\nSELECT 3;")
        XCTAssertEqual(store.currentBookmark?.id, bookmark.id)
        bookmark = try XCTUnwrap(store.bookmarks.first { $0.id == bookmark.id })
        bookmark.name = "Renamed"; bookmark.emoji = "⚡️"
        XCTAssertTrue(store.saveBookmark(bookmark))
        XCTAssertFalse(store.query.contains("🌷 Lookup"))
        XCTAssertEqual(store.query.components(separatedBy: "/* ⚡️ Renamed */").count, 2)
        XCTAssertTrue(store.query.contains("-- keep this note"))
        XCTAssertEqual(store.currentBookmark?.id, bookmark.id)
    }

    func testBookmarkHeaderEscapesCommentDelimitersAndMongoFocusKeepsOneHeader() throws {
        let store = try store()
        let mongo = DBConnection(name: "Mongo fixture", kind: .mongodb)
        store.connections.append(mongo); store.select(mongo)
        store.query = "db.items.find({});"
        var bookmark = QueryBookmark(name: "Title */\nSELECT 9; /*", emoji: "🌷", sql: store.query, connectionID: mongo.id)
        XCTAssertTrue(store.saveBookmark(bookmark))
        bookmark = try XCTUnwrap(store.bookmarks.first { $0.id == bookmark.id })
        XCTAssertTrue(bookmark.sql.hasPrefix("/* 🌷 Title * / SELECT 9; / * */\n"))
        XCTAssertNotNil(QueryLanguage(.mongodb).singleStatement(in: bookmark.sql))
        XCTAssertTrue(store.focusBookmark(bookmark))
        XCTAssertTrue(store.focusBookmark(bookmark))
        XCTAssertEqual(store.query.components(separatedBy: BookmarkAnnotation.header(for: bookmark)).count, 2)
        XCTAssertEqual(store.currentBookmark?.id, bookmark.id)
    }

    private func store() throws -> AppStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return AppStore(directory: directory)
    }

    private func key(_ code: UInt16, _ text: String, modifiers: NSEvent.ModifierFlags = .command, window: NSWindow? = nil) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: window?.windowNumber ?? 0,
            context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)!
    }
}
