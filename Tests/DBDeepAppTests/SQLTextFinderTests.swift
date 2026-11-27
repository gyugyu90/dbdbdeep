import AppKit
import SwiftUI
import XCTest
@testable import DBDeepApp

@MainActor
final class SQLTextFinderTests: XCTestCase {
    func testFindUsesInlineBarAndEscapeReturnsFocusWithoutChangingSQL() throws {
        let (window, scroll, editor, coordinator) = makeEditor("SELECT '고객 🌷';\nSELECT '고객 🌷';")
        defer { coordinator.stopObserving(); window.contentView = nil }
        let original = editor.string
        XCTAssertTrue(editor.usesFindBar)
        XCTAssertTrue(editor.isIncrementalSearchingEnabled)
        let finder = try XCTUnwrap(editor.findController)
        window.makeFirstResponder(editor)
        XCTAssertNil(finder.handle(key(3, "ㄹ", window: window)))
        XCTAssertTrue(scroll.isFindBarVisible)
        XCTAssertNotNil(scroll.findBarView)
        XCTAssertEqual(editor.string, original)
        window.makeFirstResponder(editor)
        XCTAssertNil(finder.handle(key(53, "\u{1b}", modifiers: [], window: window)))
        XCTAssertFalse(scroll.isFindBarVisible)
        XCTAssertTrue(window.firstResponder === editor)
        XCTAssertEqual(editor.string, original)
    }

    func testFindShortcutsStayInsideTheirEditorAndSearchField() throws {
        let (window, scroll, editor, coordinator) = makeEditor("SELECT 1;")
        defer { coordinator.stopObserving(); window.contentView = nil }
        let finder = try XCTUnwrap(editor.findController)
        let external = NSTextView(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
        scroll.addSubview(external)
        window.makeFirstResponder(external)
        XCTAssertNotNil(finder.handle(key(3, "f", window: window)))
        XCTAssertFalse(scroll.isFindBarVisible)
        window.makeFirstResponder(editor)
        XCTAssertNotNil(finder.handle(key(3, "f", modifiers: [.command, .option], window: window)))
        finder.perform(.showFindInterface)
        let bar = try XCTUnwrap(scroll.findBarView)
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
        bar.addSubview(field)
        window.makeFirstResponder(field)
        XCTAssertTrue((window.firstResponder as? NSTextView)?.isFieldEditor == true)
        XCTAssertNil(finder.handle(key(53, "\u{1b}", modifiers: [], window: window)))
        XCTAssertFalse(scroll.isFindBarVisible)
        XCTAssertTrue(window.firstResponder === editor)
    }

    func testNextPreviousSearchCommandsReachTheNativeFinder() throws {
        let (window, _, editor, coordinator) = makeEditor("SELECT 1;\nSELECT 2;")
        defer { coordinator.stopObserving(); window.contentView = nil }
        let finder = try XCTUnwrap(editor.findController)
        window.makeFirstResponder(editor)
        XCTAssertNil(finder.handle(key(5, "ㅎ", window: window)))
        XCTAssertNil(finder.handle(key(5, "ㅎ", modifiers: [.command, .shift], window: window)))
        XCTAssertEqual(editor.string, "SELECT 1;\nSELECT 2;")
    }

    private func makeEditor(_ text: String) -> (NSWindow, NSScrollView, SQLCompletionTextView, SQLTextEditor.Coordinator) {
        let editor = SQLTextEditor(text: .constant(text), selection: .constant(""))
        let coordinator = editor.makeCoordinator()
        let scroll = editor.makeScrollView(coordinator: coordinator)
        scroll.frame = NSRect(x: 0, y: 0, width: 640, height: 280)
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = scroll
        scroll.layoutSubtreeIfNeeded()
        return (window, scroll, scroll.documentView as! SQLCompletionTextView, coordinator)
    }

    private func key(_ code: UInt16, _ text: String, modifiers: NSEvent.ModifierFlags = .command, window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)!
    }
}
