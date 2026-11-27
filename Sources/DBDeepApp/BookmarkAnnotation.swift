import Foundation
import DBDeepCore

enum BookmarkAnnotation {
    static func header(for bookmark: QueryBookmark) -> String {
        func safe(_ value: String) -> String {
            value.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
                .replacingOccurrences(of: "/*", with: "/ *").replacingOccurrences(of: "*/", with: "* /")
        }
        return "/* \(safe(bookmark.emoji)) \(safe(bookmark.name)) */"
    }

    static func apply(to sql: String, bookmark: QueryBookmark, previous: QueryBookmark?) -> String {
        var body = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        let headers = [header(for: bookmark)] + (previous.map { [header(for: $0)] } ?? [])
        while let existing = headers.first(where: { body.hasPrefix($0) }) {
            body = String(body.dropFirst(existing.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return header(for: bookmark) + "\n" + body
    }
}
