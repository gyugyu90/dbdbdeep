import Foundation
import CoreFoundation

public struct DocumentPreview: Sendable, Equatable {
    public let text: String
    public let isTruncated: Bool
    public init(text: String, isTruncated: Bool) { self.text = text; self.isTruncated = isTruncated }
}

// Parsed containers are immutable and raw values never leave this type.
public struct DocumentValue: @unchecked Sendable {
    public enum Kind { case object, array, string, number, boolean, null, bson }
    public struct Child {
        public let name: String
        public let value: DocumentValue
    }

    private let raw: Any
    public let kind: Kind
    public let typeName: String
    public let childCount: Int

    public init(json: String) throws {
        self.init(try JSONSerialization.jsonObject(with: Data(json.utf8), options: .fragmentsAllowed))
    }

    private init(_ raw: Any) {
        self.raw = raw
        if raw is NSNull { kind = .null; typeName = "Null" }
        else if let document = raw as? NSDictionary {
            if let type = Self.bsonType(document) { kind = .bson; typeName = type }
            else { kind = .object; typeName = "Object" }
        } else if raw is NSArray { kind = .array; typeName = "Array" }
        else if raw is String { kind = .string; typeName = "String" }
        else if let number = raw as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() { kind = .boolean; typeName = "Boolean" }
        else { kind = .number; typeName = "Number" }
        childCount = kind == .object ? (raw as? NSDictionary)?.count ?? 0 : kind == .array ? (raw as? NSArray)?.count ?? 0 : 0
    }

    public var children: [Child] {
        if kind == .object, let document = raw as? [String: Any] {
            return document.keys.sorted { left, right in
                if left == "_id" { return right != "_id" }
                if right == "_id" { return false }
                return left < right
            }.map { Child(name: $0, value: DocumentValue(document[$0]!)) }
        }
        if kind == .array, let array = raw as? [Any] {
            return array.enumerated().map { Child(name: "[\($0.offset)]", value: DocumentValue($0.element)) }
        }
        return []
    }

    public var displayValue: String {
        switch kind {
        case .object: return "{ \(childCount) \(childCount == 1 ? "field" : "fields") }"
        case .array: return "[ \(childCount) \(childCount == 1 ? "item" : "items") ]"
        case .string:
            let text = String((raw as? String ?? "").prefix(257))
            return String(decoding: (try? JSONEncoder().encode(String(text.prefix(256)))) ?? Data(), as: UTF8.self) + (text.count > 256 ? "…" : "")
        case .null: return "null"
        case .boolean: return (raw as? NSNumber)?.boolValue == true ? "true" : "false"
        case .number: return (raw as? NSNumber)?.stringValue ?? ""
        case .bson:
            let document = raw as? [String: Any] ?? [:]
            if let id = document["$oid"] as? String { return id }
            for key in ["$numberInt", "$numberLong", "$numberDouble", "$numberDecimal", "$symbol"] {
                if let text = document[key] as? String { return text }
            }
            if let date = document["$date"] as? String { return date }
            if let date = document["$date"] as? [String: String], let milliseconds = date["$numberLong"] {
                if let value = Double(milliseconds), abs(value) < 253_402_300_800_000 {
                    let formatter = ISO8601DateFormatter()
                    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    return formatter.string(from: Date(timeIntervalSince1970: value / 1000))
                }
                return milliseconds + " ms since epoch"
            }
            if let regex = document["$regularExpression"] as? [String: String] { return "/\(regex["pattern"] ?? "")/\(regex["options"] ?? "")" }
            if let binary = document["$binary"] as? [String: String] { return "subtype \(binary["subType"] ?? "00") · base64" }
            return typeName
        }
    }

    public var json: String {
        guard let data = try? JSONSerialization.data(withJSONObject: raw, options: [.fragmentsAllowed, .prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    public var copyText: String { kind == .string ? raw as? String ?? "" : json }

    public func preview(maxCharacters: Int = 4_096) throws -> DocumentPreview {
        var writer = PreviewWriter(limit: max(0, maxCharacters))
        try writer.write(raw)
        return DocumentPreview(text: writer.text, isTruncated: writer.truncated)
    }

    private static func bsonType(_ document: NSDictionary) -> String? {
        guard document.count == 1, let key = document.allKeys.first as? String else { return nil }
        let names = ["$oid": "ObjectId", "$numberInt": "Int32", "$numberLong": "Int64", "$numberDouble": "Double", "$numberDecimal": "Decimal128", "$date": "Date", "$binary": "Binary", "$regularExpression": "Regex", "$timestamp": "Timestamp", "$minKey": "MinKey", "$maxKey": "MaxKey", "$undefined": "Undefined", "$symbol": "Symbol", "$code": "JavaScript"]
        return names[key]
    }

    private struct PreviewWriter {
        var limit: Int
        var text = ""
        var truncated = false
        private var visited = 0

        init(limit: Int) { self.limit = limit }

        private mutating func append(_ value: String) {
            for character in value {
                let count = character.utf16.count
                guard limit >= count else { truncated = true; return }
                text.append(character); limit -= count
            }
        }

        mutating func write(_ value: Any, depth: Int = 0) throws {
            try Task.checkCancellation()
            guard limit > 0, visited < 256, depth < 7 else { truncated = true; append("…"); return }
            visited += 1
            if let object = value as? NSDictionary {
                append("{")
                var keys: [String] = []
                if object["_id"] != nil { keys.append("_id") }
                let enumerator = object.keyEnumerator()
                while keys.count < 40, let key = enumerator.nextObject() as? String {
                    if key != "_id" { keys.append(key) }
                }
                keys.sort { $0 == "_id" ? $1 != "_id" : $1 != "_id" && $0 < $1 }
                for (index, key) in keys.enumerated() {
                    guard limit > 0, visited < 256 else { truncated = true; break }
                    append(index == 0 ? "\n" : ",\n")
                    append(String(repeating: "  ", count: depth + 1))
                    writeString(key as NSString)
                    append(": ")
                    if let child = object[key] { try write(child, depth: depth + 1) }
                }
                if keys.count < object.count { truncated = true; append(",\n…") }
                if !keys.isEmpty { append("\n" + String(repeating: "  ", count: depth)) }
                append("}")
            } else if let array = value as? NSArray {
                append("[")
                let count = min(40, array.count)
                for index in 0..<count {
                    guard limit > 0, visited < 256 else { truncated = true; break }
                    append(index == 0 ? "\n" : ",\n")
                    append(String(repeating: "  ", count: depth + 1))
                    try write(array[index], depth: depth + 1)
                }
                if count < array.count { truncated = true; append(",\n…") }
                if count > 0 { append("\n" + String(repeating: "  ", count: depth)) }
                append("]")
            } else if let string = value as? NSString { writeString(string) }
            else if value is NSNull { append("null") }
            else if let number = value as? NSNumber {
                append(CFGetTypeID(number) == CFBooleanGetTypeID() ? (number.boolValue ? "true" : "false") : number.stringValue)
            }
        }

        private mutating func writeString(_ string: NSString) {
            let length = min(string.length, min(1_024, max(0, limit / 6 - 2)))
            let range = string.rangeOfComposedCharacterSequences(for: NSRange(location: 0, length: length))
            let prefix = string.substring(with: range)
            let quoted = String(decoding: (try? JSONEncoder().encode(prefix)) ?? Data(), as: UTF8.self)
            append(quoted)
            if range.length < string.length { truncated = true; append("…") }
        }
    }
}
