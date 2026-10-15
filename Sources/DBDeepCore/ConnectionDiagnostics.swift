import Foundation

public extension DBConnection {
    var jdbcURL: String {
        let address = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        return usesSID
            ? "jdbc:oracle:thin:@\(address):\(port):\(service)"
            : "jdbc:oracle:thin:@//\(address):\(port)/\(service)"
    }
}

public enum OracleDriverLibraries {
    public static func resolve(connection: DBConnection, runtime: URL) -> [URL] {
        var paths = [runtime.appendingPathComponent("ojdbc11.jar")]
        if connection.usesBundledInternationalization { paths.append(runtime.appendingPathComponent("orai18n.jar")) }
        paths += connection.additionalJARs.map { URL(fileURLWithPath: $0) }
        var seen: Set<URL> = []
        return paths.map(\.standardizedFileURL).filter { seen.insert($0).inserted }
    }

    public static func validate(_ libraries: [URL]) throws {
        for library in libraries {
            guard library.pathExtension.lowercased() == "jar", FileManager.default.isReadableFile(atPath: library.path) else {
                throw OracleConnectionFailure(message: "드라이버 라이브러리를 읽을 수 없습니다: \(library.path)", stage: .driver)
            }
            guard !library.path.contains(":") else {
                throw OracleConnectionFailure(message: "JAR 경로에는 ':' 문자를 사용할 수 없습니다: \(library.path)", stage: .driver)
            }
        }
    }
}

public enum ConnectionStage: String, Codable, Sendable {
    case credentials, runtime, driver, connecting, session, verification, schema

    public var title: String {
        switch self {
        case .credentials: return "Credentials"
        case .runtime: return "Runtime"
        case .driver: return "Oracle driver"
        case .connecting: return "Connect & authenticate"
        case .session: return "Database session"
        case .verification: return "Verification query"
        case .schema: return "Schema"
        }
    }
}

public struct ConnectionEvent: Identifiable, Sendable {
    public enum Level: String, Codable, Sendable { case info, success, warning, error }
    public let id = UUID()
    public let date: Date
    public let stage: ConnectionStage
    public let level: Level
    public let message: String

    public init(stage: ConnectionStage, level: Level = .info, message: String, date: Date = Date()) {
        self.stage = stage; self.level = level; self.message = message; self.date = date
    }
}

public struct OracleConnectionFailure: LocalizedError, Sendable, Decodable {
    public let message: String
    public let details: [String]
    public let errorCode: Int?
    public let sqlState: String?
    public let stage: ConnectionStage?
    public var errorDescription: String? { message }

    enum CodingKeys: String, CodingKey { case message = "error", details, errorCode, sqlState, stage }

    public init(message: String, details: [String] = [], errorCode: Int? = nil, sqlState: String? = nil, stage: ConnectionStage? = nil) {
        self.message = message; self.details = details; self.errorCode = errorCode
        self.sqlState = sqlState; self.stage = stage
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        message = try values.decode(String.self, forKey: .message)
        details = try values.decodeIfPresent([String].self, forKey: .details) ?? []
        errorCode = try values.decodeIfPresent(Int.self, forKey: .errorCode)
        sqlState = try values.decodeIfPresent(String.self, forKey: .sqlState)
        stage = try values.decodeIfPresent(ConnectionStage.self, forKey: .stage)
    }

    public var oracleCode: String? {
        guard let range = message.range(of: "ORA-[0-9]{5}", options: .regularExpression) else { return nil }
        return String(message[range])
    }

    public var documentationURL: URL? {
        oracleCode.flatMap { URL(string: "https://docs.oracle.com/en/error-help/db/\($0.lowercased())/") }
    }

    public var suggestion: String {
        let text = ([message] + details).joined(separator: " ").lowercased()
        if oracleCode == "ORA-17056" { return "Oracle 문자 집합 지원 라이브러리가 필요합니다. 연결 설정의 Driver libraries에서 Bundled orai18n.jar를 켜거나 해당 JAR를 추가해 주세요." }
        if stage == .driver { return "연결 설정의 Driver libraries에서 JAR 파일 경로와 읽기 권한을 확인해 주세요. 번들 파일 오류인 경우 앱을 다시 빌드해 주세요." }
        if stage == .runtime { return "번들 런타임 경로와 원본 오류를 확인해 주세요. scripts/build-app.sh로 앱을 다시 빌드할 수 있습니다." }
        if stage == .credentials { return "키체인에서 비밀번호를 가져오지 못했습니다. 연결 창에 비밀번호를 다시 입력해 주세요." }
        if stage == .schema { return "접속과 확인 쿼리는 성공했습니다. 원본 오류에서 스키마 조회 권한이나 세션 상태를 확인해 주세요." }
        if stage == .verification { return "계정 인증 후 확인 쿼리에서 실패했습니다. 원본 오류와 서버의 세션 상태를 확인해 주세요." }
        switch oracleCode {
        case "ORA-12514": return "리스너에 등록된 Service name을 확인해 주세요. SID를 입력한 경우 Connect with를 SID로 바꿔 주세요."
        case "ORA-12505": return "리스너가 해당 SID를 인식하지 못했습니다. 실제 SID를 확인하거나 Service 방식으로 접속해야 하는지 확인해 주세요."
        case "ORA-12541": return "표시된 호스트·포트의 Oracle 리스너를 확인해 주세요. VPN, 포트 접근 권한과 서버의 리스너 실행 상태도 확인할 수 있습니다."
        case "ORA-01017": return "계정·비밀번호와 해당 데이터베이스의 접속 권한을 확인해 주세요. 비밀번호의 대소문자도 구분합니다."
        case "ORA-28000": return "계정이 잠겨 있습니다. 데이터베이스 관리자에게 계정 상태 확인을 요청해 주세요."
        case "ORA-28001": return "비밀번호가 만료되었습니다. 비밀번호를 갱신한 뒤 연결 설정에 다시 입력해 주세요."
        case "ORA-12170", "ORA-12535": return "연결 응답 시간이 초과되었습니다. VPN·방화벽·호스트·포트와 서버 상태를 확인해 주세요."
        default:
            if text.contains("unknownhost") { return "호스트 이름을 해석하지 못했습니다. 주소의 오타, DNS와 VPN 연결을 확인해 주세요." }
            if text.contains("timed out") || text.contains("timeout") { return "응답 시간이 초과되었습니다. VPN·방화벽·호스트·포트와 서버 상태를 확인해 주세요." }
            if text.contains("connection refused") { return "대상 포트가 연결을 거부했습니다. 호스트·포트와 리스너 실행 상태를 확인해 주세요." }
            return "아래 원본 오류와 접속 주소를 함께 확인해 주세요. Service name과 SID는 서로 다른 접속 방식입니다."
        }
    }

    public func redacted(password: String) -> Self {
        Self(message: DiagnosticRedactor.redact(message, password: password),
             details: details.map { DiagnosticRedactor.redact($0, password: password) },
             errorCode: errorCode, sqlState: sqlState, stage: stage)
    }
}

public enum DiagnosticRedactor {
    public static func redact(_ text: String, password: String) -> String {
        guard !password.isEmpty else { return text }
        return text.replacingOccurrences(of: password, with: "[REDACTED]")
    }
}

public struct ConnectionAttempt: Identifiable, Sendable {
    public enum Outcome: Sendable { case running, succeeded, failed, partial }
    public let id = UUID()
    public let connection: DBConnection
    public let purpose: String
    public let startedAt: Date
    public private(set) var finishedAt: Date?
    public private(set) var events: [ConnectionEvent] = []
    public private(set) var outcome: Outcome = .running
    public private(set) var failure: OracleConnectionFailure?

    public init(connection: DBConnection, purpose: String, startedAt: Date = Date()) {
        self.connection = connection; self.purpose = purpose; self.startedAt = startedAt
    }

    public mutating func record(_ event: ConnectionEvent) {
        guard outcome == .running else { return }
        events.append(event)
    }

    public mutating func finish(_ outcome: Outcome, failure: OracleConnectionFailure? = nil, date: Date = Date()) {
        self.outcome = outcome; self.failure = failure; finishedAt = date
    }

    public var report: String {
        let elapsed = (finishedAt ?? Date()).timeIntervalSince(startedAt)
        var lines = [
            "dbdbdeep · \(purpose)",
            "Started: \(ISO8601DateFormatter().string(from: startedAt))",
            "Connection: \(connection.name)", "JDBC URL: \(connection.jdbcURL)",
            "Mode: \(connection.usesSID ? "SID" : "Service name")", "User: \(connection.username)",
            "Driver: Oracle JDBC Thin · TCP",
            "Bundled charset library: \(connection.usesBundledInternationalization ? "orai18n.jar" : "disabled")",
            "Additional JARs: \(connection.additionalJARs.isEmpty ? "none" : connection.additionalJARs.joined(separator: ", "))",
            "Password: [never included]",
            "Timeouts: TCP 8s · connection establishment 10s · read 70s · verification query 10s",
            "Verification SQL: SELECT 1 FROM DUAL", "Outcome: \(outcome)",
            String(format: "Elapsed: %.3fs", elapsed), "", "Attempt log:"
        ]
        lines += events.map { String(format: "+%.3fs [%@] %@: %@", max(0, $0.date.timeIntervalSince(startedAt)), $0.level.rawValue, $0.stage.title, $0.message) }
        if let failure {
            lines += ["", "Original error:", failure.message]
            if let code = failure.errorCode { lines.append("Vendor code: \(code)") }
            if let state = failure.sqlState { lines.append("SQLState: \(state)") }
            lines += failure.details
            lines += ["", "Check: \(failure.suggestion)"]
        }
        return lines.joined(separator: "\n")
    }
}

enum OracleBridgeFrame {
    case event(ConnectionEvent)
    case failure(OracleConnectionFailure)
    case result(QueryResult)

    static func decode(_ payload: Data) throws -> Self {
        struct EventEnvelope: Decodable {
            struct Event: Decodable {
                let stage: ConnectionStage
                let level: ConnectionEvent.Level
                let message: String
            }
            let event: Event
        }
        let decoder = JSONDecoder()
        if let envelope = try? decoder.decode(EventEnvelope.self, from: payload) {
            return .event(ConnectionEvent(stage: envelope.event.stage, level: envelope.event.level, message: envelope.event.message))
        }
        if let failure = try? decoder.decode(OracleConnectionFailure.self, from: payload) { return .failure(failure) }
        return .result(try decoder.decode(QueryResult.self, from: payload))
    }
}
