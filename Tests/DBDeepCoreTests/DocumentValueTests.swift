import XCTest
@testable import DBDeepCore

final class DocumentValueTests: XCTestCase {
    func testLargeContainerPreviewIsBoundedWithoutLosingTheOriginalValue() throws {
        let longText = String(repeating: "x", count: 1_000_000)
        let document = try DocumentValue(json: "{\"nested\":{\"text\":\"" + longText + "\",\"items\":[" + (0..<100_000).map(String.init).joined(separator: ",") + "]}}")
        let preview = try document.preview()
        XCTAssertTrue(preview.isTruncated)
        XCTAssertLessThanOrEqual(preview.text.utf16.count, 4_096)
        XCTAssertTrue(preview.text.contains("nested"))
        XCTAssertTrue(document.copyText.contains(longText))
        let array = try DocumentValue(json: "[" + (0..<100_000).map(String.init).joined(separator: ",") + "]")
        let arrayPreview = try array.preview()
        XCTAssertTrue(arrayPreview.isTruncated)
        XCTAssertLessThan(arrayPreview.text.count, 1_000)
        XCTAssertEqual(array.childCount, 100_000)
    }

    func testSmallPreviewPreservesBSONPrecisionAndUnicodeAndHonorsZeroBudget() throws {
        let json = #"{"name":"한글 🌷","precise":{"$numberLong":"9223372036854775807"},"values":[null,true,{}]}"#
        let value = try DocumentValue(json: json)
        let preview = try value.preview()
        XCTAssertFalse(preview.isTruncated)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: Data(preview.text.utf8)) as? NSDictionary,
                       try JSONSerialization.jsonObject(with: Data(json.utf8)) as? NSDictionary)
        XCTAssertEqual(try value.preview(maxCharacters: 0), DocumentPreview(text: "", isTruncated: true))
        XCTAssertLessThanOrEqual(try value.preview(maxCharacters: 12).text.utf16.count, 12)
    }

    func testNestedDocumentsArraysAndEmptyContainersKeepTheirStructure() throws {
        let document = try DocumentValue(json: #"{"profile":{"city":"Seoul"},"tags":["a",{"active":true}],"emptyObject":{},"emptyArray":[],"nothing":null}"#)
        XCTAssertEqual(document.kind, .object)
        XCTAssertEqual(document.childCount, 5)
        let fields = Dictionary(uniqueKeysWithValues: document.children.map { ($0.name, $0.value) })
        XCTAssertEqual(fields["profile"]?.children.first?.name, "city")
        XCTAssertEqual(fields["tags"]?.children.map(\.name), ["[0]", "[1]"])
        XCTAssertEqual(fields["tags"]?.children[1].value.children.first?.value.kind, .boolean)
        XCTAssertEqual(fields["emptyObject"]?.kind, .object)
        XCTAssertEqual(fields["emptyObject"]?.childCount, 0)
        XCTAssertEqual(fields["emptyArray"]?.kind, .array)
        XCTAssertEqual(fields["nothing"]?.kind, .null)
        XCTAssertNil(fields["missing"])
    }

    func testStringsThatLookLikeJSONStayStringsAndBooleansAreNotNumbers() throws {
        let document = try DocumentValue(json: #"{"text":"{\"nested\":true}","one":1,"flag":true}"#)
        let fields = Dictionary(uniqueKeysWithValues: document.children.map { ($0.name, $0.value) })
        XCTAssertEqual(fields["text"]?.kind, .string)
        XCTAssertEqual(fields["text"]?.children.count, 0)
        XCTAssertEqual(fields["text"]?.copyText, #"{"nested":true}"#)
        XCTAssertEqual(fields["one"]?.kind, .number)
        XCTAssertEqual(fields["flag"]?.displayValue, "true")
    }

    func testCanonicalBSONTypesAndPrecisionArePreserved() throws {
        let cases: [(String, String, String)] = [
            (#"{"$oid":"507f1f77bcf86cd799439011"}"#, "ObjectId", "507f1f77bcf86cd799439011"),
            (#"{"$numberInt":"1"}"#, "Int32", "1"),
            (#"{"$numberLong":"9223372036854775807"}"#, "Int64", "9223372036854775807"),
            (#"{"$numberDouble":"NaN"}"#, "Double", "NaN"),
            (#"{"$numberDecimal":"1234567890.123456789012345678901234"}"#, "Decimal128", "1234567890.123456789012345678901234"),
            (#"{"$date":{"$numberLong":"0"}}"#, "Date", "1970-01-01T00:00:00.000Z"),
            (#"{"$regularExpression":{"pattern":"test","options":"i"}}"#, "Regex", "/test/i")
        ]
        for (json, type, preview) in cases {
            let value = try DocumentValue(json: json)
            XCTAssertEqual(value.kind, .bson)
            XCTAssertEqual(value.typeName, type)
            XCTAssertEqual(value.displayValue, preview)
            XCTAssertTrue(value.children.isEmpty)
            XCTAssertEqual(try JSONSerialization.jsonObject(with: Data(value.copyText.utf8)) as? NSDictionary,
                           try JSONSerialization.jsonObject(with: Data(json.utf8)) as? NSDictionary)
        }
    }

    func testLongStringPreviewDoesNotTruncateCopiedValue() throws {
        let original = String(repeating: "🌷한글", count: 20_000)
        let value = try DocumentValue(json: String(decoding: JSONEncoder().encode(original), as: UTF8.self))
        XCTAssertTrue(value.displayValue.hasSuffix("…"))
        XCTAssertLessThan(value.displayValue.count, 300)
        XCTAssertEqual(value.copyText, original)
    }

    func testQueryResultDocumentsSurviveBridgeAndLegacyResultsRemainCompatible() throws {
        let raw = #"{"nested":{"items":[null,{"$numberLong":"9223372036854775807"}]}}"#
        let result = QueryResult(columns: ["nested"], rows: [["table preview"]], documents: [raw])
        guard case .result(let decoded) = try OracleBridgeFrame.decode(JSONEncoder().encode(result)) else { return XCTFail() }
        XCTAssertEqual(decoded.documents, [raw])
        let legacy = Data(#"{"columns":["name"],"rows":[["old"]],"affected":0,"elapsed":0,"truncated":false,"message":"done"}"#.utf8)
        guard case .result(let decodedLegacy) = try OracleBridgeFrame.decode(legacy) else { return XCTFail() }
        XCTAssertNil(decodedLegacy.documents)
        XCTAssertEqual(decodedLegacy.rows, [["old"]])
        XCTAssertThrowsError(try DocumentValue(json: "{unfinished"))
    }
}
