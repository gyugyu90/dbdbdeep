import XCTest
@testable import DBDeepCore

final class SQLStatementLocatorTests: XCTestCase {
    func testBookmarkTargetUsesPreviousStatementInWhitespaceButNotInsideUnfinishedSQL() {
        let sql = "SELECT '한글 🌷';\n\n\nSELECT '다음';"
        let gap = (sql as NSString).range(of: "\n\n\n").location + 1
        XCTAssertEqual(SQLStatementLocator.statementAtOrBefore(in: sql, atUTF16Offset: gap)?.text, "SELECT '한글 🌷';")
        let unfinished = "SELECT 1; SELECT 'unfinished"
        XCTAssertNil(SQLStatementLocator.statementAtOrBefore(in: unfinished, atUTF16Offset: unfinished.utf16.count))
        XCTAssertNil(SQLStatementLocator.statementAtOrBefore(in: "  SELECT 1;", atUTF16Offset: 0))
        let trailing = "SELECT 1;\n-- trailing note"
        XCTAssertEqual(SQLStatementLocator.statementAtOrBefore(in: trailing, atUTF16Offset: trailing.utf16.count)?.text, "SELECT 1;")
    }

    func testSingleStatementRejectsIncompleteOrMultipleTrailingStatements() {
        for sql in ["SELECT 1; SELECT 2;", "SELECT 1; SELECT 'unfinished", "SELECT 1; /* unfinished", "BEGIN NULL;", "-- comment"] {
            XCTAssertNil(SQLStatementLocator.singleStatement(in: sql), sql)
        }
        for sql in ["SELECT q'[a;b]' FROM dual; -- trailing note", "BEGIN NULL; NULL; END;\n/", "SELECT 1;;"] {
            XCTAssertNotNil(SQLStatementLocator.singleStatement(in: sql), sql)
        }
    }

    func testStatementComparisonIgnoresFormattingCommentsAndFinalDelimiter() {
        XCTAssertEqual(SQLStatementLocator.comparisonKey(for: "-- saved\nSELECT id, name FROM customers;"),
            SQLStatementLocator.comparisonKey(for: " select ID,\n NAME /* format */ from CUSTOMERS "))
        XCTAssertEqual(SQLStatementLocator.comparisonKey(for: "BEGIN NULL; END;\n/"),
            SQLStatementLocator.comparisonKey(for: "begin null; end;"))
    }

    func testStatementComparisonPreservesLiteralValuesAndQuotedIdentifierCase() {
        XCTAssertNotEqual(SQLStatementLocator.comparisonKey(for: "SELECT 'A B';"), SQLStatementLocator.comparisonKey(for: "SELECT 'a b';"))
        XCTAssertNotEqual(SQLStatementLocator.comparisonKey(for: "SELECT \"Name\" FROM customers;"), SQLStatementLocator.comparisonKey(for: "SELECT \"NAME\" FROM customers;"))
        XCTAssertNotEqual(SQLStatementLocator.comparisonKey(for: "SELECT a b;"), SQLStatementLocator.comparisonKey(for: "SELECT ab;"))
        XCTAssertNil(SQLStatementLocator.comparisonKey(for: "SELECT 1; SELECT 2;"))
    }

    func testCursorChoosesOnlyContainingStatement() {
        let sql = "SELECT 1 FROM dual;\n\nUPDATE notes\nSET content = 'hello';\n\nDELETE FROM notes;"
        assertStatement(sql, containing: "content", equals: "UPDATE notes\nSET content = 'hello';")
        assertStatement(sql, containing: "DELETE", equals: "DELETE FROM notes;")
        XCTAssertEqual(SQLStatementLocator.statements(in: sql).count, 3)
    }

    func testStringsQuotedIdentifiersAndCommentsDoNotSplitStatements() {
        let first = "-- heading;\nSELECT 'it''s; safe', \"semi;column\" FROM dual;"
        let second = "/* another; heading */\nSELECT 2 FROM dual;"
        let sql = first + "\n\n" + second
        XCTAssertEqual(SQLStatementLocator.statements(in: sql).map(\.text), [first, second])
        assertStatement(sql, containing: "safe", equals: first)
    }

    func testOracleAlternativeQuotesKeepInternalSemicolonsAndQuotes() {
        for literal in ["q'[it's; safe]'", "Q'{it's; safe}'", "q'(it's; safe)'", "q'<it's; safe>'", "q'#it's; safe#'", "nq'[한글'; safe]'"] {
            let first = "SELECT \(literal) FROM dual;"
            let sql = first + "\nSELECT 2 FROM dual;"
            XCTAssertEqual(SQLStatementLocator.statements(in: sql).map(\.text), [first, "SELECT 2 FROM dual;"])
        }
    }

    func testNestedPLSQLBlockRemainsOneStatement() {
        let block = """
        DECLARE
            value NUMBER := 0;
        BEGIN
            FOR i IN 1..2 LOOP
                IF i > 0 THEN
                    value := CASE WHEN i = 1 THEN 1 ELSE 2 END;
                    BEGIN NULL; END;
                END IF;
            END LOOP;
        END;
        """
        let sql = block + "\nSELECT 2 FROM dual;"
        assertStatement(sql, containing: "value :=", equals: block)
        XCTAssertEqual(SQLStatementLocator.statements(in: sql).map(\.text), [block, "SELECT 2 FROM dual;"])
    }

    func testDeclareWithLocalRoutineAndForwardDeclaration() {
        let block = "DECLARE PROCEDURE p; PROCEDURE p IS BEGIN NULL; END; BEGIN p; END;"
        let sql = block + " SELECT 2 FROM dual;"
        assertStatement(sql, containing: "NULL", equals: block)
        XCTAssertEqual(SQLStatementLocator.statements(in: sql).count, 2)
    }

    func testStoredFunctionWithoutSlashDoesNotConsumeNextQuery() {
        let block = "CREATE OR REPLACE FUNCTION f RETURN NUMBER AS value NUMBER := 1; BEGIN RETURN value; END f;"
        let sql = block + "\nSELECT f FROM dual;"
        assertStatement(sql, containing: "RETURN value", equals: block)
        assertStatement(sql, containing: "SELECT f", equals: "SELECT f FROM dual;")
    }

    func testPackageBodyAndSlashDelimiterStayTogether() {
        let block = """
        CREATE OR REPLACE PACKAGE BODY example AS
            FUNCTION f RETURN NUMBER IS
            BEGIN RETURN 1; END f;
            PROCEDURE p IS
            BEGIN NULL; END p;
        BEGIN p;
        END example;
        """
        let sql = block + "\n/\nSELECT 3 FROM dual;"
        assertStatement(sql, containing: "RETURN 1", equals: block)
        assertStatement(sql, containing: "/", equals: block)
        XCTAssertEqual(SQLStatementLocator.statements(in: sql).count, 2)
    }

    func testPackageSpecificationAndTypeSpecification() {
        let package = "CREATE PACKAGE example AS PROCEDURE p; FUNCTION f RETURN NUMBER; END example;"
        let type = "CREATE TYPE example_type AS OBJECT (value NUMBER);"
        XCTAssertEqual(SQLStatementLocator.statements(in: package + "\n/\n" + type).map(\.text), [package, type])
    }

    func testSQLiteTransactionCommandsStaySeparate() {
        let sql = "BEGIN TRANSACTION; SELECT 1; COMMIT; BEGIN; SELECT 2; ROLLBACK;"
        XCTAssertEqual(SQLStatementLocator.statements(in: sql).map(\.text), ["BEGIN TRANSACTION;", "SELECT 1;", "COMMIT;", "BEGIN;", "SELECT 2;", "ROLLBACK;"])
    }

    func testSQLiteTriggerWithSeveralBodyStatements() {
        let trigger = "CREATE TRIGGER IF NOT EXISTS audit AFTER INSERT ON notes BEGIN INSERT INTO log VALUES ('a;'); INSERT INTO log VALUES ('b'); END;"
        let sql = trigger + "\nSELECT * FROM notes;"
        assertStatement(sql, containing: "VALUES ('b')", equals: trigger)
        XCTAssertEqual(SQLStatementLocator.statements(in: sql).count, 2)
    }

    func testSQLDivisionIsNotSlashDelimiter() {
        let sql = "SELECT 10 / 2 FROM dual; SELECT 4 FROM dual;"
        assertStatement(sql, containing: "/", equals: "SELECT 10 / 2 FROM dual;")
    }

    func testCursorAtSemicolonAndImmediatelyAfterItUsesPreviousStatement() {
        let first = "SELECT 1;"
        let sql = first + "\nSELECT 2;"
        XCTAssertEqual(SQLStatementLocator.statement(in: sql, atUTF16Offset: first.utf16.count - 1)?.text, first)
        XCTAssertEqual(SQLStatementLocator.statement(in: sql, atUTF16Offset: first.utf16.count)?.text, first)
        assertStatement(sql, containing: "SELECT 2", equals: "SELECT 2;")
    }

    func testBlankGapHasNoExecutionTargetButIndentationUsesItsLine() {
        let sql = "SELECT 1;\n\n\n    SELECT 2;"
        let gap = (sql as NSString).range(of: "\n\n\n").location + 1
        XCTAssertNil(SQLStatementLocator.statement(in: sql, atUTF16Offset: gap))
        let indentation = (sql as NSString).range(of: "    SELECT").location
        XCTAssertEqual(SQLStatementLocator.statement(in: sql, atUTF16Offset: indentation)?.text, "SELECT 2;")
    }

    func testLeadingAndTrailingWhitespaceResolveToAdjacentStatement() {
        let sql = "\n\n  SELECT 1;\n\n"
        XCTAssertEqual(SQLStatementLocator.statement(in: sql, atUTF16Offset: 0)?.text, "SELECT 1;")
        XCTAssertEqual(SQLStatementLocator.statement(in: sql, atUTF16Offset: sql.utf16.count)?.text, "SELECT 1;")
    }

    func testUTF16CursorWithKoreanAndEmoji() {
        let first = "SELECT '한글 🌷;💜' FROM dual;"
        let second = "SELECT '다음' FROM dual;"
        let sql = first + "\n" + second
        assertStatement(sql, containing: "다음", equals: second)
        let range = SQLStatementLocator.statements(in: sql)[1].range
        XCTAssertEqual((sql as NSString).substring(with: range), second)
        XCTAssertEqual(SQLStatementLocator.statement(in: sql, atUTF16Offset: Int.max)?.text, second)
        XCTAssertEqual(SQLStatementLocator.statement(in: sql, atUTF16Offset: -1)?.text, first)
    }

    func testCommentsOnlyAndIncompleteInputHaveNoTarget() {
        for sql in ["", " \n ", "-- comment;", "/* comment; */", "SELECT 'unfinished; SELECT 2;", "SELECT q'[unfinished;", "SELECT 1 /* unfinished", "BEGIN NULL; SELECT 2;"] {
            XCTAssertNil(SQLStatementLocator.statement(in: sql, atUTF16Offset: 0), sql)
        }
    }

    private func assertStatement(_ sql: String, containing text: String, equals expected: String, file: StaticString = #filePath, line: UInt = #line) {
        let location = (sql as NSString).range(of: text).location
        XCTAssertNotEqual(location, NSNotFound, file: file, line: line)
        XCTAssertEqual(SQLStatementLocator.statement(in: sql, atUTF16Offset: location)?.text, expected, file: file, line: line)
    }
}
