import Foundation

struct SQLToken {
    let value: String
    let range: NSRange
    let identifier: Bool
    let quoted: Bool
    let scope: Int
    let followingScope: Int
    var keyword: String { quoted ? "" : value.uppercased() }
}

struct SQLProtectedRange {
    let range: NSRange
    let closed: Bool
    var isLiteral = false
    func contains(_ offset: Int) -> Bool { offset > range.location && (closed ? offset < NSMaxRange(range) : offset <= NSMaxRange(range)) }
}

struct SQLLexer {
    var tokens: [SQLToken] = []
    var protected: [SQLProtectedRange] = []
    var parents: [Int: Int] = [:]

    init(_ sql: String) {
        let source = sql as NSString
        let units = Array(sql.utf16)
        var index = 0
        var scope = 0
        var nextScope = 1
        func at(_ position: Int) -> UInt16 { position < units.count ? units[position] : 0 }
        func letter(_ unit: UInt16) -> Bool {
            [95, 36, 35].contains(unit) || UnicodeScalar(unit).map { CharacterSet.alphanumerics.contains($0) || $0.value > 127 } == true
        }
        while index < units.count {
            let start = index
            let unit = at(index)
            if UnicodeScalar(unit).map({ CharacterSet.whitespacesAndNewlines.contains($0) }) == true { index += 1; continue }
            if unit == 45 && at(index + 1) == 45 {
                while index < units.count && ![10, 13].contains(at(index)) { index += 1 }
                protected.append(SQLProtectedRange(range: NSRange(location: start, length: index - start), closed: false)); continue
            }
            if unit == 47 && at(index + 1) == 42 {
                index += 2
                while index < units.count && !(at(index) == 42 && at(index + 1) == 47) { index += 1 }
                let closed = index < units.count
                index = min(units.count, index + 2)
                protected.append(SQLProtectedRange(range: NSRange(location: start, length: index - start), closed: closed)); continue
            }
            let qLength = [81, 113].contains(unit) && at(index + 1) == 39 ? 2 : ([78, 110].contains(unit) && [81, 113].contains(at(index + 1)) && at(index + 2) == 39 ? 3 : 0)
            if unit == 39 || qLength > 0 {
                var closed = false
                if qLength > 0 {
                    let opening = at(index + qLength)
                    let pairs: [UInt16: UInt16] = [91: 93, 123: 125, 40: 41, 60: 62]
                    let closing = pairs[opening] ?? opening
                    index += qLength + 1
                    while index < units.count && !(at(index) == closing && at(index + 1) == 39) { index += 1 }
                    closed = index < units.count; index = min(units.count, index + 2)
                } else {
                    index += 1
                    while index < units.count {
                        if at(index) == 39 {
                            index += 1
                            if at(index) == 39 { index += 1; continue }
                            closed = true; break
                        }
                        index += 1
                    }
                }
                protected.append(SQLProtectedRange(range: NSRange(location: start, length: index - start), closed: closed, isLiteral: true)); continue
            }
            let quoted = unit == 34
            let identifier = quoted || letter(unit)
            var value: String
            if quoted {
                index += 1
                var content = ""
                var chunk = index
                while index < units.count {
                    if at(index) == 34 {
                        content += source.substring(with: NSRange(location: chunk, length: index - chunk))
                        index += 1
                        if at(index) == 34 { content += "\""; index += 1; chunk = index; continue }
                        chunk = index; break
                    }
                    index += 1
                }
                if chunk < index { content += source.substring(with: NSRange(location: chunk, length: index - chunk)) }
                value = content
            } else {
                index += 1
                if identifier { while index < units.count && letter(at(index)) { index += 1 } }
                value = source.substring(with: NSRange(location: start, length: index - start))
            }
            let tokenScope = value == ")" ? parents[scope] ?? 0 : scope
            if value == "(" { parents[nextScope] = scope; scope = nextScope; nextScope += 1 }
            else if value == ")" { scope = tokenScope }
            tokens.append(SQLToken(value: value, range: NSRange(location: start, length: index - start), identifier: identifier, quoted: quoted, scope: tokenScope, followingScope: scope))
        }
    }
}
