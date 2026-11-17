import XCTest
import AppKit
import UniformTypeIdentifiers
import DBDeepCore
@testable import DBDeepApp

final class ResultGridSelectionTests: XCTestCase {
    func testRectangleIncludesBothEndpointsAndWorksInEveryDirection() {
        let selection = ResultGridSelection(anchor: .init(row: 3, column: 4), extent: .init(row: 1, column: 2))
        XCTAssertEqual(selection.rowRange, 1...3)
        XCTAssertEqual(selection.columnRange, 2...4)
        XCTAssertTrue(selection.contains(.init(row: 1, column: 2)))
        XCTAssertTrue(selection.contains(.init(row: 2, column: 3)))
        XCTAssertTrue(selection.contains(.init(row: 3, column: 4)))
        XCTAssertFalse(selection.contains(.init(row: 0, column: 3)))
        XCTAssertFalse(selection.contains(.init(row: 2, column: 5)))
    }

    func testCopyUsesFilteredSortedRowsAndReorderedColumnsWithoutHeaders() {
        let result = QueryResult(columns: ["score", "name", "note"], rows: [["10", "keep A", "a"], ["2", "keep B", "b"], ["1", "other", "c"]])
        var grid = ResultGridState()
        grid.reset(for: result)
        grid.toggleSort(column: 0)
        grid.moveColumn(0, to: 2, after: true)
        let selection = ResultGridSelection(anchor: .init(row: 0, column: 0), extent: .init(row: 1, column: 1))
        XCTAssertEqual(selection.text(in: result, rowOrder: grid.rows(in: result, filter: "keep").map(\.offset), columnOrder: grid.columns(in: result), format: .tsv), "keep B\tb\nkeep A\ta")
        XCTAssertEqual(selection.text(in: result, rowOrder: [1, 0], columnOrder: [1, 2, 0], format: .csv), "keep B,b\r\nkeep A,a")
    }

    func testTabsQuotesCommasNewlinesAndUnicodeAreEscapedForEachFormat() {
        let result = QueryResult(columns: ["a", "b", "c"], rows: [["고객 🌷", "A\tB", "a,b"], ["line 1\nline 2", "say \"hello\"", "CR\rLF\r\n"]])
        let selection = ResultGridSelection(anchor: .init(row: 0, column: 0), extent: .init(row: 1, column: 2))
        XCTAssertEqual(selection.text(in: result, rowOrder: [0, 1], columnOrder: [0, 1, 2], format: .tsv), "고객 🌷\t\"A\tB\"\ta,b\n\"line 1\nline 2\"\t\"say \"\"hello\"\"\"\t\"CR\rLF\r\n\"")
        XCTAssertEqual(selection.text(in: result, rowOrder: [0, 1], columnOrder: [0, 1, 2], format: .csv), "고객 🌷,A\tB,\"a,b\"\r\n\"line 1\nline 2\",\"say \"\"hello\"\"\",\"CR\rLF\r\n\"")
    }

    func testNullAndMissingCellsRemainEmptyWhileLiteralNullStaysText() {
        let result = QueryResult(columns: ["a", "b", "c"], rows: [["A"], [nil, "", "NULL"]])
        let selection = ResultGridSelection(anchor: .init(row: 0, column: 0), extent: .init(row: 1, column: 2))
        XCTAssertEqual(selection.text(in: result, rowOrder: [0, 1], columnOrder: [0, 1, 2], format: .tsv), "A\t\t\n\t\tNULL")
        let single = ResultGridSelection(anchor: .init(row: 1, column: 2), extent: .init(row: 1, column: 2))
        XCTAssertEqual(single.text(in: result, rowOrder: [0, 1], columnOrder: [0, 1, 2], format: .tsv), "NULL")
    }

    func testStaleOrInvalidSelectionCannotCopyUnrelatedCells() {
        let result = QueryResult(columns: ["a"], rows: [["keep"]])
        let selection = ResultGridSelection(anchor: .init(row: 0, column: 0), extent: .init(row: 1, column: 1))
        XCTAssertNil(selection.text(in: result, rowOrder: [0], columnOrder: [0], format: .tsv))
        let single = ResultGridSelection(anchor: .init(row: 0, column: 0), extent: .init(row: 0, column: 0))
        XCTAssertNil(single.text(in: result, rowOrder: [99], columnOrder: [0], format: .tsv))
        XCTAssertNil(single.text(in: result, rowOrder: [0], columnOrder: [-1], format: .tsv))
        let negative = ResultGridSelection(anchor: .init(row: -1, column: 0), extent: .init(row: 0, column: 0))
        XCTAssertNil(negative.text(in: result, rowOrder: [0], columnOrder: [0], format: .tsv))
    }

    func testDraggingUsesResizedColumnBoundariesAndClampsOutsideGrid() {
        let layout = ResultGridLayout(columnWidths: [64, 175, 80], rowCount: 4)
        XCTAssertEqual(layout.cell(at: CGPoint(x: 38, y: 34)), .init(row: 0, column: 0))
        XCTAssertEqual(layout.cell(at: CGPoint(x: 102, y: 70)), .init(row: 1, column: 1))
        XCTAssertEqual(layout.cell(at: CGPoint(x: 277, y: 106)), .init(row: 2, column: 2))
        XCTAssertEqual(layout.cell(at: CGPoint(x: -100, y: -100)), .init(row: 0, column: 0))
        XCTAssertEqual(layout.cell(at: CGPoint(x: 10_000, y: 10_000)), .init(row: 3, column: 2))
        XCTAssertNil(layout.cell(at: CGPoint(x: CGFloat.nan, y: 0)))
        XCTAssertNil(ResultGridLayout(columnWidths: [], rowCount: 0).cell(at: .zero))
    }

    @MainActor
    func testAutoScrollOnlyMovesNearViewportEdgesAndCapsItsSpeed() {
        XCTAssertEqual(ResultGridDragScroller.offset(50, lower: 0, upper: 100), 0)
        XCTAssertLessThan(ResultGridDragScroller.offset(5, lower: 0, upper: 100), 0)
        XCTAssertGreaterThan(ResultGridDragScroller.offset(95, lower: 0, upper: 100), 0)
        XCTAssertEqual(ResultGridDragScroller.offset(-1000, lower: 0, upper: 100), -24)
        XCTAssertEqual(ResultGridDragScroller.offset(1000, lower: 0, upper: 100), 24)
    }

    @MainActor
    func testNativeAutoScrollMovesViewportAndUpdatesContentCoordinates() {
        let controller = ResultGridDragScroller()
        let document = ResultGridScrollProbe.Probe(frame: NSRect(x: 0, y: 0, width: 600, height: 1000))
        let probe = ResultGridScrollProbe.Probe(frame: .zero)
        document.addSubview(probe)
        controller.probe = probe
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        scroll.documentView = document
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = scroll
        defer { controller.stop(); window.contentView = nil }
        scroll.layoutSubtreeIfNeeded()
        let old = scroll.contentView.bounds.origin
        let pointer = scroll.contentView.convert(NSPoint(x: scroll.contentView.bounds.maxX + 20, y: scroll.contentView.bounds.maxY + 20), to: nil)
        var updated: CGPoint?
        controller.scroll(at: pointer) { updated = $0 }
        XCTAssertGreaterThan(scroll.contentView.bounds.minY, old.y)
        XCTAssertGreaterThan(scroll.contentView.bounds.minX, old.x)
        XCTAssertNotNil(updated)
        XCTAssertEqual(updated, probe.convert(pointer, from: nil))
    }

    @MainActor
    func testClipboardProvidesPlainTextAndTheSelectedTabularFormat() {
        let pasteboard = NSPasteboard(name: .init("dbdbdeep-selection-test-\(UUID())"))
        defer { pasteboard.clearContents() }
        XCTAssertTrue(ResultSelectionClipboard.write("A\tB\n1\t2", format: .tsv, to: pasteboard))
        XCTAssertEqual(pasteboard.string(forType: .string), "A\tB\n1\t2")
        XCTAssertEqual(pasteboard.string(forType: .tabularText), "A\tB\n1\t2")
        XCTAssertTrue(ResultSelectionClipboard.write("A,B\r\n1,2", format: .csv, to: pasteboard))
        XCTAssertEqual(pasteboard.string(forType: .string), "A,B\r\n1,2")
        XCTAssertEqual(pasteboard.string(forType: .init(UTType.commaSeparatedText.identifier)), "A,B\r\n1,2")
        XCTAssertNil(pasteboard.string(forType: .tabularText))
    }
}
