import AppKit
import SwiftUI
import XCTest
@testable import DBDeepApp

@MainActor
final class SQLSelectionTests: XCTestCase {
    func testBookmarkFocusRequestMovesNativeCaretOnlyOnceAndClearsSelection() {
        let state = EditorState(text: "SELECT '한글 🌷';\nSELECT 'saved 💜';")
        let range = (state.text as NSString).range(of: "SELECT 'saved 💜';")
        let request = SQLEditorFocus(range: range)
        state.cursorLocation = range.location
        let editor = SQLTextEditor(text: state.textBinding, selection: state.selectionBinding, cursorLocation: state.cursorBinding, focusRequest: request)
        let coordinator = SQLTextEditor.Coordinator(editor)
        let view = NSTextView()
        view.string = state.text
        view.setSelectedRange(NSRange(location: 0, length: 6))
        view.delegate = coordinator
        coordinator.applyFocus(request, in: view)
        XCTAssertEqual(view.selectedRange(), NSRange(location: range.location, length: 0))
        XCTAssertEqual(state.cursorLocation, range.location)
        XCTAssertTrue(state.selection.isEmpty)
        XCTAssertEqual(state.text, view.string)
        view.setSelectedRange(NSRange(location: 0, length: 0))
        coordinator.applyFocus(request, in: view)
        XCTAssertEqual(view.selectedRange().location, 0)
    }

    func testStaleOrInvalidFocusRequestDoesNotMoveNativeCaret() {
        let state = EditorState(text: "SELECT 1;")
        let editor = SQLTextEditor(text: state.textBinding, selection: state.selectionBinding)
        let coordinator = SQLTextEditor.Coordinator(editor)
        let view = NSTextView()
        view.string = state.text
        let stale = SQLEditorFocus(range: NSRange(location: 5, length: 1))
        view.setSelectedRange(NSRange(location: 0, length: 0))
        coordinator.applyFocus(stale, in: view)
        XCTAssertNil(coordinator.appliedFocusID)
        let invalid = SQLEditorFocus(range: NSRange(location: NSNotFound, length: 1))
        coordinator.parent.focusRequest = invalid
        coordinator.applyFocus(invalid, in: view)
        XCTAssertNil(coordinator.appliedFocusID)
        XCTAssertEqual(view.selectedRange().location, 0)
    }

    func testExternalTextSynchronizationDoesNotOverwriteRequestedCursorBindings() {
        let state = EditorState(text: "SELECT 'old';")
        let editor = SQLTextEditor(text: state.textBinding, selection: state.selectionBinding, cursorLocation: state.cursorBinding)
        let coordinator = SQLTextEditor.Coordinator(editor)
        let view = NSTextView()
        view.string = state.text
        view.delegate = coordinator
        state.text = "SELECT 'old';\n\nSELECT 'new';"
        state.cursorLocation = (state.text as NSString).range(of: "SELECT 'new';").location
        let target = state.cursorLocation
        coordinator.replaceText(in: view, with: state.text)
        XCTAssertEqual(view.string, state.text)
        XCTAssertEqual(state.cursorLocation, target)
        XCTAssertTrue(state.selection.isEmpty)
    }

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

    func testCursorInBlankGapRunsAndBookmarksTheSamePreviousStatement() async throws {
        let store = try makeStore()
        store.query = "SELECT 'first';\n\n\nSELECT 'last';"
        store.cursorLocation = (store.query as NSString).range(of: "\n\n\n").location + 1

        await store.run()

        XCTAssertTrue(store.canRunQuery)
        XCTAssertNil(store.error)
        XCTAssertEqual(store.result?.rows, [["first"]])
        store.newBookmark()
        XCTAssertEqual(store.bookmarkDraftSQL, store.history.first?.sql)
        XCTAssertEqual(store.sqlToRun, store.sqlToBookmark)
    }

    func testRunAndBookmarkUseTheSameNearestQueryAcrossCursorPositions() throws {
        let store = try makeStore()
        let first = "SELECT '한글 🌷' AS marker;"
        let middle = "SELECT 'middle' AS marker;"
        let last = "SELECT 'last' AS marker;"
        let draft = " \n" + first + "\n\n   " + middle + "   " + last + "\n\n-- trailing note"
        store.query = draft
        let source = draft as NSString
        let cases: [(Int, String)] = [
            (0, ""),
            (source.range(of: "한글").location, first),
            (source.range(of: "\n\n   ").location + 1, first),
            (source.range(of: "   SELECT").location + 2, first),
            (source.range(of: "middle").location, middle),
            (source.range(of: ";   SELECT").location + 2, middle),
            (source.range(of: "last").location, last),
            (source.length, last)
        ]
        for (cursor, expected) in cases {
            store.cursorLocation = cursor
            XCTAssertEqual(store.sqlToRun, expected, "Run at \(cursor)")
            XCTAssertEqual(store.sqlToBookmark, expected, "Bookmark at \(cursor)")
            XCTAssertEqual(store.canRunQuery, store.canBookmarkQuery)
        }
    }

    func testCursorAfterFinalQueryAndCommentRunsTheSameQueryThatWouldBeBookmarked() async throws {
        let store = try makeStore()
        store.query = "SELECT 'first';\nSELECT 'last';\n\n-- a trailing note 🌷\n"
        store.cursorLocation = store.query.utf16.count
        store.newBookmark()
        let target = store.bookmarkDraftSQL
        await store.run()
        XCTAssertNil(store.error)
        XCTAssertEqual(store.result?.rows, [["last"]])
        XCTAssertEqual(store.history.map(\.sql), [target])
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
