import Foundation

public struct ConsoleDraft: Codable, Equatable, Sendable {
    public var connectionName: String
    public var query: String
    public var updatedAt: Date

    public init(connectionName: String, query: String, updatedAt: Date = Date()) {
        self.connectionName = connectionName
        self.query = query
        self.updatedAt = updatedAt
    }
}

public struct ConsoleDraftFileStore: Sendable {
    public let directory: URL
    private var current: URL { directory.appendingPathComponent("current.json") }
    private var previous: URL { directory.appendingPathComponent("previous.json") }
    private var history: URL { directory.appendingPathComponent("History", isDirectory: true) }
    private let historyLimit = 20
    private let checkpointInterval: TimeInterval = 300

    public struct Snapshot: Codable, Equatable {
        public var drafts: [String: ConsoleDraft]
    }

    public struct Loaded {
        public var drafts: [String: ConsoleDraft]
        public var recoveredFromBackup: Bool
    }

    public init(directory: URL) {
        self.directory = directory.appendingPathComponent("ConsoleDrafts", isDirectory: true)
    }

    public func load() throws -> Loaded {
        var readError: Error?
        for candidate in [current, previous] where FileManager.default.fileExists(atPath: candidate.path) {
            do {
                let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: candidate))
                return Loaded(drafts: snapshot.drafts, recoveredFromBackup: candidate != current)
            } catch { readError = error }
        }
        for candidate in try checkpoints().reversed() {
            do {
                let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: candidate))
                return Loaded(drafts: snapshot.drafts, recoveredFromBackup: true)
            } catch { readError = error }
        }
        if let readError { throw readError }
        return Loaded(drafts: [:], recoveredFromBackup: false)
    }

    public func save(_ drafts: [String: ConsoleDraft], now: Date = Date()) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let snapshot = Snapshot(drafts: drafts)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(snapshot)
        if manager.fileExists(atPath: current.path) {
            let original = try Data(contentsOf: current)
            if let old = try? JSONDecoder().decode(Snapshot.self, from: original) {
                if old == snapshot { return }
                try original.write(to: previous, options: .atomic)
                let cleared = old.drafts.contains { id, draft in
                    !draft.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                    (drafts[id]?.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                }
                try checkpoint(original, now: now, force: cleared)
            } else {
                _ = try load()
                let unreadable = directory.appendingPathComponent("unreadable-\(UUID().uuidString).json")
                try original.write(to: unreadable, options: .atomic)
            }
        }
        try data.write(to: current, options: .atomic)
    }

    private func checkpoints() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: history.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: history, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func checkpoint(_ data: Data, now: Date, force: Bool) throws {
        let manager = FileManager.default
        let existing = try checkpoints()
        if !force, let last = existing.last {
            let modified = try last.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            if let modified, now.timeIntervalSince(modified) < checkpointInterval { return }
        }
        try manager.createDirectory(at: history, withIntermediateDirectories: true)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let stamp = formatter.string(from: now).replacingOccurrences(of: ":", with: "-")
        let target = history.appendingPathComponent("\(stamp)-\(UUID().uuidString).json")
        try data.write(to: target, options: .atomic)
        try manager.setAttributes([.modificationDate: now], ofItemAtPath: target.path)
        for expired in (existing + [target]).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).dropLast(historyLimit) {
            try manager.removeItem(at: expired)
        }
    }
}
