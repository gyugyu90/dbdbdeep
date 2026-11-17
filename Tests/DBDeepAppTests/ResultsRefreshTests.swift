import XCTest
import AppKit
import DBDeepCore
@testable import DBDeepApp

@MainActor
final class ResultsRefreshTests: XCTestCase {
    func testRefreshRunsOriginalSelectionAndPreservesEditedConsoleAndSelection() async throws {
        let store = try makeStore()
        XCTAssertFalse(store.canRefreshResults)
        store.query = "SELECT 'not selected'; SELECT 'original result';"
        store.selectedSQL = "SELECT 'original result';"
        await store.run()
        let previousID = store.result?.id
        store.query = "SELECT * FROM should_not_run;"
        store.selectedSQL = "should_not_run"
        store.cursorLocation = 9
        XCTAssertTrue(store.canRefreshResults)

        await store.refreshResults()

        XCTAssertNil(store.error)
        XCTAssertEqual(store.result?.rows, [["original result"]])
        XCTAssertNotEqual(store.result?.id, previousID)
        XCTAssertEqual(store.history.map(\.sql), Array(repeating: "SELECT 'original result';", count: 2))
        XCTAssertEqual(store.query, "SELECT * FROM should_not_run;")
        XCTAssertEqual(store.selectedSQL, "should_not_run")
        XCTAssertEqual(store.cursorLocation, 9)
    }

    func testFailureKeepsPreviousResultsRefreshTargetAndCommitRemovesIt() async throws {
        let store = try makeStore()
        store.query = "SELECT 'last successful result';"
        await store.run()
        store.query = "SELECT * FROM missing_table;"
        await store.run()
        XCTAssertNotNil(store.error)
        XCTAssertTrue(store.canRefreshResults)
        await store.refreshResults()
        XCTAssertNil(store.error)
        XCTAssertEqual(store.result?.rows, [["last successful result"]])
        await store.transaction(commit: true)
        XCTAssertNil(store.result)
        XCTAssertFalse(store.canRefreshResults)
        let count = store.history.count
        await store.refreshResults()
        XCTAssertEqual(store.history.count, count)
    }

    func testRefreshTargetBelongsToTheSelectedConnection() async throws {
        let store = try makeStore()
        let first = try XCTUnwrap(store.connection)
        let second = DBConnection(name: "Second", kind: .sample)
        store.connections.append(second)
        store.query = "SELECT 'first';"
        await store.run()
        store.select(second)
        XCTAssertFalse(store.canRefreshResults)
        store.query = "SELECT 'second';"
        await store.run()
        store.select(first)
        await store.refreshResults()
        XCTAssertEqual(store.result?.rows, [["first"]])
        store.select(second)
        await store.refreshResults()
        XCTAssertEqual(store.result?.rows, [["second"]])
    }

    func testPreviewAndBookmarkResultsRefreshTheirOwnQueries() async throws {
        let store = try makeStore()
        await store.browse(SchemaTable(name: "customers"))
        store.query = "SELECT * FROM should_not_run;"
        await store.refreshResults()
        XCTAssertNil(store.error)
        XCTAssertEqual(store.history.first?.sql, "SELECT *\nFROM \"customers\"\nLIMIT 100;")
        let bookmark = QueryBookmark(name: "Saved", sql: "SELECT 'bookmark';", connectionID: store.selectedID)
        await store.runBookmark(bookmark)
        store.query = "SELECT 'edited console';"
        await store.refreshResults()
        XCTAssertEqual(store.result?.rows, [["bookmark"]])
        XCTAssertEqual(store.query, "SELECT 'edited console';")
    }

    func testBusyRefreshIsIgnored() async throws {
        let store = try makeStore()
        store.query = "SELECT 1;"
        await store.run()
        let previousID = store.result?.id
        store.isBusy = true
        XCTAssertFalse(store.canRefreshResults)
        await store.refreshResults()
        XCTAssertEqual(store.result?.id, previousID)
        XCTAssertEqual(store.history.count, 1)
        store.isBusy = false
    }

    func testShortcutOnlyConsumesCommandRWhenResultsOwnFirstResponder() throws {
        let (window, scope, editor, child) = makeShortcutWindow()
        defer { window.contentView = nil }
        var refreshed = 0
        scope.canRefresh = true
        scope.refresh = { refreshed += 1 }
        window.makeFirstResponder(editor)
        XCTAssertNotNil(scope.handle(key(window)))
        XCTAssertEqual(refreshed, 0)
        window.makeFirstResponder(scope)
        XCTAssertNil(scope.handle(key(window)))
        XCTAssertEqual(refreshed, 1)
        window.makeFirstResponder(child)
        XCTAssertNil(scope.handle(key(window)))
        XCTAssertEqual(refreshed, 2)
        XCTAssertTrue(window.firstResponder === scope)
        XCTAssertNotNil(scope.handle(key(window, modifiers: [.command, .shift])))
        XCTAssertNotNil(scope.handle(key(window, modifiers: [])))
        XCTAssertNotNil(scope.handle(key(window, character: "e")))
        XCTAssertEqual(refreshed, 2)
        XCTAssertNil(scope.handle(key(window, repeats: true)))
        scope.canRefresh = false
        XCTAssertNil(scope.handle(key(window)))
        XCTAssertEqual(refreshed, 2)
    }

    func testResultsClickMovesFocusWithoutConsumingMouseEventOrOtherWindowsKeys() throws {
        let (window, scope, editor, _) = makeShortcutWindow()
        defer { window.contentView = nil }
        window.makeFirstResponder(editor)
        let click = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 50, y: 50), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        XCTAssertNotNil(scope.handle(click))
        XCTAssertTrue(window.firstResponder === scope)
        let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        XCTAssertNotNil(scope.handle(key(other)))
    }

    private func makeStore() throws -> AppStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return AppStore(directory: directory)
    }

    private func makeShortcutWindow() -> (NSWindow, ResultsShortcutView, RefreshTestResponder, NSTextView) {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
        let child = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let scope = ResultsShortcutView(content: child)
        scope.frame = NSRect(x: 0, y: 0, width: 300, height: 200)
        let editor = RefreshTestResponder(frame: NSRect(x: 0, y: 250, width: 300, height: 100))
        root.addSubview(scope); root.addSubview(editor)
        let window = NSWindow(contentRect: root.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = root
        return (window, scope, editor, child)
    }

    private func key(_ window: NSWindow, character: String = "r", modifiers: NSEvent.ModifierFlags = .command, repeats: Bool = false) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: character, charactersIgnoringModifiers: character, isARepeat: repeats, keyCode: 15)!
    }
}

private final class RefreshTestResponder: NSView {
    override var acceptsFirstResponder: Bool { true }
}
