import AppKit
import DBDeepCore
import SwiftUI
import XCTest
@testable import DBDeepApp

@MainActor
final class SQLCompletionEditorTests: XCTestCase {
    func testTabReplacesWholeIdentifierAndUpdatesExecutionCursor() {
        let (state, view, coordinator) = editor("-- 한글 🌷\nSELECT em|ail FROM customers")
        coordinator.updateCompletion(view)
        XCTAssertEqual(coordinator.completion?.candidates.first?.name, "email")

        XCTAssertTrue(coordinator.textView(view, doCommandBy: #selector(NSResponder.insertTab(_:))))

        XCTAssertEqual(view.string, "-- 한글 🌷\nSELECT email FROM customers")
        XCTAssertEqual(state.text, view.string)
        XCTAssertEqual(state.cursor, (view.string as NSString).range(of: "email").location + 5)
        XCTAssertEqual(state.selection, "")
        XCTAssertNil(coordinator.completion)
    }

    func testArrowKeysChooseAndReturnInsertsWithoutNewline() {
        let (_, view, coordinator) = editor("SELECT * FROM |")
        coordinator.updateCompletion(view)
        XCTAssertEqual(coordinator.completion?.candidates.map(\.name), ["customers", "orders"])
        XCTAssertTrue(coordinator.textView(view, doCommandBy: #selector(NSResponder.moveDown(_:))))
        XCTAssertEqual(coordinator.selectedCompletion, 1)
        XCTAssertTrue(coordinator.textView(view, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        XCTAssertEqual(view.string, "SELECT * FROM orders")
        XCTAssertNil(coordinator.completion)
    }

    func testEscapeKeepsTextAndRestoresNormalReturn() {
        let (_, view, coordinator) = editor("SELECT * FROM cu|")
        coordinator.updateCompletion(view)
        let original = view.string
        XCTAssertTrue(coordinator.textView(view, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        XCTAssertEqual(view.string, original)
        XCTAssertNil(coordinator.completion)
        XCTAssertFalse(coordinator.textView(view, doCommandBy: #selector(NSResponder.insertNewline(_:))))
    }

    func testSelectionAndMarkedTextDoNotShowOrAcceptCompletions() {
        let (_, view, coordinator) = editor("SELECT * FROM cu|")
        view.setSelectedRange(NSRange(location: 0, length: 6))
        coordinator.updateCompletion(view)
        XCTAssertNil(coordinator.completion)
        view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
        view.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0), replacementRange: view.selectedRange())
        coordinator.updateCompletion(view)
        XCTAssertNil(coordinator.completion)
        XCTAssertFalse(coordinator.textView(view, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        view.unmarkText()
        coordinator.dismissCompletion()
    }

    func testCaretMovementDismissesStaleSuggestions() {
        let (_, view, coordinator) = editor("SELECT * FROM cu|")
        coordinator.updateCompletion(view)
        XCTAssertNotNil(coordinator.completion)
        view.setSelectedRange(NSRange(location: 0, length: 0))
        XCTAssertNil(coordinator.completion)
    }

    func testExplicitCompletionWorksWithoutTypingAnotherCharacter() {
        let (_, view, coordinator) = editor("SELECT | FROM customers")
        XCTAssertTrue(coordinator.textView(view, doCommandBy: #selector(NSResponder.complete(_:))))
        XCTAssertEqual(coordinator.completion?.candidates.map(\.name), ["email", "id", "name"])
        coordinator.dismissCompletion()
    }

    private func editor(_ marked: String) -> (CompletionState, NSTextView, SQLTextEditor.Coordinator) {
        let cursor = (marked as NSString).range(of: "|").location
        let state = CompletionState(marked.replacingOccurrences(of: "|", with: ""))
        let tables = [
            SchemaTable(name: "customers", columns: [SchemaColumn(name: "id", type: "INTEGER"), SchemaColumn(name: "name", type: "TEXT"), SchemaColumn(name: "email", type: "TEXT")]),
            SchemaTable(name: "orders", columns: [SchemaColumn(name: "total", type: "REAL")])
        ]
        let editor = SQLTextEditor(text: Binding(get: { state.text }, set: { state.text = $0 }),
            selection: Binding(get: { state.selection }, set: { state.selection = $0 }),
            cursorLocation: Binding(get: { state.cursor }, set: { state.cursor = $0 }), tables: tables, connectionKind: .sample)
        let coordinator = SQLTextEditor.Coordinator(editor)
        let view = NSTextView()
        view.isRichText = false
        view.string = state.text
        view.delegate = coordinator
        view.setSelectedRange(NSRange(location: cursor, length: 0))
        return (state, view, coordinator)
    }
}

private final class CompletionState {
    var text: String
    var selection = ""
    var cursor = 0
    init(_ text: String) { self.text = text }
}
