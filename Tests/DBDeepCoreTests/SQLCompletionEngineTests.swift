import XCTest
@testable import DBDeepCore

final class SQLCompletionEngineTests: XCTestCase {
    private let tables = [
        SchemaTable(name: "CUSTOMERS", columns: [SchemaColumn(name: "ID", type: "NUMBER"), SchemaColumn(name: "CUSTOMER_NAME", type: "VARCHAR2"), SchemaColumn(name: "EMAIL", type: "VARCHAR2")]),
        SchemaTable(name: "ORDERS", columns: [SchemaColumn(name: "ID", type: "NUMBER"), SchemaColumn(name: "CUSTOMER_ID", type: "NUMBER"), SchemaColumn(name: "TOTAL", type: "NUMBER")]),
        SchemaTable(name: "ACTIVE_CUSTOMERS", isView: true, columns: [SchemaColumn(name: "ID", type: "NUMBER")])
    ]

    func testFromAndJoinSuggestTablesAndViews() throws {
        for sql in ["SELECT * FROM cu|", "SELECT * FROM orders o JOIN cu| ON 1 = 1", "DELETE FROM cu|", "UPDATE cu| SET id = 1", "INSERT INTO cu|"] {
            let result = try complete(sql)
            XCTAssertEqual(result.candidates.first?.name, "CUSTOMERS", sql)
            XCTAssertTrue(result.candidates.allSatisfy { $0.kind != .column })
        }
        XCTAssertEqual(try complete("SELECT * FROM active_|").candidates.first?.kind, .view)
    }

    func testEmptyTableSlotAndSchemaQualification() throws {
        XCTAssertEqual(try complete("SELECT * FROM |").candidates.count, 3)
        XCTAssertEqual(try complete("SELECT * FROM APP.cu|").candidates.first?.insertion, "CUSTOMERS")
        XCTAssertEqual(try complete("SELECT * FROM customers c, or|").candidates.first?.name, "ORDERS")
    }

    func testSelectUsesFollowingFromAndWhereUsesReferencedColumns() throws {
        for sql in ["SELECT em| FROM customers", "SELECT * FROM customers WHERE em|", "SELECT * FROM customers GROUP BY em|", "SELECT * FROM customers ORDER BY em|", "SELECT * FROM customers HAVING em| IS NOT NULL", "UPDATE customers SET em|", "INSERT INTO customers (em|) VALUES ('a')"] {
            let result = try complete(sql)
            XCTAssertEqual(result.candidates.first?.name, "EMAIL", sql)
            XCTAssertTrue(result.candidates.allSatisfy { $0.kind == .column })
            XCTAssertFalse(result.candidates.contains { $0.name == "TOTAL" })
        }
    }

    func testSelectBeforeKnowingTableUsesKnownSchema() throws {
        XCTAssertEqual(try complete("SELECT tot|").candidates.first?.name, "TOTAL")
    }

    func testAliasAndTableQualifiedColumns() throws {
        for sql in ["SELECT c.em| FROM customers c JOIN orders o ON c.id = o.customer_id", "SELECT * FROM customers AS c WHERE c.em|", "SELECT customers.em| FROM customers", "SELECT * FROM customers c WHERE c.|"] {
            let result = try complete(sql)
            XCTAssertTrue(result.candidates.contains { $0.name == "EMAIL" }, sql)
            XCTAssertFalse(result.candidates.contains { $0.name == "TOTAL" }, sql)
            XCTAssertTrue(result.candidates.allSatisfy { !$0.insertion.contains(".") })
        }
        XCTAssertNil(optionalComplete("SELECT x.em| FROM customers c"))
    }

    func testAmbiguousColumnsAreQualifiedWithEachAlias() throws {
        let result = try complete("SELECT i| FROM customers c JOIN orders o ON c.id = o.customer_id")
        let ids = result.candidates.filter { $0.name == "ID" }
        XCTAssertEqual(Set(ids.map(\.insertion)), ["c.ID", "o.ID"])
    }

    func testSameTableCanHaveMultipleAliases() throws {
        let result = try complete("SELECT i| FROM customers a JOIN customers b ON a.id = b.id")
        XCTAssertEqual(Set(result.candidates.filter { $0.name == "ID" }.map(\.insertion)), ["a.ID", "b.ID"])
    }

    func testRankingPrefersPrefixThenSubstringThenAbbreviationAndTypo() throws {
        let engine = SQLCompletionEngine(tables: [SchemaTable(name: "T", columns: ["CUSTOMER_EMAIL", "EMAIL_ADDRESS", "EMAIL", "E_MAIL"].map { SchemaColumn(name: $0, type: "TEXT") })])
        XCTAssertEqual(try complete("SELECT em| FROM t", engine: engine).candidates.map(\.name), ["EMAIL", "EMAIL_ADDRESS", "CUSTOMER_EMAIL", "E_MAIL"])
        XCTAssertEqual(try complete("SELECT cstnm| FROM customers").candidates.first?.name, "CUSTOMER_NAME")
        XCTAssertEqual(try complete("SELECT * FROM custmo|").candidates.first?.name, "CUSTOMERS")
        XCTAssertEqual(try complete("SELECT emali| FROM customers").candidates.first?.name, "EMAIL")
        XCTAssertNil(optionalComplete("SELECT zzzz| FROM customers"))
    }

    func testExactMatchRanksFirst() throws {
        let result = try complete("SELECT email| FROM customers")
        XCTAssertEqual(result.candidates.first?.name, "EMAIL")
    }

    func testQuotedIdentifiersAndReplacementRange() throws {
        let schema = [SchemaTable(name: "Order Items", columns: [SchemaColumn(name: "line Total", type: "NUMBER"), SchemaColumn(name: "A\"B", type: "TEXT")])]
        let engine = SQLCompletionEngine(tables: schema)
        let table = try complete("SELECT * FROM \"Order| Items\"", engine: engine)
        XCTAssertEqual(table.candidates.first?.insertion, "\"Order Items\"")
        XCTAssertEqual(table.range.length, "\"Order Items\"".utf16.count)
        XCTAssertEqual(try complete("SELECT \"line| Total\" FROM \"Order Items\"", engine: engine).candidates.first?.insertion, "\"line Total\"")
        XCTAssertEqual(try complete("SELECT \"A|\" FROM \"Order Items\"", engine: engine).candidates.first?.insertion, "\"A\"\"B\"")
        XCTAssertEqual(try complete("SELECT \"line|", engine: engine).candidates.first?.insertion, "\"line Total\"")
    }

    func testReservedAndOracleMixedCaseNamesAreQuotedButSQLiteNamesStaySimple() throws {
        let schema = [SchemaTable(name: "things", columns: [SchemaColumn(name: "camelCase", type: "TEXT"), SchemaColumn(name: "select", type: "TEXT")])]
        XCTAssertEqual(try complete("SELECT cam|", engine: SQLCompletionEngine(tables: schema)).candidates.first?.insertion, "\"camelCase\"")
        XCTAssertEqual(try complete("SELECT cam|", engine: SQLCompletionEngine(tables: schema, kind: .sample)).candidates.first?.insertion, "camelCase")
        XCTAssertEqual(try complete("SELECT sel|", engine: SQLCompletionEngine(tables: schema)).candidates.first?.insertion, "\"select\"")
    }

    func testQuotedAliasesAndEscapedQuotes() throws {
        let result = try complete("SELECT \"client\".em| FROM customers \"client\"")
        XCTAssertEqual(result.candidates.first?.insertion, "EMAIL")
        let engine = SQLCompletionEngine(tables: [SchemaTable(name: "A\"B", columns: [SchemaColumn(name: "NAME", type: "TEXT")])])
        XCTAssertEqual(try complete("SELECT na| FROM \"A\"\"B\"", engine: engine).candidates.first?.name, "NAME")
    }

    func testNoSuggestionsInsideStringsCommentsOrOracleAlternativeQuotes() {
        for sql in ["SELECT 'em|ail' FROM customers", "SELECT 'em|", "SELECT q'[it''s em|]' FROM customers", "SELECT nq'#em|#' FROM customers", "SELECT /* em| */ id FROM customers", "SELECT id FROM customers -- em|", "SELECT id FROM customers /* em|"] {
            XCTAssertNil(optionalComplete(sql), sql)
        }
        XCTAssertNotNil(optionalComplete("SELECT /* comment */ em| FROM customers"))
    }

    func testOnlyCurrentStatementAndUnionBranchContributeTables() throws {
        for sql in ["SELECT * FROM orders; SELECT em| FROM customers; SELECT * FROM orders", "SELECT id FROM orders UNION ALL SELECT em| FROM customers"] {
            let result = try complete(sql)
            XCTAssertEqual(result.candidates.first?.name, "EMAIL")
            XCTAssertFalse(result.candidates.contains { $0.name == "TOTAL" })
        }
    }

    func testNestedQueryUsesInnerTable() throws {
        let result = try complete("SELECT * FROM customers c WHERE EXISTS (SELECT tot| FROM orders o WHERE o.customer_id = c.id)")
        XCTAssertEqual(result.candidates.first?.name, "TOTAL")
        XCTAssertFalse(result.candidates.contains { $0.name == "EMAIL" })
        XCTAssertEqual(try complete("SELECT COALESCE(em|, '') FROM customers").candidates.first?.name, "EMAIL")
        let qualified = try complete("SELECT COALESCE(c.em|, '') FROM customers c JOIN orders o ON c.id = o.customer_id")
        XCTAssertEqual(qualified.candidates.first?.name, "EMAIL")
        XCTAssertFalse(qualified.candidates.contains { $0.name == "TOTAL" })
    }

    func testUTF16ReplacementCoversWholeWordWithSuffix() throws {
        let marked = "-- 한글 🌷\nSELECT em|ail FROM customers"
        let sql = marked.replacingOccurrences(of: "|", with: "")
        let result = try complete(marked)
        XCTAssertEqual((sql as NSString).substring(with: result.range), "email")
    }

    func testNoSuggestionsForAliasesKeywordsOrUnrelatedContext() {
        for sql in ["SELECT * FROM customers c|", "SELECT email AS em| FROM customers", "SELECT|", "FROM|", "-- comment|", "hello|"] {
            XCTAssertNil(optionalComplete(sql), sql)
        }
        XCTAssertNil(SQLCompletionEngine(tables: []).completions(in: "SELECT em", atUTF16Offset: 9))
        XCTAssertNil(SQLCompletionEngine(tables: tables).completions(in: "SELECT em", atUTF16Offset: -1))
    }

    private func complete(_ marked: String, engine: SQLCompletionEngine? = nil, file: StaticString = #filePath, line: UInt = #line) throws -> SQLCompletionResult {
        try XCTUnwrap(optionalComplete(marked, engine: engine), marked, file: file, line: line)
    }

    private func optionalComplete(_ marked: String, engine: SQLCompletionEngine? = nil) -> SQLCompletionResult? {
        let source = marked as NSString
        return (engine ?? SQLCompletionEngine(tables: tables)).completions(in: marked.replacingOccurrences(of: "|", with: ""), atUTF16Offset: source.range(of: "|").location)
    }
}
