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

    func testTypingIdentifierAndQualifierOpensSuggestions() async throws {
        let (state, view, coordinator) = editor("SELECT * FROM c|")
        defer { coordinator.stopObserving() }
        view.keyDown(with: key("u", code: 32))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(state.text, "SELECT * FROM cu")
        XCTAssertEqual(coordinator.completion?.candidates.first?.name, "customers")

        view.string = "SELECT customers"
        view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
        view.keyDown(with: key(".", code: 47))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(coordinator.completion?.candidates.map(\.name), ["email", "id", "name"])
    }

    func testEditingAndNavigationKeysDoNotOpenSuggestions() async throws {
        let keys: [(String, UInt16)] = [(" ", 49), ("\t", 48), ("\r", 36), ("\u{3}", 76), ("\u{7f}", 51), ("\u{f728}", 117), ("\u{f702}", 123), ("\u{f703}", 124), ("\u{f700}", 126), ("\u{f701}", 125)]
        for (characters, code) in keys {
            let (state, view, coordinator) = editor("SELECT * FROM c|u")
            view.keyDown(with: key(characters, code: code))
            try await Task.sleep(for: .milliseconds(160))
            XCTAssertNil(coordinator.completion, "Unexpected suggestions for key code \(code): \(state.text)")
            coordinator.stopObserving()
        }
    }

    func testNavigationAndWhitespaceCancelPendingTypingSuggestions() async throws {
        for (characters, code): (String, UInt16) in [("\u{f702}", 123), (" ", 49), ("\u{7f}", 51)] {
            let (_, view, coordinator) = editor("SELECT * FROM c|")
            view.keyDown(with: key("u", code: 32))
            view.keyDown(with: key(characters, code: code))
            try await Task.sleep(for: .milliseconds(200))
            XCTAssertNil(coordinator.completion)
            coordinator.stopObserving()
        }
    }

    func testPastingAndAcceptingCompletionDoNotReopenSuggestions() async throws {
        let (_, view, coordinator) = editor("SELECT * FROM c|")
        defer { coordinator.stopObserving() }
        view.insertText("u", replacementRange: view.selectedRange())
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(coordinator.completion)

        view.keyDown(with: key(" ", code: 49, modifiers: .control))
        XCTAssertEqual(coordinator.completion?.candidates.first?.name, "customers")
        view.keyDown(with: key("\t", code: 48))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(view.string, "SELECT * FROM customers")
        XCTAssertNil(coordinator.completion)
    }

    func testMongoTypingAndTabUseCollectionSuggestions() async throws {
        let (state, view, coordinator) = editor("db.c|", kind: .mongodb)
        defer { coordinator.stopObserving() }
        view.keyDown(with: key("u", code: 32))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(coordinator.completion?.candidates.first?.name, "customers")
        view.keyDown(with: key("\t", code: 48))
        XCTAssertEqual(state.text, "db.customers")
        XCTAssertNil(coordinator.completion)
    }

    func testMongoLazyFieldsReplaceQuotedKeyAndIgnoreStaleResponse() async throws {
        var requested: [String] = []
        let (state, view, coordinator) = editor("db.customers.find({'em|ail': ''})", kind: .mongodb, loadFields: { name in
            requested.append(name)
            try? await Task.sleep(for: .milliseconds(50))
            return [SchemaColumn(name: "email", type: "STRING")]
        })
        defer { coordinator.stopObserving() }
        coordinator.parent.tables = [SchemaTable(name: "customers")]
        coordinator.updateCompletion(view)
        XCTAssertNil(coordinator.completion)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(requested, ["customers"])
        XCTAssertEqual(coordinator.completion?.candidates.first?.name, "email")
        XCTAssertTrue(coordinator.textView(view, doCommandBy: #selector(NSResponder.insertTab(_:))))
        XCTAssertEqual(state.text, "db.customers.find({'email': ''})")
        view.setSelectedRange(NSRange(location: (view.string as NSString).range(of: "email").location + 2, length: 0))
        coordinator.updateCompletion(view, explicit: true)
        view.setSelectedRange(NSRange(location: 0, length: 0))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(coordinator.completion)
    }

    func testMongoNavigationAndWhitespaceDoNotOpenSuggestions() async throws {
        for (characters, code): (String, UInt16) in [(" ", 49), ("\u{7f}", 51), ("\u{f702}", 123), ("\r", 36)] {
            let (_, view, coordinator) = editor("db.c|u", kind: .mongodb)
            view.keyDown(with: key(characters, code: code))
            try await Task.sleep(for: .milliseconds(160))
            XCTAssertNil(coordinator.completion)
            coordinator.stopObserving()
        }
    }

    private func key(_ characters: String, code: UInt16, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
    }

    private func editor(_ marked: String, kind: DBConnection.Kind = .sample, loadFields: @escaping (String) async -> [SchemaColumn] = { _ in [] }) -> (CompletionState, SQLCompletionTextView, SQLTextEditor.Coordinator) {
        let cursor = (marked as NSString).range(of: "|").location
        let state = CompletionState(marked.replacingOccurrences(of: "|", with: ""))
        let tables = [
            SchemaTable(name: "customers", columns: [SchemaColumn(name: "id", type: "INTEGER"), SchemaColumn(name: "name", type: "TEXT"), SchemaColumn(name: "email", type: "TEXT")]),
            SchemaTable(name: "orders", columns: [SchemaColumn(name: "total", type: "REAL")])
        ]
        let editor = SQLTextEditor(text: Binding(get: { state.text }, set: { state.text = $0 }),
            selection: Binding(get: { state.selection }, set: { state.selection = $0 }),
            cursorLocation: Binding(get: { state.cursor }, set: { state.cursor = $0 }), tables: tables, connectionKind: kind, loadMongoFields: loadFields)
        let coordinator = SQLTextEditor.Coordinator(editor)
        let scroll = editor.makeScrollView(coordinator: coordinator)
        let view = scroll.documentView as! SQLCompletionTextView
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 280), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = scroll
        window.makeFirstResponder(view)
        state.window = window
        view.setSelectedRange(NSRange(location: cursor, length: 0))
        return (state, view, coordinator)
    }
}

private final class CompletionState {
    var text: String
    var selection = ""
    var cursor = 0
    var window: NSWindow?
    init(_ text: String) { self.text = text }
}
