import AppKit
import SwiftUI
import XCTest
@testable import DBDeepApp

@MainActor
final class SQLSelectionTests: XCTestCase {
    func testOnlySelectedBlockRunsFromEditorContainingSeveralStatements() async throws {
        let store = try makeStore()
        store.query = "SELECT 'before' AS marker;\nSELECT 'selected' AS marker;\nSELECT * FROM should_not_run;"
        store.selectedSQL = "SELECT 'selected' AS marker;"
        let original = store.query

        await store.run()

        XCTAssertNil(store.error)
        XCTAssertEqual(store.result?.rows, [["selected"]])
        XCTAssertEqual(store.history.map(\.sql), [store.selectedSQL])
        XCTAssertEqual(store.query, original)
    }

    func testNoSelectionRunsOnlyStatementAtCursor() async throws {
        let store = try makeStore()
        store.query = "SELECT 'first' AS marker; SELECT 'last' AS marker;"
        store.cursorLocation = (store.query as NSString).range(of: "last").location

        await store.run()

        XCTAssertNil(store.error)
        XCTAssertEqual(store.result?.rows, [["last"]])
        XCTAssertEqual(store.history.map(\.sql), ["SELECT 'last' AS marker;"])
    }

    func testDefaultCursorRunsFirstStatementWithoutExecutingLaterSQL() async throws {
        let store = try makeStore()
        store.query = "SELECT 'first' AS marker; SELECT * FROM should_not_run;"

        await store.run()

        XCTAssertNil(store.error)
        XCTAssertEqual(store.result?.rows, [["first"]])
        XCTAssertEqual(store.history.map(\.sql), ["SELECT 'first' AS marker;"])
    }

    func testCursorInBlankGapDoesNotRunNeighboringStatements() async throws {
        let store = try makeStore()
        store.query = "SELECT 'first';\n\n\nSELECT 'last';"
        store.cursorLocation = (store.query as NSString).range(of: "\n\n\n").location + 1

        await store.run()

        XCTAssertFalse(store.canRunQuery)
        XCTAssertNil(store.result)
        XCTAssertTrue(store.history.isEmpty)
    }

    func testWhitespaceSelectionNeverFallsBackToFullEditor() async throws {
        let store = try makeStore()
        store.query = "SELECT 'must not run' AS marker;"
        store.selectedSQL = " \n\t "
        XCTAssertFalse(store.canRunQuery)

        await store.run()

        XCTAssertNil(store.result)
        XCTAssertTrue(store.history.isEmpty)
        XCTAssertFalse(store.isConnected)
    }

    func testNativeSelectionUsesUTF16RangeAndUpdatesWhenCleared() {
        let state = EditorState(text: "-- 한글 🌷\nSELECT '선택 💜' AS marker;\nSELECT 'other';")
        let editor = SQLTextEditor(text: state.textBinding, selection: state.selectionBinding, cursorLocation: state.cursorBinding)
        let coordinator = SQLTextEditor.Coordinator(editor)
        let view = NSTextView()
        view.string = state.text
        view.delegate = coordinator
        let selected = "SELECT '선택 💜' AS marker;"

        view.setSelectedRange((view.string as NSString).range(of: selected))

        XCTAssertEqual(state.selection, selected)
        XCTAssertEqual(state.cursorLocation, (view.string as NSString).range(of: selected).location)
        view.setSelectedRange(NSRange(location: 0, length: 0))
        XCTAssertEqual(state.selection, "")
        XCTAssertEqual(state.cursorLocation, 0)
    }

    func testReplacingSelectionClearsStaleExecutionText() {
        let state = EditorState(text: "SELECT 'old' AS marker;")
        let editor = SQLTextEditor(text: state.textBinding, selection: state.selectionBinding)
        let coordinator = SQLTextEditor.Coordinator(editor)
        let view = NSTextView()
        view.string = state.text
        view.delegate = coordinator
        view.setSelectedRange(NSRange(location: 0, length: (view.string as NSString).length))
        XCTAssertEqual(state.selection, "SELECT 'old' AS marker;")
        let updated = "SELECT 'new' AS marker;"
        view.textStorage?.replaceCharacters(in: view.selectedRange(), with: updated)
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: view))

        XCTAssertEqual(state.text, updated)
        XCTAssertEqual(state.selection, "")
    }

    private func makeStore() throws -> AppStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return AppStore(directory: directory)
    }
}

private final class EditorState {
    var text: String
    var selection = ""
    var cursorLocation = 0
    init(text: String) { self.text = text }
    var textBinding: Binding<String> { Binding(get: { self.text }, set: { self.text = $0 }) }
    var selectionBinding: Binding<String> { Binding(get: { self.selection }, set: { self.selection = $0 }) }
    var cursorBinding: Binding<Int> { Binding(get: { self.cursorLocation }, set: { self.cursorLocation = $0 }) }
}
