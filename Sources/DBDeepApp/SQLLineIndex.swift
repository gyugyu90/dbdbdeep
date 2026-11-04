import Foundation

struct SQLLineIndex {
    static let maximumLines = 100_000
    let starts: [Int]
    let length: Int
    var count: Int { starts.count }

    init(_ text: String) {
        var starts = [0]
        var offset = 0
        var previousWasCR = false
        for unit in text.utf16 {
            offset += 1
            if unit == 10 && previousWasCR { starts[starts.count - 1] = offset }
            else if [10, 13, 0x85, 0x2028, 0x2029].contains(unit) { starts.append(offset) }
            previousWasCR = unit == 13
        }
        self.starts = starts
        length = offset
    }

    func line(at offset: Int) -> Int {
        var lower = 0
        var upper = starts.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if starts[middle] <= offset { lower = middle + 1 } else { upper = middle }
        }
        return max(0, lower - 1)
    }

    func truncated(_ text: String, maximumLines: Int = Self.maximumLines) -> String? {
        guard count > maximumLines else { return nil }
        let source = text as NSString
        var end = starts[maximumLines] - 1
        if source.character(at: end) == 10, end > 0, source.character(at: end - 1) == 13 { end -= 1 }
        return source.substring(to: end)
    }
}
