import Foundation
import DBDeepCore

struct ResultGridState {
    enum SortDirection {
        case ascending, descending
    }

    private var resultID: UUID?
    private(set) var columnOrder: [Int] = []
    private(set) var columnWidths: [Int: Double] = [:]
    private(set) var sortColumn: Int?
    private(set) var sortDirection = SortDirection.ascending

    mutating func reset(for result: QueryResult?) {
        resultID = result?.id
        columnOrder = result.map { Array($0.columns.indices) } ?? []
        columnWidths = [:]
        sortColumn = nil
        sortDirection = .ascending
    }

    func columns(in result: QueryResult) -> [Int] {
        resultID == result.id ? columnOrder : Array(result.columns.indices)
    }

    mutating func toggleSort(column: Int) {
        guard columnOrder.contains(column) else { return }
        sortDirection = sortColumn == column && sortDirection == .ascending ? .descending : .ascending
        sortColumn = column
    }

    mutating func resize(column: Int, width: Double) {
        guard columnOrder.contains(column), width.isFinite else { return }
        columnWidths[column] = min(1_200, max(64, width))
    }

    @discardableResult
    mutating func moveColumn(_ source: Int, to target: Int, after: Bool) -> Bool {
        guard source != target, let sourceIndex = columnOrder.firstIndex(of: source), columnOrder.contains(target) else { return false }
        columnOrder.remove(at: sourceIndex)
        let targetIndex = columnOrder.firstIndex(of: target)!
        columnOrder.insert(source, at: targetIndex + (after ? 1 : 0))
        return true
    }

    func rows(in result: QueryResult, filter: String) -> [(offset: Int, element: [String?])] {
        let rows = Array(result.rows.enumerated()).filter { row in
            filter.isEmpty || row.element.contains { $0?.localizedCaseInsensitiveContains(filter) == true }
        }
        guard resultID == result.id, let column = sortColumn, result.columns.indices.contains(column) else { return rows }
        func value(_ row: [String?]) -> String? { row.indices.contains(column) ? row[column] : nil }
        let values = result.rows.compactMap { value($0) }
        let numbers = values.compactMap(Self.number)
        let isNumeric = !values.isEmpty && numbers.count == values.count
        let numericValues = isNumeric ? Dictionary(zip(values, numbers), uniquingKeysWith: { first, _ in first }) : [:]
        return rows.sorted { lhs, rhs in
            let left = value(lhs.element), right = value(rhs.element)
            switch (left, right) {
            case (nil, nil): return lhs.offset < rhs.offset
            case (nil, _): return false
            case (_, nil): return true
            case let (left?, right?):
                let comparison: ComparisonResult
                if let leftNumber = numericValues[left], let rightNumber = numericValues[right] {
                    comparison = leftNumber == rightNumber ? .orderedSame : leftNumber < rightNumber ? .orderedAscending : .orderedDescending
                } else {
                    comparison = left.compare(right, options: [.caseInsensitive, .diacriticInsensitive, .numeric], locale: Locale(identifier: "en_US_POSIX"))
                }
                if comparison == .orderedSame { return lhs.offset < rhs.offset }
                return sortDirection == .ascending ? comparison == .orderedAscending : comparison == .orderedDescending
            }
        }
    }

    private static func number(_ value: String) -> Decimal? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.range(of: #"^[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?$"#, options: .regularExpression) != nil,
              let number = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")), !number.isNaN else { return nil }
        return number
    }
}
