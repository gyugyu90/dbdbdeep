import XCTest
@testable import DBDeepCore

final class MongoDatabaseTests: XCTestCase {
    func testSettingsRoundTripAndLegacyDefaults() throws {
        let profile = DBConnection(name: "Atlas", kind: .mongodb, host: "cluster.example.com", port: 27017, service: "catalog", username: "reader", mongoAuthSource: "admin", mongoTLS: true, mongoSRV: true, mongoReplicaSet: "rs0")
        let restored = try JSONDecoder().decode(DBConnection.self, from: JSONEncoder().encode(profile))
        XCTAssertEqual(restored, profile)
        XCTAssertEqual(profile.dialect, "MongoDB")
        XCTAssertFalse(profile.supportsTransactions)
        XCTAssertTrue(profile.needsPassword)
        XCTAssertEqual(profile.mongoURI, "mongodb+srv://cluster.example.com/catalog?tls=true&authSource=admin&replicaSet=rs0")
        XCTAssertNil(profile.configurationError)
        let legacy = DBConnection(name: "Existing Oracle")
        XCTAssertTrue(legacy.supportsTransactions)
    }

    func testSettingsValidateHostDatabaseAuthAndSRV() {
        var profile = DBConnection(name: "Local", kind: .mongodb, port: 27017, service: "test")
        XCTAssertFalse(profile.needsPassword)
        XCTAssertEqual(profile.mongoURI, "mongodb://localhost:27017/test?tls=false")
        profile.host = "::1"
        XCTAssertEqual(profile.mongoURI, "mongodb://[::1]:27017/test?tls=false")
        profile.mongoSRV = true
        XCTAssertNotNil(profile.configurationError)
        profile.host = "mongodb://user:secret@localhost"
        XCTAssertNotNil(profile.configurationError)
        profile.host = "cluster.example.com"
        profile.service = "bad/name"
        XCTAssertNotNil(profile.configurationError)
        profile.service = "test"
        profile.username = "user"
        profile.mongoAuthSource = ""
        XCTAssertNil(profile.configurationError)
        XCTAssertEqual(profile.effectiveMongoAuthSource, "test")
    }

    func testJSONCommandsRespectEscapesCaseAndCursorBoundaries() throws {
        let language = QueryLanguage(.mongodb)
        let first = #"{"find":"한글🌱","filter":{"text":"brace } ; \\\" quote","a":[1,2]}}"#
        let second = #"{"ping":1}"#
        let text = first + ";\n\n" + second
        XCTAssertEqual(language.statements(in: text).map(\.text), [first, second])
        XCTAssertEqual(language.statementAtOrBefore(in: text, atUTF16Offset: first.utf16.count + 1)?.text, first)
        XCTAssertEqual(language.statementAtOrBefore(in: text, atUTF16Offset: text.utf16.count)?.text, second)
        XCTAssertNil(language.singleStatement(in: text))
        XCTAssertNil(language.singleStatement(in: "{}"))
        XCTAssertNil(language.singleStatement(in: "SELECT * FROM customers"))
        XCTAssertNil(language.singleStatement(in: #"{"find":"customers"} garbage"#))
        XCTAssertNil(language.statementAtOrBefore(in: first + "\n{\"ping\":", atUTF16Offset: first.utf16.count + 9))
        XCTAssertEqual(language.comparisonKey(for: #"{ "find" : "Name" }"#), language.comparisonKey(for: #"{"find":"Name"}"#))
        XCTAssertNotEqual(language.comparisonKey(for: #"{"find":"Name"}"#), language.comparisonKey(for: #"{"find":"name"}"#))
        let focus = try SavedQueryFocus.resolve(bookmarkSQL: second, in: first, cursor: 0, kind: .mongodb)
        XCTAssertEqual(focus.sql, first + "\n\n" + second)
        XCTAssertEqual(language.singleStatement(in: language.statementAtOrBefore(in: focus.sql, atUTF16Offset: focus.range.location)!.text)?.text, second)
        XCTAssertEqual(language.singleStatement(in: QueryLanguage.browseCollection("a\"b🌱"))?.text, QueryLanguage.browseCollection("a\"b🌱"))
    }

    func testMultiHostURIImportsDatabaseAndAuthenticationSource() throws {
        let imported = try MongoConnectionURI("mongodb://192.0.2.67:27017,192.0.2.68:27017,192.0.2.69:27017/app?authSource=app")
        XCTAssertEqual(imported.host, "192.0.2.67:27017,192.0.2.68:27017,192.0.2.69:27017")
        XCTAssertEqual(imported.database, "app")
        XCTAssertEqual(imported.authSource, "app")
        XCTAssertFalse(imported.srv)
        XCTAssertFalse(imported.tls)
        let profile = DBConnection(name: "Replica", kind: .mongodb, host: imported.host, port: imported.port, service: imported.database, mongoAuthSource: imported.authSource)
        XCTAssertNil(profile.configurationError)
        XCTAssertEqual(profile.mongoURI, "mongodb://192.0.2.67:27017,192.0.2.68:27017,192.0.2.69:27017/app?tls=false&authSource=app")
    }

    func testMongoSeedPortsIPv6AndAuthenticationDefaults() throws {
        var profile = DBConnection(name: "Replica", kind: .mongodb, host: "one:27018, two, [::1]:27019", port: 27020, service: "app", username: "reader")
        XCTAssertNil(profile.configurationError)
        XCTAssertEqual(profile.mongoURI, "mongodb://one:27018,two:27020,[::1]:27019/app?tls=false")
        XCTAssertEqual(profile.effectiveMongoAuthSource, "app")
        profile.service = ""
        XCTAssertEqual(profile.effectiveMongoAuthSource, "admin")
        profile.service = "app"
        for host in ["one,,two", "one:abc", "one:0", "[::1", "one:65536"] {
            profile.host = host
            XCTAssertNotNil(profile.configurationError)
        }
        XCTAssertThrowsError(try MongoConnectionURI("mongodb+srv://one,two/app"))
        XCTAssertThrowsError(try MongoConnectionURI("mongodb+srv://one:27017/app"))
    }

    func testURIImportPreservesCredentialsWithoutPuttingThemInSavedURI() throws {
        let imported = try MongoConnectionURI("mongodb://user:p%40ss%3Aword@[::1]:27018/app?authSource=auth%20db&tls=true&replicaSet=rs0")
        XCTAssertEqual(imported.host, "[::1]")
        XCTAssertEqual(imported.port, 27018)
        XCTAssertEqual(imported.username, "user")
        XCTAssertEqual(imported.password, "p@ss:word")
        XCTAssertEqual(imported.authSource, "auth db")
        XCTAssertTrue(imported.tls)
        let profile = DBConnection(name: "Imported", kind: .mongodb, host: imported.host, port: imported.port, service: imported.database, username: imported.username!, mongoAuthSource: imported.authSource, mongoTLS: imported.tls, mongoReplicaSet: imported.replicaSet)
        XCTAssertFalse(profile.mongoURI.contains("user"))
        XCTAssertFalse(profile.mongoURI.contains("p%40ss"))
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(profile), as: UTF8.self).contains("p@ss:word"))
        XCTAssertEqual(try MongoConnectionURI("mongodb://localhost/app").authSource, "")
        XCTAssertEqual(try MongoConnectionURI("mongodb+srv://cluster.example.com/app").tls, true)
        XCTAssertThrowsError(try MongoConnectionURI("mongodb://localhost/app?unsupported=value"))
        XCTAssertThrowsError(try MongoConnectionURI("mongodb://localhost/app?tls=true&ssl=false"))
        XCTAssertThrowsError(try MongoConnectionURI("mongodb://localhost/app?tls=invalid"))
    }

    func testMongoDiagnosticsUseMongoSettingsAndHints() {
        let profile = DBConnection(name: "Mongo", kind: .mongodb, port: 27017, service: "catalog", username: "reader", mongoAuthSource: "admin")
        let failure = OracleConnectionFailure(message: "Authentication failed", errorCode: 18, stage: .connecting)
        var attempt = ConnectionAttempt(connection: profile, purpose: "Test")
        attempt.finish(.failed, failure: failure)
        XCTAssertTrue(attempt.report.contains("MongoDB URI"))
        XCTAssertTrue(attempt.report.contains("Authentication DB: admin"))
        XCTAssertFalse(attempt.report.contains("JDBC"))
        XCTAssertFalse(attempt.report.contains("DUAL"))
        XCTAssertTrue(failure.suggestion(for: profile).contains("authSource"))
    }

    func testMissingMongoRuntimeFailsBeforeConnecting() async {
        let runtime = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let database = MongoDatabase(connection: DBConnection(name: "Mongo", kind: .mongodb, port: 27017, service: "test"), runtime: runtime)
        do {
            try await database.connect(password: "private-test-value")
            XCTFail("Missing runtime must fail.")
        } catch let failure as OracleConnectionFailure {
            XCTAssertEqual(failure.stage, .runtime)
            XCTAssertTrue(failure.message.contains("MongoDB"))
            XCTAssertFalse(failure.message.contains("private-test-value"))
        } catch { XCTFail("Expected a structured runtime failure: \(error)") }
    }

    func testLiveMongoCRUDSchemaCursorAndAuthentication() async throws {
        guard let port = ProcessInfo.processInfo.environment["DBDBDEEP_MONGO_TEST_PORT"].flatMap(Int.init) else {
            throw XCTSkip("Set DBDBDEEP_MONGO_TEST_PORT to an isolated MongoDB test server port.")
        }
        let runtime = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".oracle")
        let databaseName = "dbdbdeep_test_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let profile = DBConnection(name: "Integration", kind: .mongodb, host: "127.0.0.1", port: port, service: databaseName)
        let database = MongoDatabase(connection: profile, runtime: runtime)
        try await database.connect(password: "")
        do {
            let inserted = try await database.execute(#"{"insert":"items","documents":[{"name":"한글 🌱","nested":{"x":1}},{"name":"second","extra":true}]}"#)
            XCTAssertEqual(inserted.affected, 2)
            let schema = try await database.schema()
            XCTAssertEqual(schema.map(\.name), ["items"])
            let fields = try await database.collectionFields("items")
            XCTAssertTrue(fields.contains { $0.name == "name" && $0.type == "STRING" })
            XCTAssertTrue(fields.contains { $0.name == "nested.x" && $0.type == "INT32" })
            XCTAssertTrue(fields.contains { $0.name == "extra" && $0.type == "BOOLEAN" })
            let cachedFields = try await database.collectionFields("items")
            XCTAssertEqual(cachedFields, fields)
            let sampledSchema = try await database.schema()
            XCTAssertTrue(sampledSchema.first?.columns.contains { $0.name == "nested.x" } == true)
            let found = try await database.execute(#"{"find":"items","filter":{},"sort":{"name":-1}}"#)
            XCTAssertEqual(found.rows.count, 2)
            XCTAssertTrue(found.columns.contains("nested"))
            XCTAssertTrue(found.rows.flatMap { $0 }.contains("한글 🌱"))
            XCTAssertEqual(found.documents?.count, found.rows.count)
            let originalDocuments = try XCTUnwrap(found.documents).map { try DocumentValue(json: $0) }
            XCTAssertTrue(originalDocuments.contains { $0.children.contains { $0.name == "nested" && $0.value.kind == .object } })
            XCTAssertTrue(originalDocuments.contains { !$0.children.contains { $0.name == "nested" } })
            let shell = try await database.execute("db.items.find({name: 'second'}, {_id: 0, name: 1}).sort({name: 1}).limit(1)")
            XCTAssertEqual(shell.columns, ["name"])
            XCTAssertEqual(shell.rows, [["second"]])
            let chained = try await database.execute("db.getCollection('items').find({}).sort({name: 1}).skip(1).limit(1).toArray()")
            XCTAssertTrue(chained.rows.flatMap { $0 }.contains("한글 🌱"))
            let idIndex = try XCTUnwrap(found.columns.firstIndex(of: "_id"))
            let idJSON = try XCTUnwrap(found.rows[0][idIndex])
            let id = try XCTUnwrap((try JSONSerialization.jsonObject(with: Data(idJSON.utf8)) as? [String: String])?["$oid"])
            let byID = try await database.execute("db.items.findOne({_id: ObjectId('\(id)')})")
            XCTAssertEqual(byID.rows.count, 1)
            let regex = try await database.execute("db.items.find({name: /한글/})")
            XCTAssertEqual(regex.rows.count, 1)
            let updated = try await database.execute(#"{"update":"items","updates":[{"q":{"name":"second"},"u":{"$set":{"name":"updated"}}}]}"#)
            XCTAssertEqual(updated.affected, 1)
            let removed = try await database.execute(#"{"delete":"items","deletes":[{"q":{"name":"updated"},"limit":1}]}"#)
            XCTAssertEqual(removed.affected, 1)
            let aggregation = try await database.execute(#"{"aggregate":"items","pipeline":[{"$match":{}}],"cursor":{}}"#)
            XCTAssertEqual(aggregation.rows.count, 1)
            let longText = String(repeating: "x", count: 20_000)
            _ = try await database.execute("{\"insert\":\"typed\",\"documents\":[{\"precise\":{\"$numberLong\":\"9223372036854775807\"},\"longText\":\"" + longText + "\"}]}")
            let typed = try await database.execute("db.typed.find({})")
            let originalTyped = try DocumentValue(json: XCTUnwrap(typed.documents?.first))
            XCTAssertEqual(originalTyped.children.first { $0.name == "precise" }?.value.displayValue, "9223372036854775807")
            XCTAssertEqual(originalTyped.children.first { $0.name == "longText" }?.value.copyText, longText)
            let textColumn = try XCTUnwrap(typed.columns.firstIndex(of: "longText"))
            XCTAssertLessThan(try XCTUnwrap(typed.rows[0][textColumn]).count, longText.count)
            let documents = (0..<1005).map { "{\"n\":\($0)}" }.joined(separator: ",")
            _ = try await database.execute("{\"insert\":\"many\",\"documents\":[" + documents + "]}")
            let many = try await database.execute(#"{"find":"many","filter":{},"batchSize":7}"#)
            XCTAssertEqual(many.rows.count, 1000)
            XCTAssertTrue(many.truncated)
            let limited = try await database.execute(#"{"find":"many","filter":{},"limit":2}"#)
            XCTAssertEqual(limited.rows.count, 2)
            XCTAssertFalse(limited.truncated)
            _ = try await database.execute(#"{"insert":"items","documents":[{"_id":1}]}"#)
            do {
                _ = try await database.execute(#"{"insert":"items","documents":[{"_id":1}]}"#)
                XCTFail("Duplicate key must surface as a write error.")
            } catch { XCTAssertTrue(error.localizedDescription.contains("write error")) }
            try await database.validateConnection()
            _ = try await database.execute(#"{"createUser":"integration","pwd":"local-test-secret","roles":["readWrite"]}"#)
            var authenticated = profile
            authenticated.username = "integration"
            authenticated.mongoAuthSource = databaseName
            let auth = MongoDatabase(connection: authenticated, runtime: runtime)
            try await auth.connect(password: "local-test-secret")
            try await auth.validateConnection()
            await auth.disconnect()
            authenticated.mongoAuthSource = ""
            let defaultAuth = MongoDatabase(connection: authenticated, runtime: runtime)
            try await defaultAuth.connect(password: "local-test-secret")
            try await defaultAuth.validateConnection()
            await defaultAuth.disconnect()
            let wrong = MongoDatabase(connection: authenticated, runtime: runtime)
            do {
                try await wrong.connect(password: "wrong-local-secret")
                XCTFail("Wrong password must fail.")
            } catch {
                XCTAssertFalse(error.localizedDescription.contains("wrong-local-secret"))
            }
            _ = try await database.execute(#"{"dropUser":"integration"}"#)
            _ = try await database.execute(#"{"dropDatabase":1}"#)
            await database.disconnect()
        } catch {
            _ = try? await database.execute(#"{"dropUser":"integration"}"#)
            _ = try? await database.execute(#"{"dropDatabase":1}"#)
            await database.disconnect()
            throw error
        }
    }
}
