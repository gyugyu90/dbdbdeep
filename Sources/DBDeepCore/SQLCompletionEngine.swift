import Foundation

public struct SQLCompletion: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable { case table, view, column, collection, method, keyword }
    public let name: String
    public let insertion: String
    public let detail: String
    public let kind: Kind
    public var id: String { kind.rawValue + ":" + insertion + ":" + detail }
}

public struct SQLCompletionResult: Equatable, Sendable {
    public let range: NSRange
    public let candidates: [SQLCompletion]
}

public struct SQLCompletionEngine: Sendable {
    private let tables: [SchemaTable]
    private let kind: DBConnection.Kind

    public init(tables: [SchemaTable], kind: DBConnection.Kind = .oracle) {
        self.tables = tables
        self.kind = kind
    }

    public func completions(in sql: String, atUTF16Offset offset: Int, explicit: Bool = false) -> SQLCompletionResult? {
        if kind == .mongodb { return MongoCompletionEngine(tables: tables).completions(in: sql, atUTF16Offset: offset, explicit: explicit) }
        let source = sql as NSString
        guard offset >= 0, offset <= source.length, !tables.isEmpty else { return nil }
        let lexed = SQLLexer(sql)
        guard !lexed.protected.contains(where: { $0.contains(offset) }) else { return nil }
        let current = lexed.tokens.first { $0.identifier && $0.range.location < offset && offset <= NSMaxRange($0.range) }
        let range = current?.range ?? NSRange(location: offset, length: 0)
        let rawPrefix = source.substring(with: NSRange(location: range.location, length: offset - range.location))
        let quoted = rawPrefix.hasPrefix("\"")
        let prefix = quoted ? String(rawPrefix.dropFirst()).replacingOccurrences(of: "\"\"", with: "\"") : rawPrefix

        let start = lexed.tokens.last { $0.value == ";" && NSMaxRange($0.range) <= range.location }.map { NSMaxRange($0.range) } ?? 0
        let end = lexed.tokens.first { $0.value == ";" && $0.range.location >= offset }?.range.location ?? source.length
        let statement = lexed.tokens.filter { $0.range.location >= start && $0.range.location < end }
        var scope = current?.scope ?? lexed.tokens.last(where: { NSMaxRange($0.range) <= offset })?.followingScope ?? 0
        while scope != 0 && !statement.contains(where: { $0.scope == scope && Self.queryHeads.contains($0.keyword) }) {
            scope = lexed.parents[scope] ?? 0
        }
        var tokens = statement.filter { $0.scope == scope }
        let segmentStart = tokens.last { $0.keyword == "UNION" && $0.range.location < offset }?.range.location ?? start
        let segmentEnd = tokens.first { $0.keyword == "UNION" && $0.range.location >= offset }?.range.location ?? end
        tokens = tokens.filter { $0.range.location >= segmentStart && $0.range.location < segmentEnd }
        let before = tokens.filter { NSMaxRange($0.range) <= range.location }
        let clauseIndex = before.lastIndex { Self.clauses.contains($0.keyword) }
        guard let clauseIndex else { return nil }
        let clause = before[clauseIndex].keyword
        let tail = Array(before.dropFirst(clauseIndex + 1))
        let tableClause = ["FROM", "JOIN", "UPDATE", "INTO"].contains(clause)
        let tableTail = clause == "FROM" ? Array(tail.suffix(from: (tail.lastIndex(where: { $0.value == "," }).map { $0 + 1 }) ?? 0)) : tail
        let tablePosition = tableClause && (tableTail.isEmpty || (tableTail.last?.value == "." && tableTail.allSatisfy { $0.identifier || $0.value == "." }))
        if !tablePosition && !explicit && !quoted && Self.keywords.contains(prefix.uppercased()) { return nil }
        if !tablePosition && tableClause && !(clause == "INTO" && tail.contains(where: { $0.value == "(" })) { return nil }
        if before.last?.keyword == "AS" { return nil }
        if prefix.isEmpty && !explicit && !(before.last?.value == "." || before.last.map { Self.clauses.contains($0.keyword) || $0.keyword == "BY" || $0.value == "," || $0.value == "(" } == true) { return nil }

        let references = tableReferences(tokens)
        let lexicalBefore = statement.filter { NSMaxRange($0.range) <= range.location }
        let qualifier = lexicalBefore.last?.value == "." ? lexicalBefore.dropLast().last?.value : nil
        var candidates: [SQLCompletion] = []
        if tablePosition {
            candidates = tables.map { table in
                SQLCompletion(name: table.name, insertion: identifier(table.name, forceQuote: quoted), detail: table.isView ? "View" : "Table", kind: table.isView ? .view : .table)
            }
        } else {
            let sources: [Reference]
            if let qualifier {
                let matching = references.filter { $0.qualifier.caseInsensitiveCompare(qualifier) == .orderedSame }
                if !matching.isEmpty { sources = matching }
                else if let table = tables.first(where: { $0.name.caseInsensitiveCompare(qualifier) == .orderedSame }) {
                    sources = [Reference(table: table, qualifier: qualifier, qualifierInsertion: identifier(qualifier))]
                } else { return nil }
            } else {
                sources = references.isEmpty ? tables.map { Reference(table: $0, qualifier: $0.name, qualifierInsertion: identifier($0.name)) } : references
            }
            var counts: [String: Int] = [:]
            for reference in sources {
                for column in reference.table.columns { counts[column.name.uppercased(), default: 0] += 1 }
            }
            for reference in sources {
                for column in reference.table.columns {
                    let name = identifier(column.name, forceQuote: quoted)
                    let ambiguous = qualifier == nil && !references.isEmpty && counts[column.name.uppercased(), default: 0] > 1 && !quoted
                    candidates.append(SQLCompletion(name: column.name, insertion: ambiguous ? reference.qualifierInsertion + "." + name : name,
                        detail: reference.qualifier + " · " + column.type, kind: .column))
                }
            }
        }
        return Self.ranked(candidates, matching: prefix, range: range)
    }

    static func ranked(_ candidates: [SQLCompletion], matching prefix: String, range: NSRange) -> SQLCompletionResult? {
        let ranked = candidates.compactMap { candidate -> (SQLCompletion, Int)? in
            guard let score = Self.score(candidate.name, matching: prefix) else { return nil }
            return (candidate, score)
        }.sorted {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            if $0.0.name != $1.0.name { return $0.0.name.localizedStandardCompare($1.0.name) == .orderedAscending }
            return $0.0.detail < $1.0.detail
        }
        var seen: Set<String> = []
        let results = ranked.map(\.0).filter { seen.insert($0.id).inserted }.prefix(80)
        return results.isEmpty ? nil : SQLCompletionResult(range: range, candidates: Array(results))
    }

    private struct Reference {
        let table: SchemaTable
        let qualifier: String
        let qualifierInsertion: String
    }

    private func tableReferences(_ tokens: [SQLToken]) -> [Reference] {
        var references: [Reference] = []
        var index = 0
        var inFrom = false
        var expectsTable = false
        while index < tokens.count {
            let token = tokens[index]
            if ["FROM", "JOIN", "UPDATE", "INTO"].contains(token.keyword) {
                inFrom = token.keyword == "FROM" || token.keyword == "JOIN"
                expectsTable = true
                index += 1
                continue
            }
            if Self.clauses.contains(token.keyword) { inFrom = false; expectsTable = false }
            if token.value == "," && inFrom { expectsTable = true; index += 1; continue }
            if expectsTable {
                expectsTable = false
                if token.identifier && !Self.keywords.contains(token.keyword) {
                    var name = token.value
                    var last = token
                    while index + 2 < tokens.count && tokens[index + 1].value == "." && tokens[index + 2].identifier {
                        index += 2; last = tokens[index]; name = last.value
                    }
                    if let table = tables.first(where: { last.quoted ? $0.name == name : $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                        var alias = last
                        if index + 1 < tokens.count && tokens[index + 1].keyword == "AS" { index += 1 }
                        if index + 1 < tokens.count && tokens[index + 1].identifier && !Self.keywords.contains(tokens[index + 1].keyword) {
                            index += 1; alias = tokens[index]
                        }
                        references.append(Reference(table: table, qualifier: alias.value, qualifierInsertion: alias.quoted ? SQLIdentifier.quote(alias.value) : alias.value))
                    }
                }
            }
            index += 1
        }
        return references
    }

    private func identifier(_ name: String, forceQuote: Bool = false) -> String {
        let normal = name.range(of: "^[A-Za-z_][A-Za-z0-9_$#]*$", options: .regularExpression) != nil
        let caseNeedsQuotes = kind == .oracle && name != name.uppercased()
        return forceQuote || !normal || caseNeedsQuotes || Self.keywords.contains(name.uppercased()) ? SQLIdentifier.quote(name) : name
    }

    private static func score(_ name: String, matching prefix: String) -> Int? {
        let name = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        let prefix = prefix.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        if prefix.isEmpty { return 0 }
        if name == prefix { return 5000 }
        if name.hasPrefix(prefix) { return 4000 - min(100, name.count - prefix.count) }
        if let range = name.range(of: prefix) {
            let distance = name.distance(from: name.startIndex, to: range.lowerBound)
            let boundary = range.lowerBound == name.startIndex || name[name.index(before: range.lowerBound)] == "_"
            return (boundary ? 3200 : 2800) - min(100, distance)
        }
        var remaining = prefix.makeIterator()
        var next = remaining.next()
        var first = 0
        var last = 0
        var matched = 0
        for (index, character) in name.enumerated() where character == next {
            if matched == 0 { first = index }
            matched += 1
            last = index
            next = remaining.next()
            if next == nil { return 2000 - min(200, last - first + name.count) }
        }
        guard prefix.count >= 3 else { return nil }
        let candidate = Array(name.prefix(prefix.count))
        let query = Array(prefix)
        var distances = Array(0...candidate.count)
        var previousDistances = distances
        for (row, character) in query.enumerated() {
            var nextDistances = [row + 1]
            for (column, other) in candidate.enumerated() {
                var distance = min(nextDistances[column] + 1, distances[column + 1] + 1, distances[column] + (character == other ? 0 : 1))
                if row > 0 && column > 0 && character == candidate[column - 1] && query[row - 1] == other {
                    distance = min(distance, previousDistances[column - 1] + 1)
                }
                nextDistances.append(distance)
            }
            previousDistances = distances
            distances = nextDistances
        }
        let distance = distances[candidate.count]
        return distance <= (prefix.count >= 6 ? 2 : 1) ? 1000 - distance * 100 - min(100, name.count) : nil
    }

    private static let queryHeads: Set<String> = ["SELECT", "UPDATE", "INSERT", "DELETE"]
    private static let clauses: Set<String> = ["SELECT", "FROM", "JOIN", "WHERE", "ON", "HAVING", "SET", "VALUES", "RETURNING", "GROUP", "ORDER", "UPDATE", "INTO"]
    private static let keywords: Set<String> = clauses.union(["AS", "BY", "AND", "OR", "NOT", "NULL", "IS", "IN", "LIKE", "BETWEEN", "EXISTS", "DISTINCT", "ALL", "UNION", "INTERSECT", "MINUS", "EXCEPT", "LEFT", "RIGHT", "FULL", "INNER", "OUTER", "CROSS", "NATURAL", "USING", "INSERT", "DELETE", "WITH", "FETCH", "FIRST", "NEXT", "ROWS", "ONLY", "LIMIT", "OFFSET", "ASC", "DESC", "CASE", "WHEN", "THEN", "ELSE", "END", "BEGIN", "COMMIT", "ROLLBACK"])

}
