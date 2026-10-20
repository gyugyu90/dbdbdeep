import XCTest
import DBDeepCore
@testable import DBDeepApp

final class ResultGridStateTests: XCTestCase {
    func testOnlyOneColumnSortsAndClickingAgainReversesIt() {
        let result = QueryResult(columns: ["name", "score"], rows: [["Zoe", "2"], ["Amy", "10"], ["Ben", "-1"]])
        var grid = ResultGridState()
        grid.reset(for: result)
        grid.toggleSort(column: 0)
        XCTAssertEqual(grid.rows(in: result, filter: "").map(\.offset), [1, 2, 0])
        grid.toggleSort(column: 0)
        XCTAssertEqual(grid.sortDirection, .descending)
        XCTAssertEqual(grid.rows(in: result, filter: "").map(\.offset), [0, 2, 1])
        grid.toggleSort(column: 1)
        XCTAssertEqual(grid.sortColumn, 1)
        XCTAssertEqual(grid.sortDirection, .ascending)
        XCTAssertEqual(grid.rows(in: result, filter: "").map(\.offset), [2, 0, 1])
    }

    func testNumericSortHandlesNegativesFractionsExponentsAndLargeIntegers() {
        let result = QueryResult(columns: ["value"], rows: [["10"], ["2"], ["-12.5"], ["-2"], [".5"], ["1e2"], ["9007199254740993"], ["9007199254740992"]])
        var grid = ResultGridState()
        grid.reset(for: result)
        grid.toggleSort(column: 0)
        XCTAssertEqual(grid.rows(in: result, filter: "").map(\.offset), [2, 3, 4, 1, 0, 5, 7, 6])
        grid.toggleSort(column: 0)
        XCTAssertEqual(grid.rows(in: result, filter: "").map(\.offset), [6, 7, 5, 0, 1, 4, 3, 2])
    }

    func testNullsStayLastAndEqualValuesKeepTheirOriginalRowIdentity() {
        let result = QueryResult(columns: ["value"], rows: [[nil], ["2"], ["02"], [nil], ["1"]])
        var grid = ResultGridState()
        grid.reset(for: result)
        grid.toggleSort(column: 0)
        XCTAssertEqual(grid.rows(in: result, filter: "").map(\.offset), [4, 1, 2, 0, 3])
        grid.toggleSort(column: 0)
        XCTAssertEqual(grid.rows(in: result, filter: "").map(\.offset), [1, 2, 4, 0, 3])
    }

    func testTextSortUsesNaturalOrderAndStableCaseInsensitiveTies() {
        let result = QueryResult(columns: ["value"], rows: [["item10"], ["Item2"], ["item1"], ["ITEM2"], [""]])
        var grid = ResultGridState()
        grid.reset(for: result)
        grid.toggleSort(column: 0)
        XCTAssertEqual(grid.rows(in: result, filter: "").map(\.offset), [4, 2, 1, 3, 0])
    }

    func testFilteringPreservesSortingAndOriginalRowValues() {
        let result = QueryResult(columns: ["score", "name"], rows: [["10", "keep A"], ["2", "KEEP B"], ["-5", "other"]])
        var grid = ResultGridState()
        grid.reset(for: result)
        grid.toggleSort(column: 0)
        let rows = grid.rows(in: result, filter: "keep")
        XCTAssertEqual(rows.map(\.offset), [1, 0])
        XCTAssertEqual(rows.map(\.element), [["2", "KEEP B"], ["10", "keep A"]])
        XCTAssertTrue(grid.rows(in: result, filter: "absent").isEmpty)
    }

    func testMixedColumnComparisonDoesNotChangeWhenFiltering() {
        let result = QueryResult(columns: ["value"], rows: [["-2"], ["-10"], ["text"]])
        var grid = ResultGridState()
        grid.reset(for: result)
        grid.toggleSort(column: 0)
        let matching = grid.rows(in: result, filter: "").filter { $0.element[0]?.contains("-") == true }.map(\.offset)
        XCTAssertEqual(grid.rows(in: result, filter: "-").map(\.offset), matching)
    }

    func testMovingColumnsKeepsSortWidthsAndDuplicateNamesAttachedToOriginalIndices() {
        let result = QueryResult(columns: ["same", "same", "third"], rows: [["2", "A", "x"], ["1", "B", "y"]])
        var grid = ResultGridState()
        grid.reset(for: result)
        grid.resize(column: 0, width: 175)
        grid.toggleSort(column: 0)
        XCTAssertTrue(grid.moveColumn(0, to: 2, after: true))
        XCTAssertEqual(grid.columns(in: result), [1, 2, 0])
        XCTAssertEqual(grid.columnWidths[0], 175)
        XCTAssertEqual(grid.sortColumn, 0)
        let row = grid.rows(in: result, filter: "")[0]
        XCTAssertEqual(grid.columns(in: result).map { row.element[$0] }, ["B", "y", "1"])
        XCTAssertTrue(grid.moveColumn(0, to: 1, after: false))
        XCTAssertEqual(grid.columns(in: result), [0, 1, 2])
        XCTAssertFalse(grid.moveColumn(1, to: 1, after: true))
        XCTAssertFalse(grid.moveColumn(99, to: 0, after: false))
    }

    func testNewResultResetsOrderWidthsAndSortingEvenWithIdenticalColumnNames() {
        let result = QueryResult(columns: ["a", "b"], rows: [["2", "x"], ["1", "y"]])
        let next = QueryResult(columns: result.columns, rows: result.rows)
        var grid = ResultGridState()
        grid.reset(for: result)
        grid.toggleSort(column: 0)
        grid.resize(column: 0, width: 250)
        grid.moveColumn(0, to: 1, after: true)
        XCTAssertEqual(grid.columns(in: next), [0, 1])
        XCTAssertEqual(grid.rows(in: next, filter: "").map(\.offset), [0, 1])
        grid.reset(for: next)
        XCTAssertEqual(grid.columns(in: next), [0, 1])
        XCTAssertNil(grid.sortColumn)
        XCTAssertTrue(grid.columnWidths.isEmpty)
        grid.reset(for: nil)
        XCTAssertTrue(grid.columnOrder.isEmpty)
    }

    func testWidthLimitsAndInvalidColumnOperations() {
        let result = QueryResult(columns: ["a"], rows: [])
        var grid = ResultGridState()
        grid.reset(for: result)
        grid.resize(column: 0, width: -100)
        XCTAssertEqual(grid.columnWidths[0], 64)
        grid.resize(column: 0, width: 2_000)
        XCTAssertEqual(grid.columnWidths[0], 1_200)
        grid.resize(column: 0, width: .infinity)
        XCTAssertEqual(grid.columnWidths[0], 1_200)
        grid.resize(column: 10, width: 250)
        grid.toggleSort(column: 10)
        XCTAssertNil(grid.columnWidths[10])
        XCTAssertNil(grid.sortColumn)
        XCTAssertTrue(grid.rows(in: result, filter: "").isEmpty)
    }

    func testMissingCellsSortLikeNullWithoutLosingRows() {
        let result = QueryResult(columns: ["a", "b"], rows: [["x"], ["y", "2"], ["z", "1"]])
        var grid = ResultGridState()
        grid.reset(for: result)
        grid.toggleSort(column: 1)
        XCTAssertEqual(grid.rows(in: result, filter: "").map(\.offset), [2, 1, 0])
    }
}
