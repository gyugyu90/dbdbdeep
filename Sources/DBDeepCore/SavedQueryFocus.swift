import Foundation

public struct SavedQueryFocus: Sendable {
    public let sql: String
    public let range: NSRange

    public enum Failure: LocalizedError, Sendable {
        case invalidBookmark, unfinishedConsole

        public var errorDescription: String? {
            switch self {
            case .invalidBookmark: return "Keep one complete SQL statement, PL/SQL block, or MongoDB query per bookmark."
            case .unfinishedConsole: return "Finish the unfinished statement in the console before adding a saved query."
            }
        }
    }

    public static func resolve(bookmarkSQL: String, in sql: String, cursor: Int, kind: DBConnection.Kind? = .oracle) throws -> SavedQueryFocus {
        let language = QueryLanguage(kind)
        guard let key = language.comparisonKey(for: bookmarkSQL) else { throw Failure.invalidBookmark }
        let matching = language.statements(in: sql).filter { language.comparisonKey(for: $0.text) == key }
        let current = language.statementAtOrBefore(in: sql, atUTF16Offset: cursor)
        if let existing = matching.first(where: { $0.range == current?.range }) ?? matching.first {
            return SavedQueryFocus(sql: sql, range: existing.range)
        }
        guard let insertion = language.appendingStatement(bookmarkSQL, to: sql) else { throw Failure.unfinishedConsole }
        return SavedQueryFocus(sql: insertion.sql, range: insertion.range)
    }
}
