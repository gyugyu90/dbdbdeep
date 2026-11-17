import XCTest
@testable import DBDeepCore

final class OracleSchemaTests: XCTestCase {
    func testColumnCommentsStayWithTheirTableAndKeepUnicodeAndLineBreaks() {
        let tables = QueryResult(rows: [["CUSTOMERS", "TABLE"], ["ORDERS", "TABLE"], ["SUMMARY", "VIEW"]])
        let columns = QueryResult(rows: [
            ["CUSTOMERS", "ID", "NUMBER", "Y", "N", "고객 식별자 🌷"],
            ["CUSTOMERS", "NAME", "VARCHAR2", "N", "Y", "고객 표시 이름\n화면에 노출할 이름입니다."],
            ["ORDERS", "ID", "NUMBER", "Y", "N", "주문 식별자"],
            ["SUMMARY", "TOTAL", "NUMBER", "N", "Y", "주문 합계"]
        ])

        let schema = OracleDatabase.makeSchema(tables: tables, columns: columns)

        XCTAssertEqual(schema.map(\.name), ["CUSTOMERS", "ORDERS", "SUMMARY"])
        XCTAssertEqual(schema[0].columns.map(\.comment), ["고객 식별자 🌷", "고객 표시 이름\n화면에 노출할 이름입니다."])
        XCTAssertTrue(schema[0].columns[0].primaryKey)
        XCTAssertFalse(schema[0].columns[0].nullable)
        XCTAssertEqual(schema[1].columns[0].comment, "주문 식별자")
        XCTAssertTrue(schema[2].isView)
        XCTAssertEqual(schema[2].columns[0].comment, "주문 합계")
    }

    func testColumnsWithoutCommentsAreStillIncluded() {
        let tables = QueryResult(rows: [["ITEMS", "TABLE"]])
        let columns = QueryResult(rows: [["ITEMS", "NAME", "VARCHAR2", "N", "Y", nil]])
        let column = OracleDatabase.makeSchema(tables: tables, columns: columns).first?.columns.first
        XCTAssertEqual(column?.name, "NAME")
        XCTAssertNil(column?.comment)
        XCTAssertEqual(column, SchemaColumn(name: "NAME", type: "VARCHAR2"))
    }

    func testMalformedMetadataDoesNotCrashSchemaLoading() {
        let tables = QueryResult(rows: [[], [nil, "TABLE"], ["ITEMS", "TABLE"]])
        let columns = QueryResult(rows: [[], ["ITEMS"], ["ITEMS", nil, "NUMBER", "N", "Y", "missing name"]])
        let schema = OracleDatabase.makeSchema(tables: tables, columns: columns)
        XCTAssertEqual(schema.map(\.name), ["ITEMS"])
        XCTAssertTrue(schema[0].columns.isEmpty)
    }
}
