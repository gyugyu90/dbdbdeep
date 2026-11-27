import XCTest
@testable import DBDeepCore

final class SQLLineEditTests: XCTestCase {
    func testPartialSelectionCommentsWholeLinesAndTogglesBack() throws {
        let text = "SELECT 🌷\n  FROM customers\nWHERE id=1;\n"
        let range = NSRange(location: 3, length: (text as NSString).range(of: "WHERE").location - 3)
        let first = try XCTUnwrap(SQLLineEdit.make(in: text, selection: range, action: .toggleComment))
        let commented = (text as NSString).replacingCharacters(in: first.range, with: first.replacement)
        XCTAssertEqual(commented, "-- SELECT 🌷\n  -- FROM customers\nWHERE id=1;\n")
        let second = try XCTUnwrap(SQLLineEdit.make(in: commented, selection: first.selection, action: .toggleComment))
        XCTAssertEqual((commented as NSString).replacingCharacters(in: second.range, with: second.replacement), text)
    }

    func testMixedCommentsAndBlankLinesOnlyUncommentWhenAllLinesHavePrefix() throws {
        let text = "-- SELECT 1;\n\nSELECT 2;"
        let edit = try XCTUnwrap(SQLLineEdit.make(in: text, selection: NSRange(location: 0, length: text.utf16.count), action: .toggleComment))
        XCTAssertEqual(edit.replacement, "-- -- SELECT 1;\n-- \n-- SELECT 2;")
        let undo = try XCTUnwrap(SQLLineEdit.make(in: edit.replacement, selection: edit.selection, action: .toggleComment))
        XCTAssertEqual(undo.replacement, text)
    }

    func testTabAndBacktabMoveSelectedLinesFourSpacesAndKeepCRLF() throws {
        let text = "SELECT 1;\r\n  FROM x\r\nNEXT"
        let range = NSRange(location: 2, length: (text as NSString).range(of: "NEXT").location - 2)
        let indent = try XCTUnwrap(SQLLineEdit.make(in: text, selection: range, action: .indent))
        let updated = (text as NSString).replacingCharacters(in: indent.range, with: indent.replacement)
        XCTAssertEqual(updated, "    SELECT 1;\r\n      FROM x\r\nNEXT")
        let outdent = try XCTUnwrap(SQLLineEdit.make(in: updated, selection: indent.selection, action: .outdent))
        XCTAssertEqual((updated as NSString).replacingCharacters(in: outdent.range, with: outdent.replacement), text)
    }

    func testOutdentRemovesUpToFourSpacesOrOneExistingTab() throws {
        let text = " x\n  y\n    z\n\tw\nzero"
        let edit = try XCTUnwrap(SQLLineEdit.make(in: text, selection: NSRange(location: 0, length: text.utf16.count), action: .outdent))
        XCTAssertEqual(edit.replacement, "x\ny\nz\nw\nzero")
    }

    func testCaretAndFinalEmptyLineRemainValid() throws {
        let text = "SELECT 1;\n"
        let edit = try XCTUnwrap(SQLLineEdit.make(in: text, selection: NSRange(location: text.utf16.count, length: 0), action: .toggleComment))
        XCTAssertEqual(edit.replacement, "-- ")
        XCTAssertEqual(edit.selection, NSRange(location: text.utf16.count + 3, length: 0))
        XCTAssertNil(SQLLineEdit.make(in: text, selection: NSRange(location: NSNotFound, length: 0), action: .indent))
    }

    func testFullSizeConsoleCanIndentAndRestoreAllLines() throws {
        let text = Array(repeating: "SELECT '한글 🌷';", count: 100_000).joined(separator: "\n")
        let indented = try XCTUnwrap(SQLLineEdit.make(in: text, selection: NSRange(location: 0, length: text.utf16.count), action: .indent))
        XCTAssertTrue(indented.replacement.hasPrefix("    SELECT"))
        XCTAssertEqual(indented.replacement.utf16.count, text.utf16.count + 400_000)
        let restored = try XCTUnwrap(SQLLineEdit.make(in: indented.replacement, selection: indented.selection, action: .outdent))
        XCTAssertEqual(restored.replacement, text)
    }
}
