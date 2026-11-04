import AppKit
import SwiftUI
import XCTest
@testable import DBDeepApp

@MainActor
final class SQLLargeDocumentTests: XCTestCase {
    func testLineIndexHandlesUnicodeAndAllLineEndings() {
        let text = "한글 🌷\r\nsecond\rthird\nfourth\u{85}fifth\u{2028}sixth\u{2029}"
        let index = SQLLineIndex(text)
        XCTAssertEqual(index.count, 7)
        for (line, offset) in index.starts.enumerated() { XCTAssertEqual(index.line(at: offset), line) }
        XCTAssertEqual(index.line(at: 3), 0)
        XCTAssertEqual(index.length, (text as NSString).length)
        XCTAssertEqual(index.truncated(text, maximumLines: 1), "한글 🌷")
        XCTAssertEqual(index.truncated(text, maximumLines: 3), "한글 🌷\r\nsecond\rthird")
    }

    func testExactlyOneHundredThousandLinesAreKeptIncludingFinalEmptyLine() {
        let text = String(repeating: "-- 한글 🌷\n", count: 99_999)
        let index = SQLLineIndex(text)
        XCTAssertEqual(index.count, 100_000)
        XCTAssertNil(index.truncated(text))
        let oversized = text + "last\nremoved"
        XCTAssertEqual(SQLLineIndex(oversized).truncated(oversized), text + "last")
        XCTAssertEqual(SQLLineIndex(text + "\n").truncated(text + "\n"), text)
    }

    func testDocumentScrollsBeyondThirtySixLinesAndToLineOneHundredThousand() throws {
        let text = String(repeating: "-- line\n", count: 99_999) + "SELECT 100000;"
        let (_, scroll, view, coordinator) = editor(text)
        defer { coordinator.stopObserving() }
        scroll.frame = NSRect(x: 0, y: 0, width: 640, height: 280)
        scroll.layoutSubtreeIfNeeded()
        let end = NSRange(location: (text as NSString).length, length: 0)
        view.setSelectedRange(end)
        view.scrollRangeToVisible(end)
        XCTAssertGreaterThan(view.frame.height, 10_000)
        XCTAssertGreaterThan(scroll.contentView.bounds.minY, 10_000)
        let layout = try XCTUnwrap(view.layoutManager)
        let container = try XCTUnwrap(view.textContainer)
        let glyph = layout.glyphIndexForCharacter(at: end.location - 1)
        let lastLine = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).offsetBy(dx: view.textContainerInset.width, dy: view.textContainerInset.height)
        XCTAssertTrue(view.visibleRect.intersects(lastLine))
        XCTAssertEqual(container.containerSize.height, CGFloat.greatestFiniteMagnitude)
        XCTAssertEqual((scroll.verticalRulerView as? LineNumberRuler)?.lines.count, 100_000)
        XCTAssertGreaterThanOrEqual(scroll.verticalRulerView?.ruleThickness ?? 0, 60)
        XCTAssertTrue(view.layoutManager?.allowsNonContiguousLayout == true)
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: view))
        XCTAssertEqual(view.selectedRange(), end)
    }

    func testOversizedPasteTruncatesOnceAndCanBeUndone() {
        let (state, _, view, coordinator) = editor("SELECT 'keep 🌷';")
        defer { coordinator.stopObserving() }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 280), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view.enclosingScrollView
        window.makeFirstResponder(view)
        var alerts = 0
        coordinator.onTruncate = { alerts += 1 }
        view.setSelectedRange(NSRange(location: 0, length: (view.string as NSString).length))
        let pasted = String(repeating: "SELECT '한글 🌷';\r\n", count: 100_002)
        view.insertText(pasted, replacementRange: view.selectedRange())
        XCTAssertEqual(alerts, 1)
        XCTAssertEqual(SQLLineIndex(view.string).count, 100_000)
        XCTAssertFalse(view.string.hasSuffix("\r"))
        XCTAssertEqual(state.text, view.string)
        XCTAssertEqual(state.cursor, (view.string as NSString).length)
        view.undoManager?.undo()
        XCTAssertEqual(view.string, "SELECT 'keep 🌷';")
        XCTAssertEqual(state.text, view.string)
        XCTAssertEqual(alerts, 1)
    }

    func testReturnAtLimitIsRejectedButEditingAndReplacingLinesStillWork() {
        let text = String(repeating: "-- line\n", count: 99_999) + "last"
        let (state, _, view, coordinator) = editor(text)
        defer { coordinator.stopObserving() }
        var alerts = 0
        coordinator.onTruncate = { alerts += 1 }
        let end = (text as NSString).length
        view.setSelectedRange(NSRange(location: end, length: 0))
        view.insertText("\n", replacementRange: view.selectedRange())
        XCTAssertEqual(view.string, text)
        XCTAssertEqual(alerts, 1)
        view.insertText("!", replacementRange: view.selectedRange())
        XCTAssertTrue(state.text.hasSuffix("last!"))
        let range = (view.string as NSString).range(of: "-- line\n")
        view.insertText("replacement\n", replacementRange: range)
        XCTAssertEqual(SQLLineIndex(view.string).count, 100_000)
        XCTAssertTrue(state.text.hasPrefix("replacement\n"))
        XCTAssertEqual(alerts, 1)
    }

    func testSyntaxHighlightingKeepsMultilineContextAndOnlyReturnsVisibleMatches() {
        let text = "/*\n" + String(repeating: "SELECT 1;\n", count: 100_000) + "*/\nSELECT 'last';"
        let rules = SQLSyntaxHighlighter.rules
        let matches = SQLSyntaxHighlighter.matches(in: text, rules: rules, cancelled: { false })
        let comment = matches?.rules.last?.first
        XCTAssertEqual(comment?.location, 0)
        let visible = (text as NSString).range(of: "SELECT 'last'")
        XCTAssertEqual(SQLSyntaxHighlighter.visibleMatches(matches?.rules.last ?? [], in: visible).count, 0)
        XCTAssertEqual(SQLSyntaxHighlighter.visibleMatches(matches?.rules.first ?? [], in: visible).count, 1)
        XCTAssertNil(SQLSyntaxHighlighter.matches(in: text, rules: rules, cancelled: { true }))
    }

    func testQueryAnalysisCacheInvalidatesWhenTextAndCursorChange() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppStore(directory: directory)
        store.query = "SELECT 'first';\r\nSELECT 'second';"
        XCTAssertEqual(store.queryLineCount, 2)
        XCTAssertEqual(store.sqlToRun, "SELECT 'first';")
        store.cursorLocation = (store.query as NSString).length
        XCTAssertEqual(store.sqlToRun, "SELECT 'second';")
        store.query = "SELECT 'changed';"
        XCTAssertEqual(store.queryLineCount, 1)
        XCTAssertEqual(store.sqlToRun, "SELECT 'changed';")
        store.query = "-- unfinished comment"
        XCTAssertNil(store.cursorStatement)
        XCTAssertNil(store.cursorStatement)
        XCTAssertNil(store.currentBookmark)
        store.query = "SELECT * FROM customers WHERE plan = 'pro' ORDER BY name;"
        store.cursorLocation = (store.query as NSString).length
        let bookmark = store.currentBookmark
        store.cursorLocation = 0
        XCTAssertEqual(store.currentBookmark?.id, bookmark?.id)
    }

    private func editor(_ text: String) -> (LargeEditorState, NSScrollView, NSTextView, SQLTextEditor.Coordinator) {
        let state = LargeEditorState(text)
        let editor = SQLTextEditor(text: Binding(get: { state.text }, set: { state.text = $0 }),
            selection: Binding(get: { state.selection }, set: { state.selection = $0 }),
            cursorLocation: Binding(get: { state.cursor }, set: { state.cursor = $0 }))
        let coordinator = SQLTextEditor.Coordinator(editor)
        let scroll = editor.makeScrollView(coordinator: coordinator)
        let view = scroll.documentView as! NSTextView
        return (state, scroll, view, coordinator)
    }
}

private final class LargeEditorState {
    var text: String
    var selection = ""
    var cursor = 0
    init(_ text: String) { self.text = text }
}
