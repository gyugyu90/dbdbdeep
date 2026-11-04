import Foundation

public struct MongoCompletionEngine: Sendable {
    private let tables: [SchemaTable]

    public init(tables: [SchemaTable]) { self.tables = tables }

    public func fieldCollection(in text: String, atUTF16Offset offset: Int) -> String? {
        guard let context = context(in: text, offset: offset), case .field(let collection, _) = context.position else { return nil }
        return collection
    }

    public func completions(in text: String, atUTF16Offset offset: Int, explicit: Bool = false) -> SQLCompletionResult? {
        guard let context = context(in: text, offset: offset) else { return nil }
        guard explicit || !context.prefix.isEmpty || context.position.isMember else { return nil }
        let candidates: [SQLCompletion]
        switch context.position {
        case .collection(let member):
            candidates = tables.map { table in
                let insertion = member ? (Self.member(table.name) ? table.name : "getCollection(\(Self.quote(table.name)))") : context.quoted(table.name)
                return SQLCompletion(name: table.name, insertion: insertion, detail: "Collection", kind: .collection)
            }
        case .method(let names):
            candidates = names.map { SQLCompletion(name: $0, insertion: $0, detail: "MongoDB helper", kind: .method) }
        case .field(let collection, let parent):
            if context.prefix.hasPrefix("$") {
                candidates = Self.operators.map { SQLCompletion(name: $0, insertion: context.quoted($0), detail: "Query operator", kind: .keyword) }
            } else {
                candidates = (tables.first { $0.name == collection }?.columns ?? []).compactMap { column in
                    guard parent.isEmpty || column.name.hasPrefix(parent + ".") else { return nil }
                    let name = parent.isEmpty ? column.name : String(column.name.dropFirst(parent.count + 1))
                    return SQLCompletion(name: name, insertion: context.quote == nil && Self.member(name) && !name.contains(".") ? name : context.quoted(name), detail: collection + " · " + column.type, kind: .column)
                }
            }
        }
        return SQLCompletionEngine.ranked(candidates, matching: context.prefix, range: context.range)
    }

    private enum Position {
        case collection(member: Bool), method([String]), field(collection: String, parent: String)
        var isMember: Bool {
            switch self { case .collection(member: true), .method: return true; default: return false }
        }
    }

    private struct Context {
        var range: NSRange
        var prefix: String
        var quote: String?
        var position: Position

        func quoted(_ value: String) -> String { MongoCompletionEngine.quote(value, delimiter: quote ?? "\"") }
    }

    private func context(in text: String, offset: Int) -> Context? {
        let source = text as NSString
        guard offset >= 0, offset <= source.length else { return nil }
        let lexed = Lexer(text)
        guard !lexed.tokens.contains(where: { $0.protected && offset > $0.range.location && (offset < NSMaxRange($0.range) || (!$0.closed && offset == NSMaxRange($0.range))) }) else { return nil }
        let current = lexed.tokens.first { $0.word && $0.range.location < offset && offset <= NSMaxRange($0.range) }
        let range = current?.range ?? NSRange(location: offset, length: 0)
        let raw = source.substring(with: NSRange(location: range.location, length: offset - range.location))
        let quote = current?.quote
        if let quote, current?.closed == true, raw.hasSuffix(quote), offset == NSMaxRange(range) { return nil }
        let prefix = Self.unescape(quote == nil ? raw : String(raw.dropFirst()))
        let tokens = lexed.tokens.filter { !$0.protected }
        let before = tokens.filter { NSMaxRange($0.range) <= range.location }
        let statementStart = before.lastIndex { $0.depth == 0 && ($0.value == ";" || $0.value == "db" || $0.value == "{") } ?? 0
        let remaining = Array(tokens.dropFirst(statementStart))
        let end = remaining.dropFirst().firstIndex { $0.depth == 0 && [";", "db", "{"].contains($0.value) && $0.quote == nil } ?? remaining.endIndex
        let statement = Array(remaining[..<end])
        let preceding = statement.filter { NSMaxRange($0.range) <= range.location }
        var result = Context(range: range, prefix: prefix, quote: quote, position: .collection(member: false))

        if statement.first?.value == "db" && !(statement.count > 2 && statement[2].value == "runCommand") {
            if preceding.count >= 4, preceding[1].value == ".", preceding[2].value == "getCollection", preceding[3].value == "(", preceding.count == 4, quote != nil { return result }
            if preceding.count == 2, preceding[1].value == "[", quote != nil { return result }
            let head = shellCollection(statement)
            if let head, range.location >= head.end {
                let tail = preceding.filter { $0.range.location >= head.end }
                if tail.last?.value == ".", quote == nil {
                    let terminal = tail.indices.contains { index in
                        index + 1 < tail.count && tail[index].quote == nil && ["findOne", "toArray"].contains(tail[index].value) && tail[index + 1].value == "("
                    }
                    let methods = tail.contains { $0.value == "(" && $0.quote == nil } ? (terminal ? [] : Self.cursorMethods) : ["find", "findOne"]
                    result.position = .method(methods)
                    return result
                }
                if let parent = fieldParent(preceding, after: head.end) {
                    result.position = .field(collection: head.name, parent: parent)
                    return result
                }
            }
            if preceding.count >= 2, preceding[1].value == ".", quote == nil,
               preceding.dropFirst(2).allSatisfy({ $0.word || $0.value == "." }) {
                let start = statement.count > 2 ? statement[2].range.location : range.location
                result.range = NSRange(location: start, length: NSMaxRange(range) - start)
                result.prefix = source.substring(with: NSRange(location: start, length: offset - start))
                result.position = .collection(member: true)
                if !result.prefix.contains(".") {
                    return result
                }
                return tables.contains { $0.name.hasPrefix(result.prefix) } ? result : nil
            }
            return nil
        }

        guard let root = statement.first, root.value == "{" || statement.starts(with: ["db", ".", "runCommand"], by: { $0.value == $1 }) else { return nil }
        let commandDepth = (statement.first { $0.value == "{" && $0.quote == nil }?.depth ?? 0) + 1
        if preceding.count >= 2, preceding.last?.value == ":", let key = preceding.dropLast().last,
           key.depth == commandDepth, Self.collectionKeys.contains(key.value), quote != nil {
            result.position = .collection(member: false)
            return result
        }
        var collection: String?
        for index in statement.indices where index + 2 < statement.count {
            if statement[index].depth == commandDepth, Self.collectionKeys.contains(statement[index].value), statement[index + 1].value == ":", statement[index + 2].quote != nil {
                collection = statement[index + 2].value
                break
            }
        }
        guard let collection, let parent = fieldParent(preceding, after: root.range.location, command: true) else { return nil }
        result.position = .field(collection: collection, parent: parent)
        return result
    }

    private func shellCollection(_ tokens: [Token]) -> (name: String, end: Int)? {
        if tokens.count > 5, tokens[1].value == ".", tokens[2].value == "getCollection", tokens[3].value == "(", tokens[4].quote != nil, tokens[5].value == ")" {
            return (tokens[4].value, NSMaxRange(tokens[5].range))
        }
        if tokens.count > 3, tokens[1].value == "[", tokens[2].quote != nil, tokens[3].value == "]" {
            return (tokens[2].value, NSMaxRange(tokens[3].range))
        }
        guard tokens.count > 3, tokens[1].value == "." else { return nil }
        for table in tables.sorted(by: { $0.name.count > $1.name.count }) {
            let parts = table.name.components(separatedBy: ".")
            let count = parts.count * 2
            guard tokens.count > count + 1, tokens[count + 1].value == "." else { continue }
            if parts.enumerated().allSatisfy({ tokens[2 + $0.offset * 2].value == $0.element && ($0.offset == 0 || tokens[1 + $0.offset * 2].value == ".") }) {
                return (table.name, NSMaxRange(tokens[count].range))
            }
        }
        return nil
    }

    private func fieldParent(_ tokens: [Token], after start: Int, command: Bool = false) -> String? {
        var stack: [(opener: String, path: String, fields: Bool)] = []
        var last: Token?
        var previous: Token?
        for token in tokens where token.range.location >= start {
            if ["{", "[", "("].contains(token.value) && token.quote == nil {
                let parent = stack.last
                let key = last?.value == ":" ? previous?.value : nil
                let isFields: Bool
                if token.value == "{" {
                    isFields = parent?.fields == true || (!command && parent?.opener == "(") || (command && key.map { Self.fieldDocuments.contains($0) } == true)
                } else { isFields = parent?.fields == true }
                let path = !isFields ? "" : key.map { key in
                    key.hasPrefix("$") || Self.fieldDocuments.contains(key) ? parent?.path ?? "" : [parent?.path ?? "", key].filter { !$0.isEmpty }.joined(separator: ".")
                } ?? parent?.path ?? ""
                stack.append((token.value, path, isFields))
            } else if ["}", "]", ")"].contains(token.value) && token.quote == nil { _ = stack.popLast() }
            previous = last; last = token
        }
        guard let frame = stack.last, frame.opener == "{", frame.fields,
              last?.value == "{" || last?.value == "," else { return nil }
        return frame.path
    }

    private static let collectionKeys: Set<String> = ["find", "aggregate", "insert", "update", "delete", "count", "distinct"]
    private static let fieldDocuments: Set<String> = ["filter", "projection", "sort", "q", "u", "$match", "$sort", "$project", "$set", "$unset", "$inc", "$group"]
    private static let cursorMethods = ["sort", "skip", "limit", "batchSize", "maxTimeMS", "pretty", "toArray"]
    private static let operators = ["$eq", "$ne", "$gt", "$gte", "$lt", "$lte", "$in", "$nin", "$and", "$or", "$nor", "$not", "$exists", "$type", "$regex", "$options", "$elemMatch", "$all", "$size"]
    private static func member(_ value: String) -> Bool { value.range(of: "^[A-Za-z_$][A-Za-z0-9_$]*(\\.[A-Za-z_$][A-Za-z0-9_$]*)*$", options: .regularExpression) != nil }
    private static func quote(_ value: String, delimiter: String = "\"") -> String {
        let encoded = String(decoding: try! JSONEncoder().encode(value), as: UTF8.self)
        return delimiter == "\"" ? encoded : "'" + encoded.dropFirst().dropLast().replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "'", with: "\\'") + "'"
    }

    private static func unescape(_ value: String) -> String {
        var encoded = "\""
        var escaped = false
        for character in value {
            if escaped {
                encoded += character == "'" ? "'" : "\\" + String(character)
                escaped = false
            } else if character == "\\" { escaped = true }
            else { encoded += character == "\"" ? "\\\"" : String(character) }
        }
        guard !escaped else { return value }
        return (try? JSONDecoder().decode(String.self, from: Data((encoded + "\"").utf8))) ?? value
    }

    private struct Token {
        let value: String
        let range: NSRange
        let word: Bool
        let quote: String?
        let protected: Bool
        let closed: Bool
        let depth: Int
    }

    private struct Lexer {
        var tokens: [Token] = []
        init(_ text: String) {
            let source = text as NSString
            let units = Array(text.utf16)
            var index = 0
            var depth = 0
            func at(_ i: Int) -> UInt16 { units.indices.contains(i) ? units[i] : 0 }
            func word(_ unit: UInt16) -> Bool { unit == 95 || unit == 36 || UnicodeScalar(unit).map { CharacterSet.alphanumerics.contains($0) || $0.value > 127 } == true }
            while index < units.count {
                let unit = at(index)
                if [9, 10, 13, 32].contains(unit) { index += 1; continue }
                let start = index
                let quote = [34, 39].contains(unit) ? String(UnicodeScalar(unit)!) : nil
                let lineComment = unit == 47 && at(index + 1) == 47
                let blockComment = unit == 47 && at(index + 1) == 42
                let regex = unit == 47 && !lineComment && !blockComment
                var closed = true
                if lineComment {
                    while index < units.count && ![10, 13].contains(at(index)) { index += 1 }
                    closed = false
                } else if blockComment {
                    index += 2
                    while index < units.count && !(at(index) == 42 && at(index + 1) == 47) { index += 1 }
                    closed = index < units.count
                    index = min(units.count, index + 2)
                } else if quote != nil || regex {
                    index += 1
                    var bracket = false
                    closed = false
                    while index < units.count {
                        let next = at(index)
                        index += 1
                        if next == 92 { index = min(units.count, index + 1); continue }
                        if regex && next == 91 { bracket = true }
                        else if regex && next == 93 { bracket = false }
                        else if next == unit && !bracket { closed = true; break }
                    }
                    if regex { while word(at(index)) { index += 1 } }
                } else {
                    index += 1
                    if word(unit) { while word(at(index)) { index += 1 } }
                }
                let range = NSRange(location: start, length: index - start)
                let raw = source.substring(with: range)
                let value = quote == nil ? raw : MongoCompletionEngine.unescape(String((closed ? String(raw.dropLast()) : raw).dropFirst()))
                if [41, 93, 125].contains(unit) && quote == nil { depth = max(0, depth - 1) }
                tokens.append(Token(value: value, range: range, word: quote != nil || word(unit), quote: quote, protected: lineComment || blockComment || regex, closed: closed, depth: depth))
                if [40, 91, 123].contains(unit) && quote == nil { depth += 1 }
            }
        }
    }
}
