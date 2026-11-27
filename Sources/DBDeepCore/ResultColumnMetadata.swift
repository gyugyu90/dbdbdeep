import Foundation

public struct ResultColumnMetadata: Codable, Equatable, Sendable {
    public var type: String?
    public var comment: String?

    public init(type: String? = nil, comment: String? = nil) {
        self.type = type
        self.comment = comment
    }
}

extension QueryResult {
    public func columnTooltip(at index: Int) -> String {
        guard columns.indices.contains(index) else { return "" }
        let metadata = columnMetadata.flatMap { $0.indices.contains(index) ? $0[index] : nil }
        let type = metadata?.type?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let comment = metadata?.comment?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return columns[index] + (type.isEmpty ? "" : " " + type) + (comment.isEmpty ? "" : "\n" + comment)
    }

    public func withColumnMetadata(sql: String, tables: [SchemaTable], kind: DBConnection.Kind, defaultSchema: String = "") -> QueryResult {
        guard kind != .mongodb else { return self }
        let resolved = SQLResultColumns(sql: sql, tables: tables, kind: kind, defaultSchema: defaultSchema).columns(matching: columns)
        var result = self
        result.columnMetadata = columns.indices.map { index in
            var metadata = columnMetadata.flatMap { $0.indices.contains(index) ? $0[index] : nil } ?? ResultColumnMetadata()
            if let column = resolved?[index] {
                if metadata.type?.isEmpty != false { metadata.type = column.type }
                metadata.comment = column.comment
            }
            return metadata
        }
        return result
    }
}

private struct SQLResultColumns {
    let sql: String
    let tables: [SchemaTable]
    let kind: DBConnection.Kind
    let defaultSchema: String

    private struct Source {
        let qualifier: SQLToken
        let table: SchemaTable?
    }

    private func matches(_ token: SQLToken, _ name: String) -> Bool {
        token.quoted ? token.value == name : kind == .oracle ? token.value.uppercased() == name : token.value.caseInsensitiveCompare(name) == .orderedSame
    }

    private func matchesQualifier(_ token: SQLToken, _ qualifier: SQLToken) -> Bool {
        matches(token, kind == .oracle && !qualifier.quoted ? qualifier.value.uppercased() : qualifier.value)
    }

    private static let boundaries: Set<String> = ["WHERE", "GROUP", "HAVING", "ORDER", "FETCH", "OFFSET", "LIMIT", "CONNECT", "START", "FOR", "MODEL"]
    private static let joins: Set<String> = ["JOIN", "INNER", "OUTER", "LEFT", "RIGHT", "FULL", "CROSS", "NATURAL", "ON", "USING"]

    func columns(matching labels: [String]) -> [SchemaColumn?]? {
        guard let statement = SQLStatementLocator.singleStatement(in: sql) else { return nil }
        let lexer = SQLLexer(statement.text)
        let tokens = lexer.tokens.filter { $0.scope == 0 && $0.value != ";" }
        guard tokens.first?.keyword == "SELECT", let from = tokens.firstIndex(where: { $0.keyword == "FROM" }),
              !tokens.contains(where: { ["UNION", "INTERSECT", "MINUS", "EXCEPT"].contains($0.keyword) }) else { return nil }
        let end = tokens[(from + 1)...].firstIndex { Self.boundaries.contains($0.keyword) } ?? tokens.count
        guard let sources = sources(in: Array(tokens[(from + 1)..<end])), !sources.isEmpty else { return nil }
        let start = ["DISTINCT", "ALL", "UNIQUE"].contains(tokens[1].keyword) ? 2 : 1
        var groups: [[SQLToken]] = [[]]
        for token in tokens[start..<from] {
            if token.value == "," { groups.append([]) }
            else { groups[groups.count - 1].append(token) }
        }
        var columns: [SchemaColumn?] = []
        var wildcardIndices: [Int] = []
        let separators = tokens[start..<from].filter { $0.value == "," }
        var boundary = tokens[start - 1].range.location + tokens[start - 1].range.length
        for (position, group) in groups.enumerated() {
            let nextBoundary = position == groups.count - 1 ? tokens[from].range.location : separators[position].range.location
            let hasLiteral = lexer.protected.contains { $0.isLiteral && $0.range.location >= boundary && $0.range.location < nextBoundary }
            boundary = nextBoundary + 1
            if hasLiteral { columns.append(nil); continue }
            var expression = group
            if expression.count >= 3, expression[expression.count - 2].keyword == "AS" { expression.removeLast(2) }
            else if expression.count >= 2, expression.last?.identifier == true, expression[expression.count - 2].value != "." { expression.removeLast() }
            if expression.count == 1, expression[0].value == "*" {
                guard sources.allSatisfy({ $0.table != nil }) else { return nil }
                let expanded = sources.flatMap { $0.table!.columns }
                wildcardIndices += Array(columns.count..<(columns.count + expanded.count))
                columns += expanded.map(Optional.some)
            } else if expression.count == 3, expression[1].value == ".", expression[2].value == "*" {
                let matching = sources.filter { matchesQualifier(expression[0], $0.qualifier) }
                guard matching.count == 1, let table = matching[0].table else { return nil }
                wildcardIndices += Array(columns.count..<(columns.count + table.columns.count))
                columns += table.columns.map(Optional.some)
            } else {
                let candidates: [Source]
                let name: SQLToken
                if expression.count == 1, expression[0].identifier {
                    candidates = sources
                    name = expression[0]
                } else if expression.count == 3, expression[0].identifier, expression[1].value == ".", expression[2].identifier {
                    candidates = sources.filter { matchesQualifier(expression[0], $0.qualifier) }
                    name = expression[2]
                } else { columns.append(nil); continue }
                let matchingColumns = candidates.flatMap { $0.table?.columns.filter { matches(name, $0.name) } ?? [] }
                columns.append(candidates.contains(where: { $0.table == nil }) || matchingColumns.count != 1 ? nil : matchingColumns[0])
            }
        }
        guard columns.count == labels.count, wildcardIndices.allSatisfy({ columns[$0]?.name == labels[$0] }) else { return nil }
        return columns
    }

    private func sources(in tokens: [SQLToken]) -> [Source]? {
        var result: [Source] = []
        var index = 0
        var expectsTable = true
        while index < tokens.count {
            let token = tokens[index]
            if token.keyword == "JOIN" || token.value == "," { expectsTable = true; index += 1; continue }
            guard expectsTable else { index += 1; continue }
            guard token.identifier else { return nil }
            expectsTable = false
            var path = [token]
            index += 1
            while index + 1 < tokens.count, tokens[index].value == ".", tokens[index + 1].identifier {
                path.append(tokens[index + 1]); index += 2
            }
            guard index == tokens.count || !["@", "("].contains(tokens[index].value), path.count <= 2 else { return nil }
            let name = path.last!
            let allowedSchema = path.count == 1 || (kind == .oracle ? matches(path[0], defaultSchema.uppercased()) : matches(path[0], "main"))
            let table = allowedSchema ? tables.first { matches(name, $0.name) } : nil
            if index < tokens.count, tokens[index].keyword == "AS" { index += 1 }
            var qualifier = name
            if index < tokens.count, tokens[index].identifier, !Self.joins.contains(tokens[index].keyword) {
                qualifier = tokens[index]; index += 1
            }
            result.append(Source(qualifier: qualifier, table: table))
        }
        return result
    }
}
