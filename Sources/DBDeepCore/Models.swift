import Foundation

public struct DBConnection: Identifiable, Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case oracle, mongodb, sample }
    public var id: UUID
    public var name: String
    public var kind: Kind
    public var host: String
    public var port: Int
    public var service: String
    public var username: String
    public var usesSID: Bool
    public var color: String
    public var usesBundledInternationalization: Bool
    public var additionalJARs: [String]
    public var mongoAuthSource: String
    public var mongoTLS: Bool
    public var mongoSRV: Bool
    public var mongoReplicaSet: String

    public init(id: UUID = UUID(), name: String, kind: Kind = .oracle, host: String = "localhost", port: Int = 1521, service: String = "FREEPDB1", username: String = "", usesSID: Bool = false, color: String = "lavender", usesBundledInternationalization: Bool = true, additionalJARs: [String] = [], mongoAuthSource: String = "", mongoTLS: Bool = false, mongoSRV: Bool = false, mongoReplicaSet: String = "") {
        self.id = id; self.name = name; self.kind = kind; self.host = host
        self.port = port; self.service = service; self.username = username
        self.usesSID = usesSID; self.color = color
        self.usesBundledInternationalization = usesBundledInternationalization; self.additionalJARs = additionalJARs
        self.mongoAuthSource = mongoAuthSource; self.mongoTLS = mongoTLS; self.mongoSRV = mongoSRV; self.mongoReplicaSet = mongoReplicaSet
    }

    enum CodingKeys: String, CodingKey {
        case id, name, kind, host, port, service, username, usesSID, color, usesBundledInternationalization, additionalJARs, mongoAuthSource, mongoTLS, mongoSRV, mongoReplicaSet
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        kind = try values.decode(Kind.self, forKey: .kind)
        host = try values.decode(String.self, forKey: .host)
        port = try values.decode(Int.self, forKey: .port)
        service = try values.decode(String.self, forKey: .service)
        username = try values.decode(String.self, forKey: .username)
        usesSID = try values.decode(Bool.self, forKey: .usesSID)
        color = try values.decode(String.self, forKey: .color)
        usesBundledInternationalization = try values.decodeIfPresent(Bool.self, forKey: .usesBundledInternationalization) ?? true
        additionalJARs = try values.decodeIfPresent([String].self, forKey: .additionalJARs) ?? []
        mongoAuthSource = try values.decodeIfPresent(String.self, forKey: .mongoAuthSource) ?? ""
        mongoTLS = try values.decodeIfPresent(Bool.self, forKey: .mongoTLS) ?? false
        mongoSRV = try values.decodeIfPresent(Bool.self, forKey: .mongoSRV) ?? false
        mongoReplicaSet = try values.decodeIfPresent(String.self, forKey: .mongoReplicaSet) ?? ""
    }

    public var subtitle: String { kind == .sample ? "SQLite · local playground" : "\(host):\(port) / \(service)" }
    public var databaseName: String {
        switch kind { case .oracle: return "Oracle"; case .mongodb: return "MongoDB"; case .sample: return "SQLite" }
    }
    public var dialect: String { kind == .mongodb ? "MongoDB" : kind == .oracle ? "Oracle SQL" : "SQLite" }
    public var supportsTransactions: Bool { kind != .mongodb }
    public var needsPassword: Bool { kind == .oracle || (kind == .mongodb && !username.isEmpty) }
}

public struct QueryBookmark: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var emoji: String
    public var color: String
    public var sql: String
    public var connectionID: UUID?

    public init(id: UUID = UUID(), name: String, emoji: String = "✨", color: String = "lavender", sql: String, connectionID: UUID? = nil) {
        self.id = id; self.name = name; self.emoji = emoji
        self.color = color; self.sql = sql; self.connectionID = connectionID
    }
}

public struct SchemaColumn: Identifiable, Equatable, Sendable {
    public var id: String { name }
    public let name: String
    public let type: String
    public let primaryKey: Bool
    public let nullable: Bool
    public let comment: String?
    public init(name: String, type: String, primaryKey: Bool = false, nullable: Bool = true, comment: String? = nil) {
        self.name = name; self.type = type; self.primaryKey = primaryKey; self.nullable = nullable
        self.comment = comment
    }
}

public struct SchemaTable: Identifiable, Equatable, Sendable {
    public var id: String { name }
    public let name: String
    public let isView: Bool
    public var columns: [SchemaColumn]
    public init(name: String, isView: Bool = false, columns: [SchemaColumn] = []) {
        self.name = name; self.isView = isView; self.columns = columns
    }
}

public struct QueryResult: Codable, Sendable, Identifiable {
    public var id: UUID = UUID()
    public var columns: [String]
    public var rows: [[String?]]
    public var affected: Int
    public var elapsed: Double
    public var truncated: Bool
    public var message: String
    public var documents: [String]?

    public init(columns: [String] = [], rows: [[String?]] = [], affected: Int = 0, elapsed: Double = 0, truncated: Bool = false, message: String = "", documents: [String]? = nil) {
        self.columns = columns; self.rows = rows; self.affected = affected
        self.elapsed = elapsed; self.truncated = truncated; self.message = message
        self.documents = documents
    }

    enum CodingKeys: String, CodingKey { case columns, rows, affected, elapsed, truncated, message, documents }

    public var csv: String {
        func cell(_ value: String?) -> String {
            guard let value else { return "" }
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return ([columns.map { cell($0) }.joined(separator: ",")] + rows.map { $0.map(cell).joined(separator: ",") }).joined(separator: "\r\n")
    }
}

public struct DatabaseError: LocalizedError, Sendable {
    public let message: String
    public var errorDescription: String? { message }
    public init(_ message: String) { self.message = message }
}

public enum SQLIdentifier {
    public static func quote(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
}

public struct WorkspaceState: Codable {
    public var connections: [DBConnection]
    public var bookmarks: [QueryBookmark]
    public var drafts: [String: String]
    public var draftUpdatedAt: [String: Date]?
    public var selectedConnection: UUID?
    public init(connections: [DBConnection], bookmarks: [QueryBookmark], drafts: [String: String] = [:], selectedConnection: UUID? = nil, draftUpdatedAt: [String: Date]? = nil) {
        self.connections = connections; self.bookmarks = bookmarks; self.drafts = drafts; self.selectedConnection = selectedConnection
        self.draftUpdatedAt = draftUpdatedAt
    }
}
