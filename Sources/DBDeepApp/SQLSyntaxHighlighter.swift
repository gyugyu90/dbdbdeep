import AppKit

struct SQLSyntaxHighlighter {
    struct Rule {
        let expression: NSRegularExpression
        let color: NSColor
    }

    struct Matches {
        let rules: [[NSRange]]
    }

    static var rules: [Rule] {
        let definitions: [(String, NSColor)] = [
            ("\\b(SELECT|FROM|WHERE|ORDER|BY|GROUP|HAVING|JOIN|LEFT|RIGHT|INNER|OUTER|ON|AS|AND|OR|NOT|NULL|IS|IN|LIKE|INSERT|INTO|VALUES|UPDATE|SET|DELETE|CREATE|TABLE|DROP|ALTER|LIMIT|OFFSET|FETCH|FIRST|ROWS|ONLY|DISTINCT|ASC|DESC|COUNT|SUM|AVG|CASE|WHEN|THEN|ELSE|END|BEGIN|COMMIT|ROLLBACK)\\b", NSColor(Theme.purple)),
            ("\\b[0-9]+(?:\\.[0-9]+)?\\b", NSColor(Theme.sqlNumber)),
            ("'(?:''|[^'])*'", NSColor(Theme.sqlString)),
            ("--[^\\n]*|/\\*[\\s\\S]*?\\*/", NSColor(Theme.sqlComment))
        ]
        return definitions.compactMap { pattern, color in
            (try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])).map { Rule(expression: $0, color: color) }
        }
    }

    static func matches(in text: String, rules: [Rule], cancelled: () -> Bool) -> Matches? {
        let range = NSRange(location: 0, length: (text as NSString).length)
        var result: [[NSRange]] = []
        for rule in rules {
            var ranges: [NSRange] = []
            rule.expression.enumerateMatches(in: text, range: range) { match, _, stop in
                if cancelled() { stop.pointee = true }
                else if let match { ranges.append(match.range) }
            }
            guard !cancelled() else { return nil }
            result.append(ranges)
        }
        return Matches(rules: result)
    }

    static func visibleMatches(_ matches: [NSRange], in range: NSRange) -> ArraySlice<NSRange> {
        var lower = 0
        var upper = matches.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if NSMaxRange(matches[middle]) <= range.location { lower = middle + 1 } else { upper = middle }
        }
        let start = lower
        while lower < matches.count && matches[lower].location < NSMaxRange(range) { lower += 1 }
        return matches[start..<lower]
    }
}
