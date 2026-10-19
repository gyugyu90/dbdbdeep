import Foundation

public struct SQLStatement: Equatable, Sendable {
    public let text: String
    public let range: NSRange
}

public enum SQLStatementLocator {
    public static func statement(in sql: String, atUTF16Offset offset: Int) -> SQLStatement? {
        let source = sql as NSString
        let location = min(max(0, offset), source.length)
        let statements = statements(in: sql)
        if let statement = statements.first(where: { NSLocationInRange(location, $0.range) }) { return statement }
        let previous = statements.last { NSMaxRange($0.range) <= location }
        if let previous {
            let gap = source.substring(with: NSRange(location: NSMaxRange(previous.range), length: location - NSMaxRange(previous.range)))
            if gap.trimmingCharacters(in: .whitespaces).isEmpty { return previous }
            let remainder = source.substring(from: NSMaxRange(previous.range))
            if remainder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return previous }
        } else if let first = statements.first {
            let prefix = source.substring(to: first.range.location)
            if prefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return first }
        }
        if let next = statements.first(where: { $0.range.location > location }) {
            let gap = source.substring(with: NSRange(location: location, length: next.range.location - location))
            if gap.trimmingCharacters(in: .whitespaces).isEmpty { return next }
        }
        return nil
    }

    public static func statements(in sql: String) -> [SQLStatement] {
        let source = sql as NSString
        let tokens = tokenize(sql)
        var statements: [SQLStatement] = []
        var index = 0
        var start = 0
        while index < tokens.count {
            if tokens[index].kind == .semicolon || tokens[index].kind == .slash {
                start = NSMaxRange(tokens[index].range)
                index += 1
                continue
            }
            guard var end = statementEnd(tokens, from: index) else { break }
            if end + 1 < tokens.count && tokens[end + 1].kind == .slash { end += 1 }
            let textEnd = tokens[end].kind == .slash ? tokens[end].range.location : NSMaxRange(tokens[end].range)
            let sourceEnd = NSMaxRange(tokens[end].range)
            let raw = source.substring(with: NSRange(location: start, length: textEnd - start))
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                let withoutLeadingWhitespace = String(raw.unicodeScalars.drop(while: { CharacterSet.whitespacesAndNewlines.contains($0) }))
                let leading = raw.utf16.count - withoutLeadingWhitespace.utf16.count
                statements.append(SQLStatement(text: text, range: NSRange(location: start + leading, length: sourceEnd - start - leading)))
            }
            start = sourceEnd
            index = end + 1
        }
        return statements
    }

    private enum Kind: Equatable {
        case word(String), semicolon, slash, other, incomplete
    }

    private struct Token {
        let kind: Kind
        let range: NSRange
        var word: String? { if case .word(let word) = kind { return word }; return nil }
    }

    private enum Scope {
        case block, declarations, routine(hasBody: Bool), package, control
        var beginsBody: Bool {
            switch self {
            case .declarations, .routine, .package: return true
            default: return false
            }
        }
    }

    private static func statementEnd(_ tokens: [Token], from start: Int) -> Int? {
        var scopes: [Scope] = []
        var index = start
        switch tokens[start].word {
        case "BEGIN":
            let next = start + 1 < tokens.count ? tokens[start + 1] : nil
            if next?.kind != .semicolon && !["TRANSACTION", "DEFERRED", "IMMEDIATE", "EXCLUSIVE"].contains(next?.word ?? "") {
                scopes = [.block]; index += 1
            }
        case "DECLARE": scopes = [.declarations]; index += 1
        case "CREATE":
            var head = start + 1
            if head + 1 < tokens.count && tokens[head].word == "OR" && tokens[head + 1].word == "REPLACE" { head += 2 }
            if head < tokens.count && ["EDITIONABLE", "NONEDITIONABLE", "TEMP", "TEMPORARY"].contains(tokens[head].word ?? "") { head += 1 }
            if head < tokens.count {
                switch tokens[head].word {
                case "PROCEDURE", "FUNCTION", "TRIGGER": scopes = [.routine(hasBody: false)]
                case "PACKAGE": scopes = [.package]
                case "TYPE" where head + 1 < tokens.count && tokens[head + 1].word == "BODY": scopes = [.package]
                default: break
                }
                if !scopes.isEmpty { index = head + 1 }
            }
        default: break
        }
        let isBlock = !scopes.isEmpty
        while index < tokens.count {
            let token = tokens[index]
            if token.kind == .incomplete { return nil }
            if token.kind == .slash { return index }
            if token.kind == .semicolon {
                if case .routine(hasBody: false) = scopes.last { scopes.removeLast() }
                if !isBlock || scopes.isEmpty { return index }
            }
            if isBlock {
                switch token.word {
                case "BEGIN":
                    if scopes.last?.beginsBody == true { scopes.removeLast() }
                    scopes.append(.block)
                case "DECLARE":
                    if case .routine = scopes.last { scopes.removeLast() }
                    scopes.append(.declarations)
                case "FUNCTION", "PROCEDURE": scopes.append(.routine(hasBody: false))
                case "IS", "AS":
                    if case .routine = scopes.last { scopes[scopes.count - 1] = .routine(hasBody: true) }
                case "IF" where index + 2 < tokens.count && tokens[index + 1].word == "NOT" && tokens[index + 2].word == "EXISTS": break
                case "IF", "LOOP", "CASE": scopes.append(.control)
                case "END":
                    guard !scopes.isEmpty else { return nil }
                    scopes.removeLast()
                    if index + 1 < tokens.count && ["IF", "LOOP", "CASE"].contains(tokens[index + 1].word ?? "") { index += 1 }
                default: break
                }
            }
            index += 1
        }
        return isBlock ? nil : tokens.indices.last
    }

    private static func tokenize(_ sql: String) -> [Token] {
        let units = Array(sql.utf16)
        let source = sql as NSString
        var tokens: [Token] = []
        var index = 0
        func at(_ offset: Int) -> UInt16 { offset < units.count ? units[offset] : 0 }
        func whitespace(_ unit: UInt16) -> Bool {
            UnicodeScalar(unit).map { CharacterSet.whitespacesAndNewlines.contains($0) } ?? false
        }
        func wordCharacter(_ unit: UInt16) -> Bool {
            (65...90).contains(unit) || (97...122).contains(unit) || (48...57).contains(unit) || [95, 36, 35].contains(unit)
        }
        while index < units.count {
            let start = index
            let character = at(index)
            if whitespace(character) { index += 1; continue }
            if character == 45 && at(index + 1) == 45 {
                index += 2
                while index < units.count && at(index) != 10 && at(index) != 13 { index += 1 }
                continue
            }
            if character == 47 && at(index + 1) == 42 {
                index += 2
                while index < units.count && !(at(index) == 42 && at(index + 1) == 47) { index += 1 }
                if index >= units.count {
                    tokens.append(Token(kind: .incomplete, range: NSRange(location: start, length: units.count - start)))
                }
                index = min(units.count, index + 2)
                continue
            }
            var kind: Kind = .other
            let qPrefix: Int
            if [81, 113].contains(character) && at(index + 1) == 39 { qPrefix = 2 }
            else if [78, 110].contains(character) && [81, 113].contains(at(index + 1)) && at(index + 2) == 39 { qPrefix = 3 }
            else { qPrefix = 0 }
            if qPrefix > 0 {
                let opening = at(index + qPrefix)
                let pairedDelimiters: [UInt16: UInt16] = [91: 93, 123: 125, 40: 41, 60: 62]
                let closing = pairedDelimiters[opening] ?? opening
                index += qPrefix + 1
                while index < units.count && !(at(index) == closing && at(index + 1) == 39) { index += 1 }
                if index >= units.count { kind = .incomplete }
                index = min(units.count, index + 2)
            } else if [39, 34, 96, 91].contains(character) {
                let closing: UInt16 = character == 91 ? 93 : character
                index += 1
                var closed = false
                while index < units.count {
                    if at(index) == closing {
                        index += 1
                        if character != 91 && at(index) == closing { index += 1; continue }
                        closed = true
                        break
                    }
                    index += 1
                }
                if !closed { kind = .incomplete }
            } else if wordCharacter(character) {
                index += 1
                while index < units.count && wordCharacter(at(index)) { index += 1 }
                kind = .word(String(decoding: units[start..<index], as: UTF16.self).uppercased())
            } else {
                index += 1
                if character == 59 { kind = .semicolon }
                if character == 47 {
                    let line = source.substring(with: source.lineRange(for: NSRange(location: start, length: 0)))
                    if line.trimmingCharacters(in: .whitespacesAndNewlines) == "/" { kind = .slash }
                }
            }
            tokens.append(Token(kind: kind, range: NSRange(location: start, length: index - start)))
        }
        return tokens
    }
}
