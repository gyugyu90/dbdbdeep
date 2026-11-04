import XCTest
@testable import DBDeepCore

final class MongoCompletionEngineTests: XCTestCase {
    private let tables = [
        SchemaTable(name: "customers", columns: ["name", "email", "customer_email", "profile", "profile.city", "profile.address", "status"].map { SchemaColumn(name: $0, type: "STRING") }),
        SchemaTable(name: "orders", columns: [SchemaColumn(name: "total", type: "DOUBLE")]),
        SchemaTable(name: "order-items"), SchemaTable(name: "audit.events"), SchemaTable(name: "한글🌷")
    ]

    func testShellCollectionsAndSafeMemberInsertion() throws {
        for marked in ["db.cu|", "db.getCollection(\"cu|\")", "db['cu|']"] {
            XCTAssertEqual(try complete(marked).candidates.first?.name, "customers", marked)
        }
        XCTAssertEqual(try complete("db.order|").candidates.first { $0.name == "order-items" }?.insertion, "getCollection(\"order-items\")")
        XCTAssertEqual(try complete("db.audit.e|").candidates.first?.insertion, "audit.events")
        XCTAssertEqual(try complete("db.getCollection('한|')").candidates.first?.insertion, "'한글🌷'")
        XCTAssertEqual(try complete("db.|").candidates.count, 5)
    }

    func testOnlyExecutableHelperMethodsAreSuggested() throws {
        XCTAssertEqual(try complete("db.customers.fi|").candidates.map(\.name), ["find", "findOne"])
        XCTAssertEqual(try complete("db.getCollection('customers').fi|").candidates.first?.name, "find")
        XCTAssertEqual(try complete("db.customers.find({}).so|").candidates.first?.name, "sort")
        XCTAssertNil(optional("db.customers.findOne({}).so|"))
        XCTAssertNil(optional("db.customers.find({}).toArray().so|"))
        XCTAssertNil(optional("db.customers.dr|"))
    }

    func testFieldsUseExactCollectionAndFuzzyRanking() throws {
        for marked in ["db.customers.find({em|})", "db.customers.find({}, {em|: 1})", "db.customers.find({}).sort({em|: 1})", "db['customers'].findOne({'em|': 'a'})"] {
            let result = try complete(marked)
            XCTAssertEqual(result.candidates.first?.name, "email", marked)
            XCTAssertFalse(result.candidates.contains { $0.name == "total" })
        }
        XCTAssertEqual(try complete("db.customers.find({emali|})").candidates.first?.name, "email")
        XCTAssertEqual(try complete("db.customers.find({profile: {ci|}})").candidates.first?.insertion, "city")
        XCTAssertEqual(try complete("db.customers.find({'profile.c|': ''})").candidates.first?.insertion, "'profile.city'")
        XCTAssertEqual(try complete("db.customers.find({prof|})").candidates.first { $0.name == "profile.city" }?.insertion, "\"profile.city\"")
        XCTAssertEqual(try complete("db.customers.find({age: {$gt|: 1}})").candidates.first?.name, "$gt")
    }

    func testJSONAndRunCommandCollectionAndFieldContexts() throws {
        for marked in [#"{"find":"cu|","filter":{}}"#, #"{"aggregate":"cu|","pipeline":[]}"#, "db.runCommand({find: 'cu|', filter: {}})"] {
            XCTAssertEqual(try complete(marked).candidates.first?.name, "customers", marked)
        }
        for marked in [#"{"find":"customers","filter":{"em|":"a"}}"#, #"{"filter":{"em|":"a"},"find":"customers"}"#, "db.runCommand({find: 'customers', filter: {em|: 'a'}})", #"{"aggregate":"customers","pipeline":[{"$match":{"em|":"a"}}]}"#] {
            XCTAssertEqual(try complete(marked).candidates.first?.name, "email", marked)
        }
    }

    func testNoSuggestionsForValuesCommentsRegexOrUnrelatedText() {
        for marked in ["db.customers.find({name: 'em|'})", "db.customers.find({name: /em|/})", "// db.cu|", "/* db.cu| */", "db.customers.find({/* em| */})", "db.customers.find({name: em|})", "hello|", #"{"find":"customers","comment":"em|"}"#] {
            XCTAssertNil(optional(marked), marked)
        }
        XCTAssertNil(optional(#"{"filter":{"em|":"a"}}; {"find":"customers"}"#))
        XCTAssertNil(optional("db.customers.find({ // em|\n})", explicit: true))
        XCTAssertNil(optional(#"{"find":"orders","filter":{"find":"customers","em|":"a"}}"#))
    }

    func testIncompleteQuotedFieldsReplaceWholeTokenWithUTF16Offsets() throws {
        let marked = "// 한글 🌷\ndb.customers.find({'em|ail': ''})"
        let result = try complete(marked)
        let text = marked.replacingOccurrences(of: "|", with: "") as NSString
        XCTAssertEqual(text.substring(with: result.range), "'email'")
        XCTAssertEqual(result.candidates.first?.insertion, "'email'")
        XCTAssertEqual(try complete("db.getCollection(\"cu|").candidates.first?.insertion, "\"customers\"")
        XCTAssertEqual(try complete("db.customers.find({'em|").candidates.first?.insertion, "'email'")
    }

    func testCurrentStatementAndLazyFieldCollection() throws {
        XCTAssertEqual(try complete("db.orders.find({});\ndb.customers.find({em|})").candidates.first?.name, "email")
        XCTAssertEqual(try complete("db.orders.find({})\ndb.customers.find({em|})").candidates.first?.name, "email")
        let text = "db.customers.find({em"
        XCTAssertEqual(MongoCompletionEngine(tables: tables).fieldCollection(in: text, atUTF16Offset: text.utf16.count), "customers")
        XCTAssertNil(MongoCompletionEngine(tables: tables).fieldCollection(in: "db.cu", atUTF16Offset: 5))
        XCTAssertNil(optional("db.customers.find({|})"))
        XCTAssertNotNil(optional("db.customers.find({|})", explicit: true))
    }

    private func complete(_ marked: String, file: StaticString = #filePath, line: UInt = #line) throws -> SQLCompletionResult {
        try XCTUnwrap(optional(marked), marked, file: file, line: line)
    }

    private func optional(_ marked: String, explicit: Bool = false) -> SQLCompletionResult? {
        SQLCompletionEngine(tables: tables, kind: .mongodb).completions(in: marked.replacingOccurrences(of: "|", with: ""), atUTF16Offset: (marked as NSString).range(of: "|").location, explicit: explicit)
    }
}
