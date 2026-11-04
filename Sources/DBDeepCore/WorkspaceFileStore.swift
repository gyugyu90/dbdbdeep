import Foundation

public struct WorkspaceFileStore {
    public let directory: URL
    private var file: URL { directory.appendingPathComponent("workspace.json") }

    public init(directory: URL) {
        self.directory = directory
    }

    public func load() throws -> WorkspaceState? {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try JSONDecoder().decode(WorkspaceState.self, from: Data(contentsOf: file))
    }

    public func save(_ state: WorkspaceState) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(state)
        if FileManager.default.fileExists(atPath: file.path) {
            let original = try Data(contentsOf: file)
            guard let previous = try? JSONDecoder().decode(WorkspaceState.self, from: original) else {
                throw DatabaseError("기존 작업 공간을 읽을 수 없어 저장을 중단했습니다. 원본 설정 파일은 보존됩니다.")
            }
            let backups = directory.appendingPathComponent("Backups", isDirectory: true)
            let needsBackup = previous.connections != state.connections || previous.bookmarks != state.bookmarks || !FileManager.default.fileExists(atPath: backups.path)
            if needsBackup {
                try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
                let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
                let backup = backups.appendingPathComponent("workspace-\(stamp)-\(UUID().uuidString).json")
                try original.write(to: backup, options: .atomic)
            }
            if original == data { return }
        }
        try data.write(to: file, options: .atomic)
    }
}
