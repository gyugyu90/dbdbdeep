import Foundation
import DBDeepCore

enum WorkspaceDefaults {
    static let sampleQuery = "-- A little peek at our customers 🌷\nSELECT\n    id, name, email, plan, status\nFROM customers\nORDER BY id;"

    static var directory: URL {
        let name = Bundle.main.bundleIdentifier == "studio.dbdbdeep.preview" ? "DBDeep Preview" : "DBDeep"
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(name)
    }

    static func query(for kind: DBConnection.Kind?) -> String {
        kind == .oracle ? "-- Hello, Oracle ✨\nSELECT *\nFROM user_tables\nFETCH FIRST 100 ROWS ONLY;" : sampleQuery
    }

    static func makeWorkspace() -> WorkspaceState {
        let sample = DBConnection(name: "Little playground", kind: .sample, color: "mint")
        let bookmarks = [
            QueryBookmark(name: "All the lovely customers", emoji: "🌷", color: "lavender", sql: sampleQuery, connectionID: sample.id),
            QueryBookmark(name: "Who's on the pro plan?", emoji: "⚡️", color: "peach", sql: "SELECT name, email, plan\nFROM customers\nWHERE plan = 'pro';", connectionID: sample.id),
            QueryBookmark(name: "A little order check", emoji: "🧺", color: "mint", sql: "SELECT o.id, c.name, o.total, o.status\nFROM orders o\nJOIN customers c ON c.id = o.customer_id;", connectionID: sample.id),
            QueryBookmark(name: "Make room for a new note", emoji: "✏️", color: "yellow", sql: "INSERT INTO notes (content)\nVALUES ('Something good is on its way.');", connectionID: sample.id)
        ]
        return WorkspaceState(connections: [sample], bookmarks: bookmarks, selectedConnection: sample.id)
    }
}
