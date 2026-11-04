import XCTest
@testable import DBDeepCore

final class MongoShellQueryTests: XCTestCase {
    func testShellAndJSONStatementsUseTheCursorAndPreserveUTF16Ranges() throws {
        let first = "db.getCollection('고객🌱').find({name: 'a ; ) \\\' b'}).sort({name: -1}).limit(10)"
        let second = #"{"ping":1}"#
        let third = "db.items.find({nested: {$in: ['a', 'b']}})"
        let text = first + ";\n\n" + second + "\n" + third
        let language = QueryLanguage(.mongodb)
        let statements = language.statements(in: text)
        XCTAssertEqual(statements.map(\.text), [first, second, third])
        XCTAssertEqual(statements.map { (text as NSString).substring(with: $0.range) }, [first, second, third])
        XCTAssertEqual(language.statementAtOrBefore(in: text, atUTF16Offset: first.utf16.count + 1)?.text, first)
        XCTAssertEqual(language.statementAtOrBefore(in: text, atUTF16Offset: text.utf16.count)?.text, third)
        XCTAssertNil(language.singleStatement(in: text))
        XCTAssertEqual(language.singleStatement(in: first + "; // trailing comment")?.text, first)
    }

    func testRegexCommentsBSONConstructorsAndMultilineChaining() {
        let query = """
        // Pick a customer
        db.customers.find({
          name: /a[{}()\\/]b/i,
          _id: ObjectId('507f1f77bcf86cd799439011'),
          created: ISODate('2026-01-01T00:00:00Z')
        }) /* query comment */
          .sort({name: -1})
          .skip(2)
          .limit(10);
        """
        let statement = MongoQueryDocument.singleStatement(in: query)
        XCTAssertNotNil(statement)
        XCTAssertTrue(statement?.text.hasSuffix(".limit(10)") == true)
        let language = QueryLanguage(.mongodb)
        XCTAssertEqual(language.comparisonKey(for: "db.items.find({name: 'hello world'})"),
                       language.comparisonKey(for: "db . items . find( { name : 'hello world' } )"))
        XCTAssertNotEqual(language.comparisonKey(for: "db.items.find({name: 'hello world'})"),
                          language.comparisonKey(for: "db.items.find({name: 'helloworld'})"))
        XCTAssertNotEqual(language.comparisonKey(for: "db.items.find({name: /hello world/})"),
                          language.comparisonKey(for: "db.items.find({name: /helloworld/})"))
    }

    func testIncompleteOrTrailingCodeNeverSelectsAnEarlierQuery() {
        let prefix = "db.items.find({});\n"
        for unfinished in ["db.items.find({", "db.items.find({name:'unfinished})", "db.items.find({}).", "db.items.find({}) + other()", "db.items.find({name:/unfinished})"] {
            XCTAssertNil(MongoQueryDocument.singleStatement(in: unfinished), unfinished)
            let text = prefix + unfinished
            XCTAssertNil(QueryLanguage(.mongodb).statementAtOrBefore(in: text, atUTF16Offset: text.utf16.count), unfinished)
        }
        XCTAssertNil(MongoQueryDocument.singleStatement(in: "const x = db.items.find({})"))
        XCTAssertNil(MongoQueryDocument.singleStatement(in: "db.items.find({}]"))
    }

    func testShellBookmarksAppendAndFocusWithoutReplacingOtherCommands() throws {
        let saved = "db.items.find({name: 'Hello 🌱'}).limit(10)"
        let existing = #"{"ping":1}"#
        let added = try SavedQueryFocus.resolve(bookmarkSQL: saved, in: existing, cursor: 0, kind: .mongodb)
        XCTAssertEqual(added.sql, existing + "\n\n" + saved)
        XCTAssertEqual((added.sql as NSString).substring(with: added.range), saved)
        let focused = try SavedQueryFocus.resolve(bookmarkSQL: saved, in: added.sql, cursor: 0, kind: .mongodb)
        XCTAssertEqual(focused.sql, added.sql)
        XCTAssertEqual(focused.range, added.range)
        XCTAssertEqual(QueryLanguage.browseCollection("a'b\"🌱"), #"db.getCollection("a'b\"🌱").find({}).limit(100)"#)
    }
}
