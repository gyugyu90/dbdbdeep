import Foundation
import DBDeepCore

enum ResultSelectionFormat {
    case tsv, csv

    var separator: String { self == .tsv ? "\t" : "," }
    var lineEnding: String { self == .tsv ? "\n" : "\r\n" }

    func escape(_ value: String?) -> String {
        guard let value else { return "" }
        guard value.contains(separator) || value.contains("\n") || value.contains("\r") || value.contains("\"") else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

struct ResultGridSelection: Equatable {
    struct Cell: Equatable {
        let row: Int
        let column: Int
    }

    let anchor: Cell
    let extent: Cell
    var rowRange: ClosedRange<Int> { min(anchor.row, extent.row)...max(anchor.row, extent.row) }
    var columnRange: ClosedRange<Int> { min(anchor.column, extent.column)...max(anchor.column, extent.column) }

    func contains(_ cell: Cell) -> Bool { rowRange.contains(cell.row) && columnRange.contains(cell.column) }

    func text(in result: QueryResult, rowOrder: [Int], columnOrder: [Int], format: ResultSelectionFormat) -> String? {
        guard rowRange.lowerBound >= 0, columnRange.lowerBound >= 0,
              rowRange.upperBound < rowOrder.count, columnRange.upperBound < columnOrder.count else { return nil }
        let rows = rowRange.map { rowOrder[$0] }
        let columns = columnRange.map { columnOrder[$0] }
        guard rows.allSatisfy({ result.rows.indices.contains($0) }),
              columns.allSatisfy({ result.columns.indices.contains($0) }) else { return nil }
        return rows.map { row in
            columns.map { column in
                format.escape(result.rows[row].indices.contains(column) ? result.rows[row][column] : nil)
            }.joined(separator: format.separator)
        }.joined(separator: format.lineEnding)
    }
}

struct ResultGridLayout {
    static let rowHeight: CGFloat = 36
    static let headerHeight: CGFloat = 34
    static let rowNumberWidth: CGFloat = 38

    let columnWidths: [CGFloat]
    let rowCount: Int

    func cell(at point: CGPoint) -> ResultGridSelection.Cell? {
        guard rowCount > 0, !columnWidths.isEmpty, point.x.isFinite, point.y.isFinite else { return nil }
        let position = floor((point.y - Self.headerHeight) / Self.rowHeight)
        let row = Int(min(CGFloat(rowCount - 1), max(0, position)))
        var trailing = Self.rowNumberWidth
        for (index, width) in columnWidths.enumerated() {
            trailing += width
            if point.x < trailing { return .init(row: row, column: index) }
        }
        return .init(row: row, column: columnWidths.count - 1)
    }
}
