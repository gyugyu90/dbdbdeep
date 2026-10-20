import Foundation

public struct SavedQueryFocus: Sendable {
    public let sql: String
    public let range: NSRange

    public enum Failure: LocalizedError, Sendable {
        case invalidBookmark, unfinishedConsole

        public var errorDescription: String? {
            switch self {
            case .invalidBookmark: return "Edit this bookmark to keep one SQL statement or PL/SQL block."
            case .unfinishedConsole: return "Finish the unfinished statement in the console before adding a saved query."
            }
        }
    }

    public static func resolve(bookmarkSQL: String, in sql: String, cursor: Int) throws -> SavedQueryFocus {
        guard let key = SQLStatementLocator.comparisonKey(for: bookmarkSQL) else { throw Failure.invalidBookmark }
        let matching = SQLStatementLocator.statements(in: sql).filter { SQLStatementLocator.comparisonKey(for: $0.text) == key }
        let current = SQLStatementLocator.statementAtOrBefore(in: sql, atUTF16Offset: cursor)
        if let existing = matching.first(where: { $0.range == current?.range }) ?? matching.first {
            return SavedQueryFocus(sql: sql, range: existing.range)
        }
        guard let insertion = SQLStatementLocator.appendingStatement(bookmarkSQL, to: sql) else { throw Failure.unfinishedConsole }
        return SavedQueryFocus(sql: insertion.sql, range: insertion.range)
    }
}
