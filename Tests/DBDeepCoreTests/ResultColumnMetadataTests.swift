import XCTest
@testable import DBDeepCore

final class ResultColumnMetadataTests: XCTestCase {
    private let tables = [
        SchemaTable(name: "CUSTOMERS", columns: [
            SchemaColumn(name: "ID", type: "NUMBER", comment: "고객 식별자"),
            SchemaColumn(name: "NAME", type: "VARCHAR2", comment: "고객 이름\n화면에 표시됩니다.")
        ]),
        SchemaTable(name: "ORDERS", columns: [
            SchemaColumn(name: "ID", type: "NUMBER", comment: "주문 식별자"),
            SchemaColumn(name: "CUSTOMER_ID", type: "NUMBER", comment: "주문 고객")
        ])
    ]

    func testWildcardUsesSchemaCommentsAndKeepsActualResultTypes() {
        let result = QueryResult(columns: ["ID", "NAME"], columnMetadata: [.init(type: "NUMBER(10)"), .init(type: "VARCHAR2(80)")])
            .withColumnMetadata(sql: "SELECT * FROM CUSTOMERS", tables: tables, kind: .oracle)
        XCTAssertEqual(result.columnTooltip(at: 0), "ID NUMBER(10)\n고객 식별자")
        XCTAssertEqual(result.columnTooltip(at: 1), "NAME VARCHAR2(80)\n고객 이름\n화면에 표시됩니다.")
    }

    func testAliasedJoinColumnsUseTheirOwnSourceEvenWithDuplicateLabels() {
        let result = QueryResult(columns: ["IDENTIFIER", "IDENTIFIER", "NAME"])
            .withColumnMetadata(sql: "SELECT c.id AS identifier, o.id identifier, c.name FROM customers c JOIN orders o ON o.customer_id = c.id", tables: tables, kind: .oracle)
        XCTAssertEqual(result.columnMetadata?.map(\.comment), ["고객 식별자", "주문 식별자", "고객 이름\n화면에 표시됩니다."])
    }

    func testLiteralsExpressionsAndAmbiguousNamesNeverBorrowAComment() {
        let sql = "SELECT 'literal' ID, q'{x}' AS NAME, c.id + 1 AS ID, COUNT(*) AS ID, id FROM customers c JOIN orders o ON c.id = o.customer_id"
        let result = QueryResult(columns: ["ID", "NAME", "ID", "ID", "ID"], columnMetadata: Array(repeating: .init(type: "NUMBER"), count: 5))
            .withColumnMetadata(sql: sql, tables: tables, kind: .oracle)
        XCTAssertEqual(result.columnMetadata?.map(\.comment), [nil, nil, nil, nil, nil])
        XCTAssertEqual(result.columnTooltip(at: 3), "ID NUMBER")
        let literal = QueryResult(columns: ["ID"]).withColumnMetadata(sql: "SELECT 'literal' ID FROM customers", tables: tables, kind: .oracle)
        XCTAssertNil(literal.columnMetadata?[0].comment)
    }

    func testQuotedIdentifiersCommentsAndQualifiedWildcard() {
        let schema = [SchemaTable(name: "Mixed table", columns: [SchemaColumn(name: "User name", type: "TEXT", comment: "표시 이름")])]
        let result = QueryResult(columns: ["User name"])
            .withColumnMetadata(sql: "SELECT /* 'ignored' */ \"c\".* FROM \"Mixed table\" \"c\"", tables: schema, kind: .oracle)
        XCTAssertEqual(result.columnTooltip(at: 0), "User name TEXT\n표시 이름")
        let aliased = QueryResult(columns: ["name"]).withColumnMetadata(sql: "SELECT \"c\".\"User name\" AS \"name\" FROM \"Mixed table\" \"c\"", tables: schema, kind: .oracle)
        XCTAssertEqual(aliased.columnTooltip(at: 0), "name TEXT\n표시 이름")
    }

    func testUnknownOwnersCTEsDerivedTablesAndSetOperationsHaveNoGuessedComments() {
        for sql in [
            "SELECT id FROM other.customers",
            "SELECT id FROM customers@other",
            "SELECT id FROM (SELECT id FROM customers)",
            "WITH customers AS (SELECT id FROM orders) SELECT id FROM customers",
            "SELECT id FROM customers UNION ALL SELECT id FROM orders",
            "SELECT id FROM customers c JOIN unknown_table u ON c.id=u.id"
        ] {
            let result = QueryResult(columns: ["ID"], columnMetadata: [.init(type: "NUMBER")])
                .withColumnMetadata(sql: sql, tables: tables, kind: .oracle, defaultSchema: "APP")
            XCTAssertEqual(result.columnTooltip(at: 0), "ID NUMBER", sql)
        }
        let known = QueryResult(columns: ["ID"]).withColumnMetadata(sql: "SELECT c.id FROM app.customers c", tables: tables, kind: .oracle, defaultSchema: "app")
        XCTAssertEqual(known.columnMetadata?[0].comment, "고객 식별자")
    }

    func testWildcardMetadataDoesNotMisalignAfterSchemaChanges() {
        let result = QueryResult(columns: ["NAME", "ID"]).withColumnMetadata(sql: "SELECT * FROM customers", tables: tables, kind: .oracle)
        XCTAssertEqual(result.columnMetadata?.map(\.comment), [nil, nil])
    }

    func testOlderBridgePayloadAndMissingMetadataRemainCompatible() throws {
        let payload = #"{"columns":["ID"],"rows":[["1"]],"affected":0,"elapsed":0,"truncated":false,"message":"Query completed"}"#
        let result = try JSONDecoder().decode(QueryResult.self, from: Data(payload.utf8))
        XCTAssertNil(result.columnMetadata)
        XCTAssertEqual(result.columnTooltip(at: 0), "ID")
        XCTAssertEqual(result.columnTooltip(at: -1), "")
        var typed = result
        typed.columnMetadata = [.init(type: " NUMBER ", comment: " \n ")]
        XCTAssertEqual(typed.columnTooltip(at: 0), "ID NUMBER")
        let restored = try JSONDecoder().decode(QueryResult.self, from: JSONEncoder().encode(typed))
        XCTAssertEqual(restored.columnMetadata, typed.columnMetadata)
    }

    func testSQLiteDeclaredTypesSurviveAliasesJoinsAndEmptyResults() async throws {
        let database = try SQLiteDatabase(path: ":memory:")
        _ = try await database.execute("CREATE TABLE customers (id INTEGER, name VARCHAR(80)); CREATE TABLE orders (id TEXT)")
        let result = try await database.execute("SELECT c.name AS label, o.id FROM customers c JOIN orders o ON 1=1")
        XCTAssertEqual(result.columns, ["label", "id"])
        XCTAssertTrue(result.rows.isEmpty)
        XCTAssertEqual(result.columnMetadata?.map(\.type), ["VARCHAR(80)", "TEXT"])
        let expression = try await database.execute("SELECT 1 AS id")
        XCTAssertEqual(expression.columnTooltip(at: 0), "id")
    }
}
