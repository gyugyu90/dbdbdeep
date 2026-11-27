import Foundation

public struct SQLLineEdit {
    public enum Action { case toggleComment, indent, outdent }
    public let range: NSRange
    public let replacement: String
    public let selection: NSRange

    public static func make(in text: String, selection: NSRange, action: Action) -> SQLLineEdit? {
        let source = text as NSString
        guard selection.location != NSNotFound, selection.location >= 0, selection.length >= 0,
              selection.location <= source.length, selection.length <= source.length - selection.location else { return nil }
        let covered = NSRange(location: selection.location, length: max(0, selection.length - 1))
        let range = source.lineRange(for: covered)
        let block = source.substring(with: range) as NSString
        var lines: [NSRange] = []
        var index = 0
        repeat {
            let line = block.lineRange(for: NSRange(location: index, length: 0))
            lines.append(line)
            index = NSMaxRange(line)
        } while index < block.length
        func indentation(_ line: NSRange) -> Int {
            var offset = line.location
            while offset < NSMaxRange(line), [9, 32].contains(block.character(at: offset)) { offset += 1 }
            return offset - line.location
        }
        let uncomment = action == .toggleComment && lines.allSatisfy { line in
            let start = line.location + indentation(line)
            return NSMaxRange(line) - start >= 3 && block.substring(with: NSRange(location: start, length: 3)) == "-- "
        }
        var edits: [(range: NSRange, text: String)] = []
        for line in lines {
            switch action {
            case .toggleComment:
                edits.append((NSRange(location: line.location + indentation(line), length: uncomment ? 3 : 0), uncomment ? "" : "-- "))
            case .indent:
                edits.append((NSRange(location: line.location, length: 0), "    "))
            case .outdent:
                var count = 0
                while count < min(4, line.length), block.character(at: line.location + count) == 32 { count += 1 }
                if count == 0, line.length > 0, block.character(at: line.location) == 9 { count = 1 }
                edits.append((NSRange(location: line.location, length: count), ""))
            }
        }
        var pieces: [String] = []
        pieces.reserveCapacity(edits.count * 2 + 1)
        var consumed = 0
        for edit in edits {
            pieces.append(block.substring(with: NSRange(location: consumed, length: edit.range.location - consumed)))
            pieces.append(edit.text)
            consumed = NSMaxRange(edit.range)
        }
        pieces.append(block.substring(from: consumed))
        let updated = pieces.joined()
        let newSelection: NSRange
        if selection.length > 0 { newSelection = NSRange(location: range.location, length: updated.utf16.count) }
        else {
            let caret = selection.location - range.location
            let delta = edits.reduce(0) { result, edit in
                result + (edit.range.location <= caret ? edit.text.utf16.count - min(edit.range.length, caret - edit.range.location) : 0)
            }
            newSelection = NSRange(location: range.location + caret + delta, length: 0)
        }
        return SQLLineEdit(range: range, replacement: updated, selection: newSelection)
    }
}
