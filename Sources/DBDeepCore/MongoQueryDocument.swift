import Foundation

public enum MongoQueryDocument {
    public static func statements(in text: String) -> [SQLStatement] {
        let scanner = MongoQueryScanner(text)
        let source = text as NSString
        var result: [SQLStatement] = []
        var index = 0
        while let start = scanner.skipTrivia(from: index), start < scanner.units.count {
            guard let end = scanner.statementEnd(from: start) else { break }
            let range = NSRange(location: start, length: end - start)
            let command = source.substring(with: range)
            if scanner.units[start] == 123 {
                guard let value = try? JSONSerialization.jsonObject(with: Data(command.utf8)) as? [String: Any], !value.isEmpty else { break }
            }
            result.append(SQLStatement(text: command, range: range))
            index = end
        }
        return result
    }

    public static func singleStatement(in text: String) -> SQLStatement? {
        let statements = statements(in: text)
        guard statements.count == 1, let statement = statements.first,
              ignorable((text as NSString).substring(from: NSMaxRange(statement.range))) else { return nil }
        return statement
    }

    static func ignorable(_ text: String) -> Bool {
        let scanner = MongoQueryScanner(text)
        return scanner.skipTrivia(from: 0) == scanner.units.count
    }

    static func comparisonKey(_ text: String) -> [String]? {
        guard let statement = singleStatement(in: text) else { return nil }
        return [MongoQueryScanner(statement.text).compact()]
    }
}

private struct MongoQueryScanner {
    let units: [UInt16]
    init(_ text: String) { units = Array(text.utf16) }

    private func at(_ index: Int) -> UInt16 { units.indices.contains(index) ? units[index] : 0 }
    private func whitespace(_ unit: UInt16) -> Bool { [9, 10, 13, 32].contains(unit) }

    func skipTrivia(from start: Int, semicolons: Bool = true) -> Int? {
        var index = start
        while index < units.count {
            if whitespace(at(index)) || (semicolons && at(index) == 59) { index += 1 }
            else if at(index) == 47 && at(index + 1) == 47 {
                while index < units.count && ![10, 13].contains(at(index)) { index += 1 }
            } else if at(index) == 47 && at(index + 1) == 42 {
                index += 2
                while index < units.count && !(at(index) == 42 && at(index + 1) == 47) { index += 1 }
                guard index < units.count else { return nil }
                index += 2
            } else { break }
        }
        return index
    }

    private func literalEnd(from start: Int) -> Int? {
        let quote = at(start)
        var index = start + 1
        var escaped = false
        var bracket = false
        while index < units.count {
            let unit = at(index)
            index += 1
            if escaped { escaped = false; continue }
            if unit == 92 { escaped = true; continue }
            if quote == 47 && unit == 91 { bracket = true }
            else if quote == 47 && unit == 93 { bracket = false }
            else if unit == quote && !bracket { return index }
        }
        return nil
    }

    private func regex(_ unit: UInt16, after previous: UInt16) -> Bool { unit == 47 && [58, 44, 40, 91, 123].contains(previous) }
    private func shellStart(_ index: Int) -> Bool { at(index) == 100 && at(index + 1) == 98 && ([46, 91, 32, 9, 10, 13, 47].contains(at(index + 2))) }

    func statementEnd(from start: Int) -> Int? {
        let json = at(start) == 123
        guard json || shellStart(start) else { return nil }
        var stack: [UInt16] = []
        var index = start
        var previous: UInt16 = 0
        while index < units.count {
            guard let next = skipTrivia(from: index, semicolons: false) else { return nil }
            index = next
            guard index < units.count else { return nil }
            let unit = at(index)
            if unit == 34 || unit == 39 || regex(unit, after: previous) {
                guard let end = literalEnd(from: index) else { return nil }
                index = end
                previous = unit
                continue
            }
            if unit == 40 { stack.append(41) }
            else if unit == 123 { stack.append(125) }
            else if unit == 91 { stack.append(93) }
            else if [41, 125, 93].contains(unit) {
                guard stack.popLast() == unit else { return nil }
                if stack.isEmpty && (json || unit == 41) {
                    if json { return index + 1 }
                    guard let following = skipTrivia(from: index + 1, semicolons: false) else { return nil }
                    if following == units.count || at(following) == 59 { return index + 1 }
                    if following > index + 1 && (shellStart(following) || at(following) == 123) { return index + 1 }
                    guard at(following) == 46 else { return nil }
                }
            }
            previous = unit
            index += 1
        }
        return nil
    }

    func compact() -> String {
        var result: [UInt16] = []
        var index = 0
        var previous: UInt16 = 0
        while index < units.count {
            guard let next = skipTrivia(from: index, semicolons: false) else { break }
            index = next
            guard index < units.count else { break }
            let unit = at(index)
            if unit == 34 || unit == 39 || regex(unit, after: previous), let end = literalEnd(from: index) {
                result.append(contentsOf: units[index..<end]); index = end
            } else { result.append(unit); index += 1 }
            previous = unit
        }
        return String(decoding: result, as: UTF16.self)
    }
}

public struct QueryLanguage {
    private let mongo: Bool
    public init(_ kind: DBConnection.Kind?) { mongo = kind == .mongodb }

    public func statements(in text: String) -> [SQLStatement] {
        mongo ? MongoQueryDocument.statements(in: text) : SQLStatementLocator.statements(in: text)
    }

    public func singleStatement(in text: String) -> SQLStatement? {
        mongo ? MongoQueryDocument.singleStatement(in: text) : SQLStatementLocator.singleStatement(in: text)
    }

    public func comparisonKey(for text: String) -> [String]? {
        mongo ? MongoQueryDocument.comparisonKey(text) : SQLStatementLocator.comparisonKey(for: text)
    }

    public func statementAtOrBefore(in text: String, atUTF16Offset offset: Int, using parsed: [SQLStatement]? = nil) -> SQLStatement? {
        guard mongo else { return SQLStatementLocator.statementAtOrBefore(in: text, atUTF16Offset: offset, using: parsed) }
        let offset = min(max(0, offset), text.utf16.count)
        guard let statement = (parsed ?? statements(in: text)).last(where: { $0.range.location <= offset }) else { return nil }
        if offset < NSMaxRange(statement.range) { return statement }
        return MongoQueryDocument.ignorable((text as NSString).substring(with: NSRange(location: NSMaxRange(statement.range), length: offset - NSMaxRange(statement.range)))) ? statement : nil
    }

    public func appendingStatement(_ statement: String, to text: String) -> (sql: String, range: NSRange)? {
        guard mongo else { return SQLStatementLocator.appendingStatement(statement, to: text) }
        guard let incoming = singleStatement(in: statement) else { return nil }
        let existing = statements(in: text)
        let end = existing.last.map { NSMaxRange($0.range) } ?? 0
        guard MongoQueryDocument.ignorable((text as NSString).substring(from: end)) else { return nil }
        let prefix = text.isEmpty ? "" : text + "\n\n"
        return (prefix + incoming.text, NSRange(location: prefix.utf16.count, length: incoming.text.utf16.count))
    }

    public static func browseCollection(_ name: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [name])
        let quoted = String(decoding: data, as: UTF8.self).dropFirst().dropLast()
        return "db.getCollection(\(quoted)).find({}).limit(100)"
    }
}
