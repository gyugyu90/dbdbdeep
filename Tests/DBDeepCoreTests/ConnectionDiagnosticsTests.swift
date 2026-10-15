import XCTest
@testable import DBDeepCore

final class ConnectionDiagnosticsTests: XCTestCase {
    func testJDBCURLUsesSelectedConnectionMode() {
        var profile = DBConnection(name: "Dev", host: "db.example.com", port: 1528, service: "APPDB", username: "app")
        XCTAssertEqual(profile.jdbcURL, "jdbc:oracle:thin:@//db.example.com:1528/APPDB")
        profile.usesSID = true
        XCTAssertEqual(profile.jdbcURL, "jdbc:oracle:thin:@db.example.com:1528:APPDB")
        profile.host = "::1"
        XCTAssertEqual(profile.jdbcURL, "jdbc:oracle:thin:@[::1]:1528:APPDB")
    }

    func testBridgeProgressFrame() throws {
        let payload = Data(#"{"event":{"stage":"connecting","level":"info","message":"Connecting to listener"}}"#.utf8)
        guard case .event(let event) = try OracleBridgeFrame.decode(payload) else { return XCTFail("Expected progress frame") }
        XCTAssertEqual(event.stage, .connecting)
        XCTAssertEqual(event.message, "Connecting to listener")
        XCTAssertEqual(event.level, .info)
    }

    func testBridgeFailurePreservesNestedCauseAndOracleCode() throws {
        let payload = Data(#"{"error":"ORA-12541: No listener","details":["java.sql.SQLException: ORA-12541","java.net.ConnectException: Connection refused"],"errorCode":12541,"sqlState":"08006","stage":"connecting"}"#.utf8)
        guard case .failure(let failure) = try OracleBridgeFrame.decode(payload) else { return XCTFail("Expected structured failure") }
        XCTAssertEqual(failure.stage, .connecting)
        XCTAssertEqual(failure.errorCode, 12541)
        XCTAssertEqual(failure.sqlState, "08006")
        XCTAssertEqual(failure.details.count, 2)
        XCTAssertEqual(failure.oracleCode, "ORA-12541")
        XCTAssertEqual(failure.documentationURL?.absoluteString, "https://docs.oracle.com/en/error-help/db/ora-12541/")
        XCTAssertTrue(failure.suggestion.contains("리스너"))
    }

    func testLegacyResultAndFailureFramesStillDecode() throws {
        let error = Data(#"{"error":"Connection failed"}"#.utf8)
        guard case .failure(let failure) = try OracleBridgeFrame.decode(error) else { return XCTFail() }
        XCTAssertTrue(failure.details.isEmpty)
        let output = try JSONEncoder().encode(QueryResult(columns: ["CHECK"], rows: [["1"]]))
        guard case .result(let result) = try OracleBridgeFrame.decode(output) else { return XCTFail() }
        XCTAssertEqual(result.rows, [["1"]])
    }

    func testPasswordRedactionIncludesNestedFailuresAndCopiedReport() {
        let secret = "private-password-42"
        let failure = OracleConnectionFailure(message: "Failed with \(secret)", details: ["Nested: \(secret)"], stage: .connecting).redacted(password: secret)
        var attempt = ConnectionAttempt(connection: DBConnection(name: "Dev", username: "app"), purpose: "Test")
        attempt.record(ConnectionEvent(stage: .connecting, level: .error, message: failure.message))
        attempt.finish(.failed, failure: failure)
        XCTAssertFalse(attempt.report.contains(secret))
        XCTAssertTrue(attempt.report.contains("[REDACTED]"))
        XCTAssertFalse(failure.details[0].contains(secret))
        XCTAssertEqual(DiagnosticRedactor.redact("unchanged", password: ""), "unchanged")
    }

    func testAttemptKeepsActualSettingsAndIgnoresLateEvents() {
        let start = Date(timeIntervalSince1970: 1000)
        var profile = DBConnection(name: "Original", host: "original.example.com")
        var attempt = ConnectionAttempt(connection: profile, purpose: "Test", startedAt: start)
        profile.host = "edited.example.com"
        attempt.record(ConnectionEvent(stage: .driver, level: .success, message: "Loaded", date: start.addingTimeInterval(1)))
        attempt.finish(.failed, date: start.addingTimeInterval(2))
        attempt.record(ConnectionEvent(stage: .session, message: "Late event"))
        XCTAssertEqual(attempt.events.count, 1)
        XCTAssertTrue(attempt.report.contains("original.example.com"))
        XCTAssertFalse(attempt.report.contains("edited.example.com"))
        XCTAssertTrue(attempt.report.contains("+1.000s"))
        XCTAssertTrue(attempt.report.contains("Elapsed: 2.000s"))
    }

    func testHintsDistinguishConnectionModesAndCharsetFailure() {
        XCTAssertTrue(OracleConnectionFailure(message: "ORA-12514: unknown service").suggestion.contains("Service name"))
        XCTAssertTrue(OracleConnectionFailure(message: "ORA-12505: unknown SID").suggestion.contains("SID"))
        XCTAssertTrue(OracleConnectionFailure(message: "ORA-17056: KO16MSWIN949", stage: .verification).suggestion.contains("orai18n.jar"))
        XCTAssertTrue(OracleConnectionFailure(message: "Failed", details: ["java.net.UnknownHostException: db.invalid"]).suggestion.contains("DNS"))
        XCTAssertTrue(OracleConnectionFailure(message: "Failed", stage: .schema).suggestion.contains("접속과 확인 쿼리는 성공"))
    }

    func testMissingRuntimeReportsFailureBeforeNetworkConnection() async throws {
        let recorder = EventRecorder()
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let database = OracleDatabase(connection: DBConnection(name: "Missing runtime"), runtime: missing)
        do {
            try await database.connect(password: "secret-for-test") { event in await recorder.append(event) }
            XCTFail("Missing runtime must fail")
        } catch let failure as OracleConnectionFailure {
            XCTAssertEqual(failure.stage, .runtime)
            XCTAssertTrue(failure.details.contains { $0.contains(missing.path) })
            XCTAssertFalse(failure.localizedDescription.contains("secret-for-test"))
        }
        let events = await recorder.events
        XCTAssertEqual(events.map(\.stage), [.runtime])
    }

    func testDriverLibrariesAreSelectedPerConnection() {
        let runtime = URL(fileURLWithPath: "/bundle/Oracle")
        var profile = DBConnection(name: "Standard", usesBundledInternationalization: false)
        XCTAssertEqual(OracleDriverLibraries.resolve(connection: profile, runtime: runtime).map(\.lastPathComponent), ["ojdbc11.jar"])
        profile.usesBundledInternationalization = true
        profile.additionalJARs = ["/custom/wallet.jar", "/custom/wallet.jar"]
        XCTAssertEqual(OracleDriverLibraries.resolve(connection: profile, runtime: runtime).map(\.lastPathComponent), ["ojdbc11.jar", "orai18n.jar", "wallet.jar"])
        XCTAssertTrue(ConnectionAttempt(connection: profile, purpose: "Test").report.contains("/custom/wallet.jar"))
    }

    func testExistingConnectionProfilesLoadWithoutNewFields() throws {
        let legacy = Data(#"{"id":"00000000-0000-0000-0000-000000000001","name":"Existing","kind":"oracle","host":"localhost","port":1521,"service":"FREEPDB1","username":"app","usesSID":false,"color":"mint"}"#.utf8)
        var profile = try JSONDecoder().decode(DBConnection.self, from: legacy)
        XCTAssertTrue(profile.usesBundledInternationalization)
        XCTAssertTrue(profile.additionalJARs.isEmpty)
        profile.usesBundledInternationalization = false
        profile.additionalJARs = ["/custom/charset.jar"]
        let restored = try JSONDecoder().decode(DBConnection.self, from: JSONEncoder().encode(profile))
        XCTAssertEqual(restored, profile)
    }

    func testMissingAdditionalLibraryNamesTheFile() {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jar")
        XCTAssertThrowsError(try OracleDriverLibraries.validate([file])) { error in
            XCTAssertTrue(error.localizedDescription.contains(file.path))
            XCTAssertEqual((error as? OracleConnectionFailure)?.stage, .driver)
        }
    }

    func testMalformedBridgeFrameFails() {
        XCTAssertThrowsError(try OracleBridgeFrame.decode(Data("{}".utf8)))
    }
}

private actor EventRecorder {
    var events: [ConnectionEvent] = []
    func append(_ event: ConnectionEvent) { events.append(event) }
}
